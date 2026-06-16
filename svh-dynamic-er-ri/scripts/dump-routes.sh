#!/usr/bin/env bash
# =============================================================================
# Script : dump-routes.sh
# Lab    : svh-dynamic-er-ri — Dynamic Secured Virtual WAN (N hubs, ER, AzFW Basic, RI)
# Purpose: Interactive, read-only route-dump tool. Dumps routing information for
#          the three core components of the lab:
#            1. ExpressRoute circuits  — summary + BGP route tables / ARP.
#            2. Virtual Hubs           — Azure Firewall effective routes (the
#                                        portal "Effective Routes / Azure Firewall"
#                                        view) plus the current hub Route Preference.
#            3. Virtual Machines       — NIC effective route table.
#
#          The Virtual Hub dump reproduces the Azure portal blade:
#              <hub> | Effective Routes  ->  Resource type = "Azure Firewall"
#          using:  az network vhub get-effective-routes --resource-type AzureFirewalls
#          (note the plural "AzureFirewalls" — the singular form silently returns
#          no routes). Columns match the portal:
#              Prefix | Next Hop Type | Next Hop | Origin | AS path
#
#          Read-only: never creates, changes or deletes any resource.
#
# Usage  :
#   ./dump-routes.sh -g <rg>                                  # interactive menu
#   ./dump-routes.sh -g <rg> --component vhub --target vwanlab-vhub2
#   ./dump-routes.sh -g <rg> --component all --target all --save --non-interactive
#
# Options:
#   -g|--resource-group <rg>   Resource group name. Required (prompted if omitted).
#   --subscription <sub>       Azure subscription ID or name (optional).
#   --component <er|vhub|vm|all>  Category to dump (skips the menu).
#   --target <name|all>        Specific resource name or "all" (default: all).
#   --save                     Also write raw JSON for every dump to ./route-dumps/.
#   --non-interactive          Skip prompts. Also: LAB_NON_INTERACTIVE=1.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
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
      az)        echo "  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      terraform) echo "  - Terraform:         https://developer.hashicorp.com/terraform/install" >&2 ;;
      gcloud)    echo "  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install" >&2 ;;
      jq)        echo "  - jq:                https://jqlang.github.io/jq/download/" >&2 ;;
      *)         echo "  - $t:                install via your OS package manager" >&2 ;;
    esac
  done

  if [ ! -t 0 ]; then
    echo "[prereq] Non-interactive shell — install the tool(s) above and re-run." >&2
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
  if [ -z "$pm" ]; then
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually (see links above)." >&2
    exit 1
  fi
  for t in "${missing[@]}"; do
    echo "[prereq] Installing '$t' via $pm ..."
    case "$pm" in
      brew) brew install "$t" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$t" || true ;;
      dnf)  sudo dnf install -y "$t" || true ;;
      yum)  sudo yum install -y "$t" || true ;;
    esac
  done

  missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} (az/terraform/gcloud need a vendor installer — see links above). Re-run when ready." >&2
    exit 1
  fi
}
lab_require_tools az jq

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date +%H:%M:%S)" "$*"; }
leaf() { local s="$1"; printf '%s' "${s##*/}"; }   # resource name from ARM id

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE_DIR="$SCRIPT_DIR/route-dumps"

save_raw() {  # save_raw <kind> <name> <json>
  [ "$SAVE" -eq 1 ] || return 0
  mkdir -p "$SAVE_DIR"
  local stamp safe file
  stamp="$(date +%Y%m%d-%H%M%S)"
  safe="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
  file="$SAVE_DIR/$stamp-$1-$safe.json"
  printf '%s' "$3" > "$file"
  printf '  (saved raw JSON: %s)\n' "$file"
}

# ---------------------------------------------------------------------------
# Defaults / env fallbacks
# ---------------------------------------------------------------------------
RESOURCE_GROUP=""
SUBSCRIPTION=""
COMPONENT="${LAB_DUMP_COMPONENT:-}"
TARGET="${LAB_DUMP_TARGET:-}"
SAVE=0
NON_INTERACTIVE="${LAB_NON_INTERACTIVE:-0}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
    --subscription)       SUBSCRIPTION="$2";   shift 2 ;;
    --component)          COMPONENT="$2";      shift 2 ;;
    --target)             TARGET="$2";         shift 2 ;;
    --save)               SAVE=1;              shift ;;
    --non-interactive)    NON_INTERACTIVE=1;   shift ;;
    -h|--help)            sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then echo "Resource group is required." >&2; exit 1; fi
  read -rp "Enter resource group name: " RESOURCE_GROUP
