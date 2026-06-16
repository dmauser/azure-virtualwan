#!/usr/bin/env bash
# =============================================================================
# Script : connect-er.sh
# Lab    : svh-dynamic-er-ri — Dynamic Secured Virtual WAN (N hubs, ER, AzFW Basic, RI)
# Purpose: Standalone post-provisioning script to connect already-provisioned
#          ExpressRoute circuits to vHub ER gateways. Safe to re-run (idempotent).
#
# Usage  :
#   ./connect-er.sh -g <rg>                        # interactive hub selection
#   ./connect-er.sh -g <rg> --non-interactive \
#     --circuit-hub-map "er1=hub1,er2=hub2"         # fully automated
#   LAB_CIRCUIT_HUB_MAP="er1=hub1" LAB_NON_INTERACTIVE=1 ./connect-er.sh -g <rg>
#
# Options:
#   -g|--resource-group <rg>   Resource group name. Required (prompted if omitted).
#   --subscription <sub>       Azure subscription ID or name (optional).
#   --circuit-hub-map <map>    "circuit=hub,circuit=hub" pairs. Also: LAB_CIRCUIT_HUB_MAP.
#   --non-interactive          Skip prompts. Also: LAB_NON_INTERACTIVE=1.
#   --max-wait-min <n>         Max minutes to wait per connection (default: 20).
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
      openssl)   echo "  - openssl:           install via your OS package manager" >&2 ;;
      python3)   echo "  - python3:           https://www.python.org/downloads/" >&2 ;;
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
lab_require_tools az

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Timestamp every progress line so stalls are obvious in terminal output.
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Defaults / env fallbacks
# ---------------------------------------------------------------------------
RESOURCE_GROUP=""
SUBSCRIPTION=""
CIRCUIT_HUB_MAP="${LAB_CIRCUIT_HUB_MAP:-}"
NON_INTERACTIVE="${LAB_NON_INTERACTIVE:-0}"
MAX_WAIT_MIN=20
HAS_FAILURE=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
    --subscription)       SUBSCRIPTION="$2";   shift 2 ;;
    --circuit-hub-map)    CIRCUIT_HUB_MAP="$2"; shift 2 ;;
    --non-interactive)    NON_INTERACTIVE=1;    shift ;;
    --max-wait-min)       MAX_WAIT_MIN="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -n "$CIRCUIT_HUB_MAP" ]]; then NON_INTERACTIVE=1; fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  read -rp "Enter resource group name: " RESOURCE_GROUP
fi

