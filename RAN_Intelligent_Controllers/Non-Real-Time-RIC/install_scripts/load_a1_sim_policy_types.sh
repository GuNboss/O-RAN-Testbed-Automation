#!/bin/bash
#
# NIST-developed software is provided by NIST as a public service. You may use,
# copy, and distribute copies of the software in any medium, provided that you
# keep intact this entire notice. You may improve, modify, and create derivative
# works of the software or any portion of the software, and you may copy and
# distribute such modifications or works. Modified works should carry a notice
# stating that you changed the software and should note the date and nature of
# any such change. Please explicitly acknowledge the National Institute of
# Standards and Technology as the source of the software.
#
# NIST-developed software is expressly provided "AS IS." NIST MAKES NO WARRANTY
# OF ANY KIND, EXPRESS, IMPLIED, IN FACT, OR ARISING BY OPERATION OF LAW,
# INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTY OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, AND DATA ACCURACY. NIST
# NEITHER REPRESENTS NOR WARRANTS THAT THE OPERATION OF THE SOFTWARE WILL BE
# UNINTERRUPTED OR ERROR-FREE, OR THAT ANY DEFECTS WILL BE CORRECTED. NIST DOES
# NOT WARRANT OR MAKE ANY REPRESENTATIONS REGARDING THE USE OF THE SOFTWARE OR
# THE RESULTS THEREOF, INCLUDING BUT NOT LIMITED TO THE CORRECTNESS, ACCURACY,
# RELIABILITY, OR USEFULNESS OF THE SOFTWARE.
#
# You are solely responsible for determining the appropriateness of using and
# distributing the software and you assume all risks associated with its use,
# including but not limited to the risks and costs of program errors, compliance
# with applicable laws, damage to or loss of data, programs or equipment, and
# the unavailability or interruption of operation. This software is not intended
# to be used in any situation where a failure could cause risk of injury or
# damage to property. The software developed by NIST employees is not subject to
# copyright protection within the United States.

# Load sample policy types into the A1 simulators, which keep them only in memory,
# so they are empty after a fresh install or a pod restart. Without them the PMS
# reports no policy types and tests/test_a1_policy.py cannot create a policy.

echo "# Script: $(realpath "$0") $@"

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PARENT_DIR=$(dirname "$SCRIPT_DIR")
cd "$PARENT_DIR"

NAMESPACE="nonrtric"
SIM_PORT=8085
PMS_PORT=8081

OSC_POLICY_TYPE_ID="20008"
OSC_POLICY_TYPE='{"name": "tsapolicy", "description": "tsa parameters", "policy_type_id": 20008, "create_schema": {"$schema": "http://json-schema.org/draft-07/schema#", "title": "TSA", "type": "object", "properties": {"threshold": {"type": "integer", "default": 0}}, "additionalProperties": false, "required": ["threshold"]}}'

STD_V2_POLICY_TYPE_ID="STD_QOS_0_2_0"
STD_V2_POLICY_TYPE='{"policySchema": {"$schema": "http://json-schema.org/draft-07/schema#", "title": "STD_QOS_0_2_0", "type": "object", "properties": {"scope": {"type": "object", "properties": {"ueId": {"type": "string"}, "qosId": {"type": "string"}}, "required": ["ueId", "qosId"]}, "qosObjectives": {"type": "object", "properties": {"priorityLevel": {"type": "number"}}, "required": ["priorityLevel"]}}, "required": ["scope", "qosObjectives"]}, "statusSchema": {"type": "object", "properties": {"enforceStatus": {"type": "string"}}}}'

SIM_PODS=$(kubectl get pods -n $NAMESPACE -l chart=a1simulator --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}')
if [ -z "$SIM_PODS" ]; then
    echo "No running A1 simulator pods found in namespace $NAMESPACE."
    exit 1
fi

EXPECTED_TYPES=0
while read -r POD_NAME POD_IP; do
    INTERFACE=$(curl -s --max-time 10 "http://$POD_IP:$SIM_PORT/counter/interface")
    case "$INTERFACE" in
    OSC_*)
        TYPE_ID=$OSC_POLICY_TYPE_ID
        TYPE_BODY=$OSC_POLICY_TYPE
        TYPE_LIST_PATH="a1-p/policytypes"
        ;;
    STD_2*)
        TYPE_ID=$STD_V2_POLICY_TYPE_ID
        TYPE_BODY=$STD_V2_POLICY_TYPE
        TYPE_LIST_PATH="A1-P/v2/policytypes"
        ;;
    *)
        # STD_1.x has no policy types
        echo "$POD_NAME ($INTERFACE): no policy types to load."
        continue
        ;;
    esac
    EXPECTED_TYPES=$((EXPECTED_TYPES + 1))
    if curl -s --max-time 10 "http://$POD_IP:$SIM_PORT/$TYPE_LIST_PATH" | jq -e --arg id "$TYPE_ID" 'map(tostring) | index($id)' &>/dev/null; then
        echo "$POD_NAME ($INTERFACE): policy type $TYPE_ID already loaded."
        continue
    fi
    RESPONSE=$(curl -s --max-time 10 -X PUT "http://$POD_IP:$SIM_PORT/policytype?id=$TYPE_ID" -H "Content-Type: application/json" -d "$TYPE_BODY" -w " %{http_code}")
    echo "$POD_NAME ($INTERFACE): $RESPONSE"
done <<<"$SIM_PODS"

# Wait for the PMS to pick up the policy types on its next RIC synchronization
PMS_IP=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=policymanagementservice -o jsonpath='{.items[0].status.podIP}')
if [ -z "$PMS_IP" ]; then
    echo "Policy Management Service pod not found."
    exit 1
fi
for ((i = 1; i <= 36; i++)); do
    LOADED_TYPES=$(curl -s --max-time 10 "http://$PMS_IP:$PMS_PORT/a1-policy/v2/rics" | jq '[.rics[] | select(any(.policytype_ids[]; . != ""))] | length' 2>/dev/null)
    if [ "${LOADED_TYPES:-0}" -ge "$EXPECTED_TYPES" ]; then
        echo "Policy Management Service reports policy types for $LOADED_TYPES RICs."
        exit 0
    fi
    echo "Waiting for the Policy Management Service to synchronize policy types ($((${LOADED_TYPES:-0}))/$EXPECTED_TYPES)..."
    sleep 5
done
echo "Timed out waiting for the Policy Management Service to report the policy types."
exit 1
