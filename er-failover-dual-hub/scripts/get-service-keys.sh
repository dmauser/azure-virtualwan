#!/usr/bin/env bash
# =============================================================================
# get-service-keys.sh — print the ExpressRoute service keys and provider state
# =============================================================================
# Run this WHILE the deployment is parked on the provider-wait pollers. The
# `serviceKeys` deployment output only appears after the deployment finishes,
# which cannot happen until the circuits are provisioned — so read them here.
# =============================================================================
set -euo pipefail

RG=""
WATCH="false"
INTERVAL=30

usage() {
  cat <<EOF
Usage: $(basename "$0") -g <resource-group> [options]

  -g, --resource-group   Resource group holding the circuits (required)
  -w, --watch            Refresh until both circuits are Provisioned
  -i, --interval         Seconds between refreshes when watching (default: ${INTERVAL})
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -w|--watch)          WATCH="true"; shift ;;
    -i|--interval)       INTERVAL="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$RG" ]] && { echo "ERROR: --resource-group is required" >&2; usage; exit 1; }

show() {
  echo "ExpressRoute circuits in '${RG}'  —  $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo
  az network express-route list -g "$RG" --query "[].{ \
        Circuit:name, \
        Provider:serviceProviderProperties.serviceProviderName, \
        PeeringLocation:serviceProviderProperties.peeringLocation, \
        Mbps:serviceProviderProperties.bandwidthInMbps, \
        ServiceKey:serviceKey, \
        ProviderState:serviceProviderProvisioningState, \
        CircuitState:circuitProvisioningState}" -o table
  echo
  echo "Private peering status:"
  for CKT in $(az network express-route list -g "$RG" --query "[].name" -o tsv); do
    COUNT="$(az network express-route peering list -g "$RG" --circuit-name "$CKT" \
              --query "length([?name=='AzurePrivatePeering'])" -o tsv 2>/dev/null || echo 0)"
    if [[ "$COUNT" == "0" ]]; then
      echo "  ${CKT}: AzurePrivatePeering NOT configured"
    else
      echo "  ${CKT}: AzurePrivatePeering present"
    fi
  done
}

all_ready() {
  local pending
  pending="$(az network express-route list -g "$RG" \
      --query "length([?serviceProviderProvisioningState!='Provisioned'])" -o tsv)"
  [[ "$pending" == "0" ]]
}

if [[ "$WATCH" == "true" ]]; then
  while true; do
    clear
    show
    if all_ready; then
      echo
      echo "All circuits are Provisioned. The deployment should now create the hub connections."
      exit 0
    fi
    echo
    echo "Waiting for the provider... refreshing in ${INTERVAL}s (Ctrl-C to stop)"
    sleep "$INTERVAL"
  done
else
  show
  echo
  echo "Order one VXC per service key in your provider portal, then re-run with --watch."
fi