fi
[[ -n "$RESOURCE_GROUP" ]] || { echo "Resource group is required." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "   svh-dynamic-er-ri — Route Dump (ER circuits / vHubs / VMs)"
echo "   Read-only diagnostics — no resources are modified"
echo "============================================================================"
echo ""

if [[ -n "$SUBSCRIPTION" ]]; then
  log "Setting subscription: $SUBSCRIPTION"
  az account set --subscription "$SUBSCRIPTION"
fi
az account show >/dev/null 2>&1 || true   # pre-warm / consume first-run banner

log "Resource group : $RESOURCE_GROUP"

# ---------------------------------------------------------------------------
# Selection helper: print a numbered list, read choice, echo selected names.
# Args: <label> <preselect> <name1> <name2> ...
#   preselect empty/"all"/"*" => all; else number(s)/name(s) (comma or space).
# Echoes selected names, one per line, on stdout. Prompts go to stderr.
# ---------------------------------------------------------------------------
select_items() {
  local label="$1"; shift
  local preselect="$1"; shift
  local items=("$@")
  local n=${#items[@]}
  [ "$n" -eq 0 ] && return 0

  local choice="$preselect"
  if [[ -z "$choice" && "$NON_INTERACTIVE" -ne 1 ]]; then
    {
      echo ""
      echo "  Available $label:"
      local i
      for ((i = 0; i < n; i++)); do printf '    [%d] %s\n' "$((i + 1))" "${items[$i]}"; done
    } >&2
    read -rp "  Select $label (number, comma-separated, name, or 'all'): " choice >&2
  fi
  if [[ -z "$choice" || "$choice" =~ ^(all|\*)$ ]]; then
    printf '%s\n' "${items[@]}"
    return 0
  fi

  local tok idx hit found=0
  local cleaned="${choice//,/ }"
  for tok in $cleaned; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
      idx=$((tok - 1))
      if (( idx >= 0 && idx < n )); then printf '%s\n' "${items[$idx]}"; found=1; fi
    else
      for hit in "${items[@]}"; do
        if [[ "$hit" == "$tok" ]]; then printf '%s\n' "$hit"; found=1; fi
      done
    fi
  done
  [ "$found" -eq 1 ] || warn "No matching $label for '$choice'." >&2
}

# ---------------------------------------------------------------------------
# Dump: ExpressRoute circuit
# ---------------------------------------------------------------------------
dump_er() {
  local cn="$1"
  echo ""
  echo "===================================================================="
  echo "  ExpressRoute circuit: $cn"
  echo "===================================================================="

  local raw
  raw="$(az network express-route show -g "$RESOURCE_GROUP" -n "$cn" -o json 2>/dev/null || echo '{}')"
  save_raw "er-show" "$cn" "$raw"
  echo "$raw" | jq -r '
    "  Name            : " + (.name // "-"),
    "  SKU             : " + ((.sku.tier // "-") + "/" + (.sku.family // "-")),
    "  Provider        : " + (.serviceProviderProperties.serviceProviderName // "-"),
    "  PeeringLocation : " + (.serviceProviderProperties.peeringLocation // "-"),
    "  BandwidthMbps   : " + ((.serviceProviderProperties.bandwidthInMbps // 0) | tostring),
    "  CircuitState    : " + (.circuitProvisioningState // "-"),
    "  ProviderState   : " + (.serviceProviderProvisioningState // "-")
  '

  local pstate
  pstate="$(echo "$raw" | jq -r '.serviceProviderProvisioningState // ""')"
  if [[ "$pstate" != "Provisioned" ]]; then
    warn "Circuit is not 'Provisioned' yet — BGP route tables are unavailable."
    return 0
  fi

  local peering="AzurePrivatePeering" path rt
  for path in primary secondary; do
    echo "  --- Route table summary ($peering / $path) ---"
    if rt="$(az network express-route list-route-tables-summary -g "$RESOURCE_GROUP" -n "$cn" \
              --peering-name "$peering" --path "$path" -o json 2>/dev/null)"; then
      save_raw "er-summary-$path" "$cn" "$rt"
      if [[ -n "$(echo "$rt" | jq -r '.value // [] | .[]?' 2>/dev/null)" ]]; then
        { printf 'Neighbor\tV\tAS\tUpDown\tStatePfxRcd\n'
          echo "$rt" | jq -r '.value[]? | [(.neighbor//"-"),(.v//"-"|tostring),(.asn//"-"|tostring),(.upDown//"-"),(.statePfxRcd//"-")] | @tsv'
        } | column -t -s "$(printf '\t')" | sed 's/^/    /'
      else
        echo "    (no summary returned)"
      fi
    else
      echo "    (route table summary unavailable)"
    fi

    echo "  --- Route table ($peering / $path) ---"
    if rt="$(az network express-route list-route-tables -g "$RESOURCE_GROUP" -n "$cn" \
              --peering-name "$peering" --path "$path" -o json 2>/dev/null)"; then
      save_raw "er-routetable-$path" "$cn" "$rt"
      if [[ -n "$(echo "$rt" | jq -r '.value // [] | .[]?' 2>/dev/null)" ]]; then
        { printf 'Network\tNextHop\tLocPrf\tWeight\tPath\n'
          echo "$rt" | jq -r '.value[]? | [(.network//"-"),(.nextHop//"-"),(.locPrf//"-"|tostring),(.weight//"-"|tostring),(.path//"-")] | @tsv'
        } | column -t -s "$(printf '\t')" | sed 's/^/    /'
      else
        echo "    (no routes returned)"
      fi
    else
      echo "    (route table unavailable)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dump: Virtual Hub (Azure Firewall effective routes)
# ---------------------------------------------------------------------------
dump_vhub() {
  local hn="$1"
  echo ""
  echo "===================================================================="
  echo "  Virtual Hub: $hn"
  echo "===================================================================="

  local hubraw pref prefix
  hubraw="$(az network vhub show -g "$RESOURCE_GROUP" -n "$hn" -o json 2>/dev/null || echo '{}')"
  pref="$(echo "$hubraw" | jq -r '.hubRoutingPreference // "(unknown)"')"
  prefix="$(echo "$hubraw" | jq -r '.addressPrefix // "-"')"
  printf '  Hub Route Preference : %s\n' "$pref"
  printf '  Address prefix       : %s\n' "$prefix"
  echo ""

  # Resolve the hub's Azure Firewall (naming: <hub>-azfw).
  local fwName="$hn-azfw" fwId
  fwId="$(az network firewall show -g "$RESOURCE_GROUP" -n "$fwName" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$fwId" ]]; then
    # Fall back: find any firewall whose virtualHub points at this hub.
    local fwlist
    fwlist="$(az network firewall list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
    fwId="$(echo "$fwlist" | jq -r --arg h "$hn" '.[] | select((.virtualHub.id // "" | split("/") | last) == $h) | .id' | head -n1)"
    [[ -n "$fwId" ]] && fwName="$(leaf "$fwId")"
  fi
  if [[ -z "$fwId" ]]; then
    warn "No Azure Firewall found for hub '$hn' — skipping firewall effective routes."
    return 0
  fi

  echo "  Effective Routes  ->  Resource type: Azure Firewall  ($fwName)"
  log "Querying firewall effective routes (this can take ~30-60s)..."

  # NOTE: the portal sends virtualWanResourceType="AzureFirewalls" (plural).
  # The singular form returns an empty set. get-effective-routes is async; the
  # CLI polls automatically.
  local raw cnt
  raw="$(az network vhub get-effective-routes -g "$RESOURCE_GROUP" --name "$hn" \
          --resource-type AzureFirewalls --resource-id "$fwId" -o json 2>/dev/null || echo '{}')"
  save_raw "vhub-fw-effective" "$hn" "$raw"

  cnt="$(echo "$raw" | jq -r '.value // [] | length')"
  if [[ "$cnt" == "0" || -z "$cnt" ]]; then
    echo "  (no effective routes returned)"
    return 0
  fi

  # Render the exact portal columns: Prefix | Next Hop Type | Next Hop | Origin | AS path
  {
    printf 'Prefix\tNext Hop Type\tNext Hop\tOrigin\tAS path\n'
    echo "$raw" | jq -r '
      .value[] | [
        ((.addressPrefixes // []) | join(", ")),
        (.nextHopType // "-"),
        ((.nextHops // []) | (if length > 0 then (.[0] | split("/") | last) else "-" end)),
        ((.routeOrigin // "-") | split("/") | last),
        (.asPath // "-")
      ] | @tsv'
  } | column -t -s "$(printf '\t')" | sed 's/^/  /'
  printf '  (%s route(s))\n' "$cnt"
}

# ---------------------------------------------------------------------------
# Dump: VM NIC effective route table
# ---------------------------------------------------------------------------
dump_vm() {
  local vn="$1"
  echo ""
  echo "===================================================================="
  echo "  Virtual Machine: $vn"
  echo "===================================================================="

  local power
  power="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$vn" \
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>/dev/null || true)"
  printf '  Power state : %s\n' "${power:-(unknown)}"
  if [[ -n "$power" && "$power" != "PowerState/running" ]]; then
    warn "VM is not running — effective routes are unavailable. Start the VM and retry."
    return 0
  fi

  local nicId
  nicId="$(az vm show -g "$RESOURCE_GROUP" -n "$vn" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$nicId" ]]; then
    warn "Could not resolve a NIC for VM '$vn'."
    return 0
  fi

  log "Querying NIC effective route table (this can take ~30-60s)..."
  local raw cnt
  raw="$(az network nic show-effective-route-table --ids "$nicId" -o json 2>/dev/null || echo '{}')"
  save_raw "vm-effective" "$vn" "$raw"

  cnt="$(echo "$raw" | jq -r '.value // [] | length')"
  if [[ "$cnt" == "0" || -z "$cnt" ]]; then
    echo "  (no effective routes returned)"
    return 0
  fi

  {
    printf 'Source\tState\tAddress Prefix\tNext Hop Type\tNext Hop IP\n'
    echo "$raw" | jq -r '
      .value[] | [
        (.source // "-"),
        (.state // "-"),
        ((.addressPrefix // []) | join(", ")),
        (.nextHopType // "-"),
        ((.nextHopIpAddress // []) | if length > 0 then join(", ") else "-" end)
      ] | @tsv'
  } | column -t -s "$(printf '\t')" | sed 's/^/  /'
  printf '  (%s route(s))\n' "$cnt"
}

# ---------------------------------------------------------------------------
# Category selection
# ---------------------------------------------------------------------------
if [[ -z "$COMPONENT" ]]; then
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    COMPONENT="all"
  else
    echo ""
    echo "  What would you like to dump?"
    echo "    [1] ExpressRoute circuit routes"
    echo "    [2] Virtual Hub firewall effective routes (+ route preference)"
    echo "    [3] VM effective routes (NIC)"
    echo "    [4] All of the above"
    read -rp "  Select [1-4]: " sel
    case "$sel" in
      1) COMPONENT="er" ;;
      2) COMPONENT="vhub" ;;
      3) COMPONENT="vm" ;;
      *) COMPONENT="all" ;;
    esac
  fi
fi

DO_ER=0; DO_HUB=0; DO_VM=0
case "$COMPONENT" in
  er)   DO_ER=1 ;;
  vhub) DO_HUB=1 ;;
  vm)   DO_VM=1 ;;
  all)  DO_ER=1; DO_HUB=1; DO_VM=1 ;;
  *)    echo "Unknown component: $COMPONENT" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# ExpressRoute
# ---------------------------------------------------------------------------
if [[ "$DO_ER" -eq 1 ]]; then
  log "Discovering ExpressRoute circuits..."
  mapfile -t ER_NAMES < <(az network express-route list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || true)
  if [[ ${#ER_NAMES[@]} -eq 0 ]]; then
    echo "  No ExpressRoute circuits found in '$RESOURCE_GROUP'."
  else
    pre="all"; [[ "$COMPONENT" == "er" ]] && pre="$TARGET"
    mapfile -t PICK < <(select_items "ExpressRoute circuit(s)" "$pre" "${ER_NAMES[@]}")
    for c in "${PICK[@]}"; do dump_er "$c"; done
  fi
fi

# ---------------------------------------------------------------------------
# Virtual Hubs
# ---------------------------------------------------------------------------
if [[ "$DO_HUB" -eq 1 ]]; then
  log "Discovering Virtual Hubs..."
  mapfile -t HUB_NAMES < <(az network vhub list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || true)
  if [[ ${#HUB_NAMES[@]} -eq 0 ]]; then
    echo "  No Virtual Hubs found in '$RESOURCE_GROUP'."
  else
    pre="all"; [[ "$COMPONENT" == "vhub" ]] && pre="$TARGET"
    mapfile -t PICK < <(select_items "Virtual Hub(s)" "$pre" "${HUB_NAMES[@]}")
    for h in "${PICK[@]}"; do dump_vhub "$h"; done
  fi
fi

# ---------------------------------------------------------------------------
# VMs
# ---------------------------------------------------------------------------
if [[ "$DO_VM" -eq 1 ]]; then
  log "Discovering Virtual Machines..."
  mapfile -t VM_NAMES < <(az vm list -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || true)
  if [[ ${#VM_NAMES[@]} -eq 0 ]]; then
    echo "  No Virtual Machines found in '$RESOURCE_GROUP'."
  else
    pre="all"; [[ "$COMPONENT" == "vm" ]] && pre="$TARGET"
    mapfile -t PICK < <(select_items "Virtual Machine(s)" "$pre" "${VM_NAMES[@]}")
    for v in "${PICK[@]}"; do dump_vm "$v"; done
  fi
fi

echo ""
log "Done."
