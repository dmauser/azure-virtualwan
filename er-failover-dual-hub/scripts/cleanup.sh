#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — tear down the ExpressRoute failover lab
# =============================================================================
# Circuits are deleted first so the provider-side VXC is released cleanly before
# the resource group goes away. Delete the VXCs in your provider portal too.
# =============================================================================
set -euo pipefail

RG=""
PREFIX="erfo"
YES="false"
KEEP_RG="false"

usage() {
  cat <<EOF
Usage: $(basename "$0") -g <resource-group> [options]

  -g, --resource-group   Resource group to tear down (required)
  -p, --prefix           labPrefix used at deploy time (default: ${PREFIX})
      --keep-rg          Delete lab resources but keep the resource group
  -y, --yes              Skip the confirmation prompt
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -p|--prefix)         PREFIX="$2"; shift 2 ;;
    --keep-rg)           KEEP_RG="true"; shift ;;
    -y|--yes)            YES="true"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$RG" ]] && { echo "ERROR: --resource-group is required" >&2; usage; exit 1; }

if ! az group show -n "$RG" -o none 2>/dev/null; then
  echo "Resource group '${RG}' does not exist. Nothing to do."
  exit 0
fi

if [[ "$YES" != "true" ]]; then
  echo "This will DELETE the ExpressRoute failover lab in resource group '${RG}'."
  [[ "$KEEP_RG" == "true" ]] && echo "The resource group itself will be kept." \
                             || echo "The resource group itself will also be deleted."
  read -rp "Type the resource group name to confirm: " CONFIRM
  [[ "$CONFIRM" != "$RG" ]] && { echo "Aborted."; exit 1; }
fi

echo
echo "Deleting ExpressRoute connections..."
for KEY in wus2 scus; do
  GW="${PREFIX}-hub-${KEY}-ergw"
  for CONN in $(az network express-route gateway connection list --gateway-name "$GW" -g "$RG" --query "[].name" -o tsv 2>/dev/null || true); do
    echo "  ${GW}/${CONN}"
    az network express-route gateway connection delete --gateway-name "$GW" -g "$RG" -n "$CONN" -o none 2>/dev/null || true
  done
done

echo "Deleting ExpressRoute circuits (releases the provider-side VXC)..."
for CKT in $(az network express-route list -g "$RG" --query "[].name" -o tsv 2>/dev/null || true); do
  echo "  ${CKT}"
  az network express-route delete -g "$RG" -n "$CKT" -o none 2>/dev/null || \
    echo "    WARNING: could not delete ${CKT} — check the provider side, then retry."
done

if [[ "$KEEP_RG" == "true" ]]; then
  echo "Deleting remaining lab resources..."
  IDS="$(az resource list -g "$RG" --query "[?tags.lab=='er-failover-dual-hub'].id" -o tsv 2>/dev/null || true)"
  if [[ -n "$IDS" ]]; then
    # shellcheck disable=SC2086
    az resource delete --ids $IDS --verbose 2>/dev/null || \
      echo "  Some resources could not be deleted individually; delete the group instead."
  fi
  echo "Done. Resource group '${RG}' kept."
else
  echo "Deleting resource group '${RG}' (running in the background)..."
  az group delete -n "$RG" --yes --no-wait
  echo "Done. Track with: az group show -n ${RG}"
fi

echo
echo "REMINDER: cancel the VXCs in your provider (Megaport) portal so they stop billing."