# ---------------------------------------------------------------------------
# Helper: look up hub in CIRCUIT_HUB_MAP for a given circuit name
# Usage: get_hub_for_circuit <circuit_name>
# Prints the hub name if found, empty string otherwise.
# ---------------------------------------------------------------------------
get_hub_for_circuit() {
  local circuit="$1"
  local pair k v result=""
  local IFS=','
  for pair in $CIRCUIT_HUB_MAP; do
    k="${pair%%=*}"; k="${k// /}"
    v="${pair#*=}";  v="${v// /}"
    if [[ "$k" == "$circuit" ]]; then
      result="$v"
      break
    fi
  done
  echo "$result"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║   svh-dynamic-er-ri — Connect ER Circuits to vHub Gateways          ║"
echo "║   Standalone post-provisioning script (idempotent)                  ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Subscription context
# ---------------------------------------------------------------------------
if [[ -n "$SUBSCRIPTION" ]]; then
  log "Setting subscription: $SUBSCRIPTION"
  az account set --subscription "$SUBSCRIPTION"
fi

# Pre-warm: consume any first-run az banner so it doesn't pollute captured output.
az account show >/dev/null 2>&1 || true

log "Resource group : $RESOURCE_GROUP"
echo ""

# ---------------------------------------------------------------------------
# Discover ER circuits
# ---------------------------------------------------------------------------
log "Discovering ExpressRoute circuits in '$RESOURCE_GROUP'..."
mapfile -t circuit_names < <(az network express-route list \
  -g "$RESOURCE_GROUP" --query '[].name' -o tsv 2>/dev/null || true)

# Remove any blank entries that tsv output might produce
filtered=()
for c in "${circuit_names[@]+"${circuit_names[@]}"}"; do
  [[ -n "$c" ]] && filtered+=("$c")
done
circuit_names=("${filtered[@]+"${filtered[@]}"}")

if [[ ${#circuit_names[@]} -eq 0 ]]; then
  echo "  No ExpressRoute circuits found in '$RESOURCE_GROUP'. Nothing to do."
  exit 0
fi
echo "  Found ${#circuit_names[@]} circuit(s): ${circuit_names[*]}"
echo ""

# ---------------------------------------------------------------------------
# Discover vHubs (names and locations in parallel arrays)
# ---------------------------------------------------------------------------
log "Discovering vHubs in '$RESOURCE_GROUP'..."
hub_names=()
hub_locations=()
while IFS=$'\t' read -r hname hloc; do
  [[ -n "$hname" ]] && hub_names+=("$hname") && hub_locations+=("$hloc")
done < <(az network vhub list -g "$RESOURCE_GROUP" \
  --query '[].[name, location]' -o tsv 2>/dev/null || true)

if [[ ${#hub_names[@]} -eq 0 ]]; then
  echo "  No vHubs found in '$RESOURCE_GROUP'. Cannot create connections."
  exit 1
fi
echo "  Found ${#hub_names[@]} hub(s): ${hub_names[*]}"
echo ""

# ---------------------------------------------------------------------------
# Summary tracking arrays (parallel)
# ---------------------------------------------------------------------------
sum_circuits=()
sum_hubs=()
sum_gateways=()
sum_connections=()
sum_results=()

# ---------------------------------------------------------------------------
# Process each circuit
# ---------------------------------------------------------------------------
for cn in "${circuit_names[@]}"; do
  echo "────────────────────────────────────────────────────────────────────"
  prov_state=$(az network express-route show -g "$RESOURCE_GROUP" -n "$cn" \
    --query serviceProviderProvisioningState -o tsv 2>/dev/null || echo "Unknown")
  log "Circuit: $cn  (serviceProviderProvisioningState = $prov_state)"

  if [[ "$prov_state" != "Provisioned" ]]; then
    warn "Circuit $cn is '$prov_state' — provider side not complete yet, skipping."
    sum_circuits+=("$cn"); sum_hubs+=("-"); sum_gateways+=("-")
    sum_connections+=("-"); sum_results+=("Skipped ($prov_state)")
    continue
  fi

  # ----- Determine target hub -----
  target_hub=""
  if [[ "$NON_INTERACTIVE" == "1" ]]; then
    target_hub=$(get_hub_for_circuit "$cn")
    if [[ -z "$target_hub" ]]; then
      warn "Circuit '$cn' not found in --circuit-hub-map — skipping."
      sum_circuits+=("$cn"); sum_hubs+=("-"); sum_gateways+=("-")
      sum_connections+=("-"); sum_results+=("Skipped (no map entry)")
      continue
    fi
    echo "  Target hub (from map): $target_hub"
  else
    echo ""
    echo "  Available hubs:"
    for i in "${!hub_names[@]}"; do
      echo "    $((i+1))) ${hub_names[$i]} (${hub_locations[$i]})"
    done
    hub_choice_input=""
    read -rp "  Connect $cn to which hub number? [1]: " hub_choice_input
    hub_choice_input="${hub_choice_input:-1}"
    hi=$((hub_choice_input - 1))
    target_hub="${hub_names[$hi]}"
    echo "  Target hub: $target_hub"
  fi

  ergw_name="${target_hub}-ergw"
  conn_name="${target_hub}-conn-to-${cn}"

  # ----- Idempotency: check if connection already exists -----
  existing_conn=$(az network express-route gateway connection list \
    --gateway-name "$ergw_name" -g "$RESOURCE_GROUP" \
    --query "[?name=='${conn_name}'] | [0].name" -o tsv 2>/dev/null || true)

  if [[ -n "$existing_conn" ]]; then
    echo "  Connection '$conn_name' already exists — skipping."
    sum_circuits+=("$cn"); sum_hubs+=("$target_hub"); sum_gateways+=("$ergw_name")
    sum_connections+=("$conn_name"); sum_results+=("AlreadyConnected")
    continue
  fi

  # ----- Ensure ER gateway exists -----
  ergw_state=$(az network express-route gateway show -g "$RESOURCE_GROUP" -n "$ergw_name" \
    --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
  if [[ "$ergw_state" != "Succeeded" ]]; then
    hub_location=""
    for i in "${!hub_names[@]}"; do
      [[ "${hub_names[$i]}" == "$target_hub" ]] && hub_location="${hub_locations[$i]}" && break
    done
    echo "  Creating ER gateway $ergw_name in $target_hub ($hub_location)..."
    az network express-route gateway create \
      -g "$RESOURCE_GROUP" -n "$ergw_name" \
      --location "$hub_location" \
      --min-val 1 \
      --virtual-hub "$target_hub" \
      -o none
    ergw_iter=0; ergw_max=40   # 40 × 15 s = 10 min
    while true; do
      ergw_iter=$((ergw_iter + 1))
      if [[ $ergw_iter -gt $ergw_max ]]; then
        log "  WARNING: ER-gateway poll timed out for $ergw_name after $ergw_max iterations — continuing."
        break
      fi
      ergw_state=$(az network express-route gateway show -g "$RESOURCE_GROUP" -n "$ergw_name" \
        --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
      log "  $ergw_name = $ergw_state"
      [[ "$ergw_state" == "Succeeded" ]] && break
      sleep 15
    done
  else
    echo "  ER gateway $ergw_name already Succeeded ✔"
  fi

  # ----- Get peering id -----
  peering=$(az network express-route show -g "$RESOURCE_GROUP" -n "$cn" \
    --query 'peerings[0].id' -o tsv 2>/dev/null || true)
  if [[ -z "$peering" ]]; then
    warn "No AzurePrivatePeering found on '$cn' — skipping."
    sum_circuits+=("$cn"); sum_hubs+=("$target_hub"); sum_gateways+=("$ergw_name")
    sum_connections+=("$conn_name"); sum_results+=("Failed (no peering)")
    HAS_FAILURE=1
    continue
  fi

  # ----- Detect Routing Intent on the hub -----
  # When a hub has Routing Intent configured, the ER connection MUST be created
  # WITHOUT associated/propagated route-table or labels — Routing Intent
  # auto-populates the routing configuration. Passing them triggers
  # ConnectionRoutingConfigConflictsWithRoutingIntent. Every hub in this lab uses
  # Routing Intent, so we branch on its presence to stay correct either way.
  ri_state=$(az network vhub routing-intent show \
    -g "$RESOURCE_GROUP" --vhub "$target_hub" -n "${target_hub}-ri" \
    --query provisioningState -o tsv 2>/dev/null || true)

  # ----- Create the ER gateway connection -----
  log "  Creating connection: $conn_name..."
  if [[ -n "$ri_state" ]]; then
    echo "  Routing Intent detected on $target_hub — leaving route config empty (auto-populated)."
    create_ok=1
    az network express-route gateway connection create \
      --name "$conn_name" \
      -g "$RESOURCE_GROUP" \
      --gateway-name "$ergw_name" \
      --peering "$peering" \
      -o none || create_ok=0
  else
    # No Routing Intent — explicitly associate/propagate the default route table.
    rtid=$(az network vhub route-table show \
      --name defaultRouteTable \
      --vhub-name "$target_hub" \
      -g "$RESOURCE_GROUP" \
      --query id -o tsv 2>/dev/null)
    create_ok=1
    az network express-route gateway connection create \
      --name "$conn_name" \
      -g "$RESOURCE_GROUP" \
      --gateway-name "$ergw_name" \
      --peering "$peering" \
      --associated-route-table "$rtid" \
      --propagated-route-tables "$rtid" \
      --labels default \
      -o none || create_ok=0
  fi
  if [[ "$create_ok" -ne 1 ]]; then
    echo "  [ERROR] Failed to create connection '$conn_name'."
    sum_circuits+=("$cn"); sum_hubs+=("$target_hub"); sum_gateways+=("$ergw_name")
    sum_connections+=("$conn_name"); sum_results+=("Failed (create error)")
    HAS_FAILURE=1
    continue
  fi

  # ----- Poll provisioningState to Succeeded -----
  conn_poll_max=$(( MAX_WAIT_MIN * 2 ))   # iterations (30 s each)
  [[ $conn_poll_max -lt 1 ]] && conn_poll_max=1
  er_conn_iter=0
  conn_result="Failed (timeout)"
  while true; do
    er_conn_iter=$((er_conn_iter + 1))
    if [[ $er_conn_iter -gt $conn_poll_max ]]; then
      log "  WARNING: ER-connection poll timed out for $conn_name after $conn_poll_max iterations — continuing."
      break
    fi
    conn_state=$(az network express-route gateway connection show \
      --name "$conn_name" \
      -g "$RESOURCE_GROUP" \
      --gateway-name "$ergw_name" \
      --query provisioningState -o tsv 2>/dev/null || echo "Unknown")
    log "  $conn_name = $conn_state"
    if [[ "$conn_state" == "Succeeded" ]]; then conn_result="Connected"; break; fi
    if [[ "$conn_state" == "Failed" ]];    then conn_result="Failed";    break; fi
    sleep 30
  done

  echo "  $conn_name → $conn_result"
  [[ "$conn_result" != "Connected" ]] && HAS_FAILURE=1

  sum_circuits+=("$cn"); sum_hubs+=("$target_hub"); sum_gateways+=("$ergw_name")
  sum_connections+=("$conn_name"); sum_results+=("$conn_result")
done

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " Summary"
echo "══════════════════════════════════════════════════════════════════════"
printf "%-28s %-22s %-28s %-38s %-22s\n" \
  "Circuit" "Hub" "Gateway" "Connection" "Result"
printf "%-28s %-22s %-28s %-38s %-22s\n" \
  "-------" "---" "-------" "----------" "------"
for i in "${!sum_circuits[@]}"; do
  printf "%-28s %-22s %-28s %-38s %-22s\n" \
    "${sum_circuits[$i]}" "${sum_hubs[$i]}" "${sum_gateways[$i]}" \
    "${sum_connections[$i]}" "${sum_results[$i]}"
done
echo ""

if [[ $HAS_FAILURE -eq 1 ]]; then
  log "Completed with one or more failures — check the rows marked 'Failed' above."
  exit 1
else
  log "All circuits processed successfully."
  exit 0
fi
