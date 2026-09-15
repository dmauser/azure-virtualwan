#!/usr/bin/env bash
# =============================================================================
# wait-for-er-provisioned.sh
# Runs inside a Microsoft.Resources/deploymentScripts (Azure CLI) container.
#
# Purpose:
#   Block the deployment until an ExpressRoute circuit has been provisioned by
#   the connectivity provider, so the vHub ExpressRoute connection is only
#   attempted once it can actually succeed.
#
# Gate conditions:
#   1. serviceProviderProvisioningState == "Provisioned"   (always)
#   2. an AzurePrivatePeering exists on the circuit         (only when
#      REQUIRE_PRIVATE_PEERING=true — i.e. the provider creates peering for you)
#
# Environment (injected by er-wait.bicep):
#   CIRCUIT_ID              Full ARM resource ID of the ExpressRoute circuit
#   POLL_SECONDS            Seconds between polls
#   TIMEOUT_SECONDS         Hard deadline
#   REQUIRE_PRIVATE_PEERING "true" | "false"
# =============================================================================

set -o pipefail

POLL_SECONDS="${POLL_SECONDS:-60}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-6600}"
REQUIRE_PRIVATE_PEERING="${REQUIRE_PRIVATE_PEERING:-false}"

if [ -z "${CIRCUIT_ID}" ]; then
  echo "FATAL: CIRCUIT_ID is not set."
  exit 1
fi

CIRCUIT_NAME="${CIRCUIT_ID##*/}"
START_EPOCH="$(date +%s)"
ATTEMPT=0

echo "=============================================================="
echo "Waiting for ExpressRoute circuit : ${CIRCUIT_NAME}"
echo "Require private peering          : ${REQUIRE_PRIVATE_PEERING}"
echo "Poll interval                    : ${POLL_SECONDS}s"
echo "Timeout                          : ${TIMEOUT_SECONDS}s"
echo "=============================================================="

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  NOW_EPOCH="$(date +%s)"
  ELAPSED=$((NOW_EPOCH - START_EPOCH))

  CIRCUIT_JSON="$(az network express-route show --ids "${CIRCUIT_ID}" -o json 2>/dev/null)"

  if [ -z "${CIRCUIT_JSON}" ]; then
    echo "[${ELAPSED}s] attempt ${ATTEMPT}: could not read circuit yet, retrying."
  else
    PROVIDER_STATE="$(echo "${CIRCUIT_JSON}" | jq -r '.serviceProviderProvisioningState // "Unknown"')"
    CIRCUIT_STATE="$(echo "${CIRCUIT_JSON}" | jq -r '.circuitProvisioningState // "Unknown"')"
    PEERING_COUNT="$(echo "${CIRCUIT_JSON}" | jq -r '[.peerings[]? | select(.peeringType == "AzurePrivatePeering")] | length')"

    echo "[${ELAPSED}s] attempt ${ATTEMPT}: circuit=${CIRCUIT_STATE} provider=${PROVIDER_STATE} privatePeerings=${PEERING_COUNT}"

    PROVIDER_OK="false"
    [ "${PROVIDER_STATE}" = "Provisioned" ] && PROVIDER_OK="true"

    PEERING_OK="true"
    if [ "${REQUIRE_PRIVATE_PEERING}" = "true" ] && [ "${PEERING_COUNT}" -lt 1 ]; then
      PEERING_OK="false"
    fi

    if [ "${PROVIDER_OK}" = "true" ] && [ "${PEERING_OK}" = "true" ]; then
      echo "READY: ${CIRCUIT_NAME} is provisioned and satisfies the peering gate."
      jq -n \
        --arg circuitName "${CIRCUIT_NAME}" \
        --arg providerState "${PROVIDER_STATE}" \
        --arg circuitState "${CIRCUIT_STATE}" \
        --argjson privatePeerings "${PEERING_COUNT}" \
        --argjson elapsedSeconds "${ELAPSED}" \
        --argjson attempts "${ATTEMPT}" \
        '{ready: true, circuitName: $circuitName, providerState: $providerState, circuitState: $circuitState, privatePeerings: $privatePeerings, elapsedSeconds: $elapsedSeconds, attempts: $attempts}' \
        > "${AZ_SCRIPTS_OUTPUT_PATH}"
      exit 0
    fi
  fi

  if [ "${ELAPSED}" -ge "${TIMEOUT_SECONDS}" ]; then
    echo "TIMEOUT after ${ELAPSED}s waiting for ${CIRCUIT_NAME}."
    echo "The circuit was never reported as Provisioned by the connectivity provider."
    echo "Give the service key to the provider, confirm they completed provisioning,"
    echo "then re-run the deployment — it is idempotent and will resume here."
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done
