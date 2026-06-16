#!/usr/bin/env bash
# =============================================================================
# Script : set-hub-routing-preference.sh
# Lab    : svh-dynamic-er-ri — Dynamic Secured Virtual WAN (N hubs, ER, AzFW Basic, RI)
# Purpose: Dump and (optionally) change the Hub Routing Preference on EVERY
#          Virtual Hub in the resource group.
#            1. Discover all Virtual Hubs and print each hub's current
#               hubRoutingPreference (ExpressRoute / VpnGateway / ASPath).
#            2. Offer to change ALL hubs to a target preference (default ASPath).
#            3. Apply via: az network vhub update --hub-routing-preference <pref>
#            4. Re-read every hub and confirm the change is effective.
#
#          NOTE: This lab is designed around Route Preference = ExpressRoute
#          (hard-coded in vhub.bicep, asserted by validate.*). Switching to
#          ASPath is a deliberate runtime-only override for BGP AS-path testing;
#          it does NOT change the Bicep. Re-running deploy/validate reports or
#          restores ExpressRoute. Use only for connectivity experiments.
#
# Usage  :
#   ./set-hub-routing-preference.sh -g <rg>                       # dump + prompt
#   ./set-hub-routing-preference.sh -g <rg> --dump-only           # dump only
#   ./set-hub-routing-preference.sh -g <rg> -p ASPath -y          # change, no prompt
#
# Options:
#   -g|--resource-group <rg>   Resource group. Required (prompted if omitted).
#   --subscription <sub>       Azure subscription ID or name (optional).
#   -p|--preference <pref>     Target: ExpressRoute | VpnGateway | ASPath (default ASPath).
#   --dump-only                Print current preference only; make no changes.
#   -y|--yes                   Skip confirmation. Also: LAB_NON_INTERACTIVE=1.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
lab_require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  echo "[prereq] Missing required tool(s): ${missing[*]}" >&2
  for t in "${missing[@]}"; do
    case "$t" in
      az) echo "  - Azure CLI (az): https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      *)  echo "  - $t: install via your OS package manager" >&2 ;;
    esac
  done

  if [ ! -t 0 ] || [ "${LAB_NON_INTERACTIVE:-}" = "1" ]; then
    echo "[prereq] Non-interactive — install the tool(s) above and re-run." >&2
    exit 1
  fi
  local ans=""
  read -r -p "[prereq] Attempt to install the missing tool(s) now? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[prereq] Install the tool(s) above and re-run." >&2
    exit 1
  fi
  local pm=""
  if   command -v brew    >/dev/null 2>&1; then pm="brew"
  elif command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v dnf     >/dev/null 2>&1; then pm="dnf"
  elif command -v yum     >/dev/null 2>&1; then pm="yum"
  fi
  for t in "${missing[@]}"; do
    if [ "$t" = "az" ]; then
      echo "[prereq] Azure CLI needs a vendor installer — see link above." >&2
      continue
    fi
    [ -n "$pm" ] || { echo "[prereq] No package manager found." >&2; exit 1; }
    case "$pm" in
      brew) brew install "$t" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$t" || true ;;
      dnf)  sudo dnf install -y "$t" || true ;;
      yum)  sudo yum install -y "$t" || true ;;
    esac
  done
  missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} — install and re-run." >&2
    exit 1
  fi
}
lab_require_tools az

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
RG=""
SUBSCRIPTION=""
PREF="ASPath"
DUMP_ONLY=0
YES=0
[ "${LAB_NON_INTERACTIVE:-}" = "1" ] && YES=1

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    --subscription)      SUBSCRIPTION="$2"; shift 2 ;;
    -p|--preference)     PREF="$2"; shift 2 ;;
    --dump-only)         DUMP_ONLY=1; shift ;;
    -y|--yes)            YES=1; shift ;;
    -h|--help)           grep -E '^#( |=)' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$PREF" in
  ExpressRoute|VpnGateway|ASPath) ;;
  *) echo "[set-hub-routing-preference] Invalid preference '$PREF' (ExpressRoute|VpnGateway|ASPath)." >&2; exit 1 ;;
