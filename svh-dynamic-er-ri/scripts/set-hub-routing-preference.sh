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
#   ./set-hub-routing-preference.sh -g <rg> -p ASPath -y          # all hubs, no prompt
#   ./set-hub-routing-preference.sh -g <rg> -p ASPath --hubs "vhub1,vhub2,vhub4" -y
#
# Options:
#   -g|--resource-group <rg>   Resource group. Required (prompted if omitted).
#   --subscription <sub>       Azure subscription ID or name (optional).
#   -p|--preference <pref>     Target: ExpressRoute | VpnGateway | ASPath (default ASPath).
#   --hubs <list|all>          Hubs to change: "all" (default) or comma/space list
#                              of names/suffixes, e.g. "vhub1,vhub2,vhub4".
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
HUBS_SEL="all"
DUMP_ONLY=0
YES=0
[ "${LAB_NON_INTERACTIVE:-}" = "1" ] && YES=1

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    --subscription)      SUBSCRIPTION="$2"; shift 2 ;;
    -p|--preference)     PREF="$2"; shift 2 ;;
    --hubs)              HUBS_SEL="$2"; shift 2 ;;
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

show_table() {  # show_table <title> ; reads PREF_MAP + TARGET map
  local title="$1"
  echo ""
  echo "$title"
  printf '  %-30s %-18s %s\n' "Virtual Hub" "Route Preference" "Targeted"
  printf '  %-30s %-18s %s\n' "-----------" "----------------" "--------"
  local h tag
  for h in "${HUBS[@]}"; do
    tag="-"; [ -n "${IS_TARGET[$h]:-}" ] && tag="yes"
    printf '  %-30s %-18s %s\n' "$h" "${PREF_MAP[$h]}" "$tag"
  done
}

# ---------------------------------------------------------------------------
# Resolve which hubs to change. --hubs accepts "all" (default) or a
# comma/space-separated list of names or suffixes (e.g. "vhub1,vhub2,vhub4"
# matches vwanlab-vhub1 / vwanlab-vhub2 / vwanlab-vhub4).
# ---------------------------------------------------------------------------
declare -A IS_TARGET
TARGETS=()
if [ -z "$HUBS_SEL" ] || [ "$HUBS_SEL" = "all" ] || [ "$HUBS_SEL" = "*" ]; then
  for h in "${HUBS[@]}"; do IS_TARGET[$h]=1; TARGETS+=("$h"); done
else
  IFS=', ' read -r -a toks <<< "$HUBS_SEL"
  for tok in "${toks[@]}"; do
    [ -z "$tok" ] && continue
    matched=0
    for h in "${HUBS[@]}"; do
      if [ "$h" = "$tok" ] || [[ "$h" == *"$tok" ]] || [[ "$h" == *"$tok"* ]]; then
        if [ -z "${IS_TARGET[$h]:-}" ]; then IS_TARGET[$h]=1; TARGETS+=("$h"); fi
        matched=1
      fi
    done
    [ "$matched" -eq 0 ] && echo "[set-hub-routing-preference] No hub matches '$tok' — ignoring." >&2
  done
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "[set-hub-routing-preference] No hubs matched --hubs '$HUBS_SEL'. Exiting." >&2
    exit 1
  fi
fi

declare -A PREF_MAP
for h in "${HUBS[@]}"; do PREF_MAP[$h]="$(get_pref "$h")"; done
show_table "Current Hub Route Preference (${#HUBS[@]} hub(s), ${#TARGETS[@]} targeted):"

if [ "$DUMP_ONLY" -eq 1 ]; then
  log "dump-only specified — no changes made."
  exit 0
fi

# Already at target (among targeted hubs)?
need=0
for h in "${TARGETS[@]}"; do [ "${PREF_MAP[$h]}" != "$PREF" ] && need=1; done
if [ "$need" -eq 0 ]; then
  log "All targeted hub(s) are already set to '$PREF'. Nothing to change."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  echo ""
  echo "About to change ${#TARGETS[@]} targeted hub(s) [${TARGETS[*]}] to Route Preference = $PREF."
  read -r -p "Proceed? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log "Cancelled by user. No changes made."
    exit 0
  fi
fi

# Apply
for h in "${TARGETS[@]}"; do
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
for h in "${TARGETS[@]}"; do [ "${PREF_MAP[$h]}" != "$PREF" ] && failed+=("$h"); done
echo ""
if [ ${#failed[@]} -eq 0 ]; then
  echo "OK: All ${#TARGETS[@]} targeted hub(s) now report Route Preference = $PREF."
  exit 0
else
  echo "FAILED: the following hub(s) did NOT apply '$PREF':"
  for h in "${failed[@]}"; do echo "    $h = ${PREF_MAP[$h]}"; done
  exit 1
fi
