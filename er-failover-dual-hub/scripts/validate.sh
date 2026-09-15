#!/usr/bin/env bash
# =============================================================================
# validate.sh — post-deployment health check for the ER failover lab
# =============================================================================
set -euo pipefail

RG=""
PREFIX="erfo"
FAILURES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") -g <resource-group> [-p <lab-prefix>]

  -g, --resource-group   Resource group holding the lab (required)
  -p, --prefix           labPrefix used at deploy time   (default: ${PREFIX})
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -p|--prefix)         PREFIX="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$RG" ]] && { echo "ERROR: --resource-group is required" >&2; usage; exit 1; }

pass() { echo "  [ OK ] $1"; }
warn() { echo "  [WARN] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "== Virtual WAN =="
B2B="$(az network vwan show -g "$RG" -n "${PREFIX}-vwan" --query allowBranchToBranchTraffic -o tsv 2>/dev/null || echo "missing")"
if [[ "$B2B" == "true" ]]; then
  pass "allowBranchToBranchTraffic is true (required for hub-to-hub failover)"
else
  fail "allowBranchToBranchTraffic is '${B2B}' — failover will NOT work"
fi

echo
echo "== Virtual Hubs =="
for KEY in wus2 scus; do
  HUB="${PREFIX}-hub-${KEY}"
  PREF="$(az network vhub show -g "$RG" -n "$HUB" --query hubRoutingPreference -o tsv 2>/dev/null || echo "missing")"
  STATE="$(az network vhub show -g "$RG" -n "$HUB" --query provisioningState -o tsv 2>/dev/null || echo "missing")"
  [[ "$STATE" == "Succeeded" ]] && pass "${HUB} provisioningState=Succeeded" || fail "${HUB} provisioningState=${STATE}"
  [[ "$PREF" == "ASPath" ]] && pass "${HUB} hubRoutingPreference=ASPath" || fail "${HUB} hubRoutingPreference=${PREF} (expected ASPath)"
done

echo
echo "== Spoke connections =="
for KEY in wus2 scus; do
  HUB="${PREFIX}-hub-${KEY}"
  CONN="${PREFIX}-spoke-${KEY}-conn"
  STATE="$(az network vhub connection show --vhub-name "$HUB" -g "$RG" -n "$CONN" --query provisioningState -o tsv 2>/dev/null || echo "missing")"
  [[ "$STATE" == "Succeeded" ]] && pass "${CONN} Succeeded" || fail "${CONN} is ${STATE}"
done

echo
echo "== ExpressRoute circuits =="
for CKT in "${PREFIX}-er-chicago" "${PREFIX}-er-dallas"; do
  PSTATE="$(az network express-route show -g "$RG" -n "$CKT" --query serviceProviderProvisioningState -o tsv 2>/dev/null || echo "missing")"
  [[ "$PSTATE" == "Provisioned" ]] && pass "${CKT} provider state Provisioned" || fail "${CKT} provider state ${PSTATE}"

  PEER="$(az network express-route peering list -g "$RG" --circuit-name "$CKT" --query "length([?name=='AzurePrivatePeering'])" -o tsv 2>/dev/null || echo 0)"
  [[ "$PEER" != "0" ]] && pass "${CKT} AzurePrivatePeering configured" || fail "${CKT} AzurePrivatePeering missing"
done

echo
echo "== ExpressRoute gateways and connections =="
declare -A CIRCUIT_FOR=( [wus2]=chicago [scus]=dallas )
for KEY in wus2 scus; do
  GW="${PREFIX}-hub-${KEY}-ergw"
  CONN="${PREFIX}-erconn-${CIRCUIT_FOR[$KEY]}"
  GSTATE="$(az network express-route gateway show -g "$RG" -n "$GW" --query provisioningState -o tsv 2>/dev/null || echo "missing")"
  [[ "$GSTATE" == "Succeeded" ]] && pass "${GW} Succeeded" || fail "${GW} is ${GSTATE}"

  CSTATE="$(az network express-route gateway connection show --gateway-name "$GW" -g "$RG" -n "$CONN" --query provisioningState -o tsv 2>/dev/null || echo "missing")"
  [[ "$CSTATE" == "Succeeded" ]] && pass "${CONN} Succeeded" || fail "${CONN} is ${CSTATE}"
done

echo
echo "== Test VMs =="
for KEY in wus2 scus; do
  VM="${PREFIX}-vm-${KEY}"
  PS="$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null || echo "missing")"
  if [[ "$PS" == "VM running" ]]; then
    pass "${VM} running"
  elif [[ "$PS" == "VM deallocated" ]]; then
    warn "${VM} is deallocated (expected when idle - start it before running failover tests)"
    echo "         az vm start -g ${RG} -n ${VM}"
  else
    fail "${VM} is ${PS}"
  fi

  PIP_ID="$(az network nic show -g "$RG" -n "nic-${VM}" --query "ipConfigurations[0].publicIPAddress.id" -o tsv 2>/dev/null || true)"
  if [[ -z "$PIP_ID" ]]; then
    pass "${VM} has no public IP (private-only, as designed)"
  else
    fail "${VM} still has a public IP attached"
  fi

  BOOT="$(az vm show -g "$RG" -n "$VM" --query diagnosticsProfile.bootDiagnostics.enabled -o tsv 2>/dev/null || echo "false")"
  if [[ "$BOOT" == "true" ]]; then
    pass "${VM} boot diagnostics enabled (Serial Console ready)"
  else
    fail "${VM} boot diagnostics disabled - Serial Console will not work"
  fi

  echo "         az serial-console connect -g ${RG} -n ${VM}"
done

echo
echo "== Effective routes (hub default route tables) =="
for KEY in wus2 scus; do
  HUB="${PREFIX}-hub-${KEY}"
  RT_ID="$(az network vhub route-table show --vhub-name "$HUB" -g "$RG" -n defaultRouteTable --query id -o tsv 2>/dev/null || true)"
  if [[ -n "$RT_ID" ]]; then
    echo "--- ${HUB} ---"
    ROWS="$(az network vhub get-effective-routes --name "$HUB" -g "$RG" \
      --resource-type RouteTable --resource-id "$RT_ID" -o table 2>/dev/null || true)"
    if [[ -n "$ROWS" ]]; then
      echo "$ROWS" | sed 's/^/  /'
    else
      echo "  (no effective routes returned)"
    fi
  fi
done

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All checks passed. Proceed to docs/failover-tests.md."
  exit 0
else
  echo "${FAILURES} check(s) failed. See docs/troubleshooting.md."
  exit 1
fi