esac

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

if [ -z "$RG" ]; then
  read -r -p "Resource group containing the lab: " RG
fi
if [ -z "$RG" ]; then
  echo "[set-hub-routing-preference] No resource group provided. Exiting." >&2
  exit 1
fi

if [ -n "$SUBSCRIPTION" ]; then
  log "Setting subscription context: $SUBSCRIPTION"
  az account set --subscription "$SUBSCRIPTION" >/dev/null
fi

# ---------------------------------------------------------------------------
# Discover hubs
# ---------------------------------------------------------------------------
log "Discovering Virtual Hubs in resource group '$RG'..."
mapfile -t HUBS < <(az network vhub list -g "$RG" --query "[].name" -o tsv 2>/dev/null | tr -d '\r')
if [ ${#HUBS[@]} -eq 0 ]; then
  echo "[set-hub-routing-preference] No Virtual Hubs found in '$RG'." >&2
  exit 1
fi

get_pref() {  # get_pref <hub>
  local p
  p="$(az network vhub show -g "$RG" -n "$1" --query hubRoutingPreference -o tsv 2>/dev/null | tr -d '[:space:]')"
  [ -n "$p" ] && echo "$p" || echo "(unknown)"
}

show_table() {  # show_table <title> ; reads PREF_MAP
  local title="$1"
  echo ""
  echo "$title"
  printf '  %-30s %s\n' "Virtual Hub" "Route Preference"
  printf '  %-30s %s\n' "-----------" "----------------"
  local h
  for h in "${HUBS[@]}"; do
    printf '  %-30s %s\n' "$h" "${PREF_MAP[$h]}"
  done
}

declare -A PREF_MAP
for h in "${HUBS[@]}"; do PREF_MAP[$h]="$(get_pref "$h")"; done
show_table "Current Hub Route Preference (${#HUBS[@]} hub(s)):"

if [ "$DUMP_ONLY" -eq 1 ]; then
  log "dump-only specified — no changes made."
  exit 0
fi

# Already all at target?
need=0
for h in "${HUBS[@]}"; do [ "${PREF_MAP[$h]}" != "$PREF" ] && need=1; done
if [ "$need" -eq 0 ]; then
  log "All hubs are already set to '$PREF'. Nothing to change."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  echo ""
  echo "About to change ALL ${#HUBS[@]} hub(s) to Route Preference = $PREF."
  read -r -p "Proceed? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log "Cancelled by user. No changes made."
    exit 0
  fi
fi

# Apply
for h in "${HUBS[@]}"; do
  if [ "${PREF_MAP[$h]}" = "$PREF" ]; then
    log "$h already '$PREF' — skipping."
    continue
  fi
  log "Updating $h : ${PREF_MAP[$h]} -> $PREF ..."
  az network vhub update -g "$RG" -n "$h" --hub-routing-preference "$PREF" --output none
done

# ---------------------------------------------------------------------------
# Re-check effectiveness
# ---------------------------------------------------------------------------
log "Re-checking hub Route Preference after update..."
declare -A PREF_MAP
for h in "${HUBS[@]}"; do PREF_MAP[$h]="$(get_pref "$h")"; done
show_table "Updated Hub Route Preference:"

failed=()
for h in "${HUBS[@]}"; do [ "${PREF_MAP[$h]}" != "$PREF" ] && failed+=("$h"); done
echo ""
if [ ${#failed[@]} -eq 0 ]; then
  echo "OK: All ${#HUBS[@]} hub(s) now report Route Preference = $PREF."
  exit 0
else
  echo "FAILED: the following hub(s) did NOT apply '$PREF':"
  for h in "${failed[@]}"; do echo "    $h = ${PREF_MAP[$h]}"; done
  exit 1
fi
