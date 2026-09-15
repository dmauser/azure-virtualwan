#!/usr/bin/env bash
# =============================================================================
# deploy.sh — deploy the ExpressRoute failover lab
# =============================================================================
# The deployment intentionally parks while each ExpressRoute circuit waits for
# its connectivity provider. Once started, run ./get-service-keys.sh in another
# terminal, order the VXCs against those keys, and leave this running.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/../infra/bicep"

RG=""
LOCATION="westus2"
DEPLOYMENT_NAME="er-failover"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
WHATIF="false"
SKIP_WAIT="false"
SKIP_CIRCUITS="false"

usage() {
  cat <<EOF
Usage: $(basename "$0") -g <resource-group> [options]

  -g, --resource-group   Target resource group (required)
  -l, --location         Region for the resource group        (default: ${LOCATION})
  -n, --name             Deployment name                      (default: ${DEPLOYMENT_NAME})
  -p, --admin-password   VM admin password (or set ADMIN_PASSWORD)
      --skip-provider-wait Skip the provider-wait poller (circuits already Provisioned,
                           or deployment scripts blocked by policy)
      --skip-circuits    Leave the ExpressRoute circuits untouched. Use on redeployments
                         once the provider has provisioned them.
      --what-if          Preview changes without deploying
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -l|--location)       LOCATION="$2"; shift 2 ;;
    -n|--name)           DEPLOYMENT_NAME="$2"; shift 2 ;;
    -p|--admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --skip-provider-wait) SKIP_WAIT="true"; shift ;;
    --skip-circuits)     SKIP_CIRCUITS="true"; shift ;;
    --what-if)           WHATIF="true"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$RG" ]] && { echo "ERROR: --resource-group is required" >&2; usage; exit 1; }

if [[ -z "$ADMIN_PASSWORD" ]]; then
  read -rsp "VM admin password: " ADMIN_PASSWORD; echo
fi
[[ -z "$ADMIN_PASSWORD" ]] && { echo "ERROR: admin password is required" >&2; exit 1; }

if [[ "$SKIP_WAIT" != "true" ]]; then
  echo "Checking Microsoft.ContainerInstance registration (required by the provider-wait poller)..."
  STATE="$(az provider show --namespace Microsoft.ContainerInstance --query registrationState -o tsv 2>/dev/null || echo "Unknown")"
  if [[ "$STATE" != "Registered" ]]; then
    echo "  State is '${STATE}'. Registering..."
    az provider register --namespace Microsoft.ContainerInstance --wait
  fi
fi

echo "Ensuring resource group '${RG}' exists in ${LOCATION}..."
az group create -n "$RG" -l "$LOCATION" -o none

ARGS=(
  --resource-group "$RG"
  --name "$DEPLOYMENT_NAME"
  --template-file "${BICEP_DIR}/main.bicep"
  --parameters "${BICEP_DIR}/main.bicepparam"
  --parameters "adminPassword=${ADMIN_PASSWORD}"
)

if [[ "$SKIP_WAIT" == "true" ]]; then
  echo "Skipping the provider-wait poller (waitForProvider=false)."
  ARGS+=(--parameters "waitForProvider=false")
fi

if [[ "$SKIP_CIRCUITS" == "true" ]]; then
  echo "Leaving the ExpressRoute circuits untouched (manageCircuits=false)."
  ARGS+=(--parameters "manageCircuits=false")
fi

if [[ "$WHATIF" == "true" ]]; then
  echo "Running what-if..."
  az deployment group what-if "${ARGS[@]}"
  exit 0
fi

cat <<EOF

-------------------------------------------------------------------------------
Starting deployment '${DEPLOYMENT_NAME}' in '${RG}'.
EOF

if [[ "$SKIP_WAIT" == "true" ]]; then
  cat <<EOF

The provider-wait poller is disabled, so the ExpressRoute connections are
created immediately. Make sure both circuits already report
ServiceProviderProvisioningState = Provisioned, otherwise the connections fail.
-------------------------------------------------------------------------------

EOF
else
  cat <<EOF

This will PAUSE partway through while each ExpressRoute circuit waits for its
connectivity provider. That is expected.

In another terminal run:

    ${SCRIPT_DIR}/get-service-keys.sh -g ${RG}

...then order one VXC per service key in your provider portal. The deployment
resumes automatically once both circuits report Provisioned.
-------------------------------------------------------------------------------

EOF
fi

az deployment group create "${ARGS[@]}" -o json | tee /tmp/${DEPLOYMENT_NAME}-outputs.json >/dev/null

echo
echo "Deployment complete. Outputs:"
az deployment group show -g "$RG" -n "$DEPLOYMENT_NAME" --query properties.outputs -o json
echo
echo "Next: ${SCRIPT_DIR}/validate.sh -g ${RG}"
echo
echo "The test VMs have no public IP. Reach them with Serial Console:"
echo "    az extension add --name serial-console    # one time"
echo "    az serial-console connect -g ${RG} -n <vm-name>"
