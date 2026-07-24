#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Delete the nva-spoke-internet lab resource group.
# Usage: ./cleanup.sh [--rg <resource-group>] [--yes]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/functions.sh"

RG=""
SKIP_CONFIRM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rg)  RG="$2"; shift 2 ;;
    --yes) SKIP_CONFIRM=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Prompt for RG if not provided
if [[ -z "$RG" ]]; then
  read -r -p "Resource group to delete [rg-nva-spoke-internet]: " RG
  RG="${RG:-rg-nva-spoke-internet}"
fi

# Verify the RG exists
if ! az group show -n "$RG" --output none 2>/dev/null; then
  echo "Resource group '$RG' not found — nothing to delete."
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ⚠️  CLEANUP: This will delete ALL resources in the lab RG.  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Resource group : $RG"
echo ""

if [[ "$SKIP_CONFIRM" -eq 0 ]]; then
  read -r -p "  Type the resource group name to confirm deletion: " CONFIRM
  if [[ "$CONFIRM" != "$RG" ]]; then
    echo "Name did not match. Aborting."
    exit 1
  fi
fi

log "Deleting resource group '$RG' (--no-wait) ..."
az group delete -n "$RG" --yes --no-wait --output none
log "Deletion queued. Monitor progress in the Azure portal or:"
echo "  az group show -n $RG --query properties.provisioningState -o tsv"
