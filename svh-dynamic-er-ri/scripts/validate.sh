#!/usr/bin/env bash
# =============================================================================
# Script : validate.sh
# Lab    : svh-dynamic-er-ri — Dynamic Secured Virtual WAN (N hubs, ER, AzFW Basic, RI)
# Purpose: Validate every deployed resource and print [PASS]/[FAIL] for each check.
#          Works for any number of hubs; discovers everything via az list calls.
# Usage  : ./validate.sh [resource-group]   (prompts if omitted)
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
lab_require_tools az python3

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
pass_count=0
fail_count=0

ok()   { echo "  $PASS $*"; (( pass_count++ )) || true; }
fail() { echo "  $FAIL $*"; (( fail_count++ )) || true; }
warn() { echo "  $WARN $*"; }
hdr()  { echo ""; echo "###############################################################"; echo "# $*"; echo "###############################################################"; }
# Timestamp every progress line so stalls are obvious in terminal output.
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
if [[ -n "${1:-}" ]]; then
    rg="$1"
else
    read -rp "Enter resource group name: " rg
fi
echo ""
echo "Resource group : $rg"
echo "============================================================="

# ---------------------------------------------------------------------------
# Pre-flight: ensure the CLI extensions used by this script are present and
# consume the one-time az first-run banner (printed to STDOUT against a fresh
# config dir; would otherwise pollute the first captured query result such as
# the Virtual WAN name).
# ---------------------------------------------------------------------------
az extension add --name virtual-wan --upgrade -o none 2>/dev/null || true
az extension add --name azure-firewall --upgrade -o none 2>/dev/null || true
az account show >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Section 1 — Virtual WAN
# ---------------------------------------------------------------------------
hdr "1. Virtual WAN"
vwan_name=$(az network vwan list -g "$rg" --query "[0].name" -o tsv 2>/dev/null)
if [[ -z "$vwan_name" ]]; then
    fail "No Virtual WAN found in resource group $rg"
    echo ""
    echo "TOTAL: $pass_count passed / $fail_count failed"
    exit 1
fi
vwan_type=$(az network vwan show -g "$rg" -n "$vwan_name" --query "type_" -o tsv 2>/dev/null)
vwan_sku=$(az network vwan show -g "$rg" -n "$vwan_name" --query "typePropertiesType" -o tsv 2>/dev/null)
ok "Virtual WAN found: $vwan_name"
if [[ "$vwan_sku" == "Standard" ]]; then
    ok "  SKU = Standard"
else
    fail "  SKU = $vwan_sku  (expected Standard)"
fi

# ---------------------------------------------------------------------------
# Discover all hubs
# ---------------------------------------------------------------------------
hubs=()
while IFS= read -r h; do
    [[ -n "$h" ]] && hubs+=("$h")
done < <(az network vhub list -g "$rg" --query "[].name" -o tsv 2>/dev/null | sort)

if [[ ${#hubs[@]} -eq 0 ]]; then
    fail "No vHubs found in resource group $rg"
    echo ""
    echo "TOTAL: $pass_count passed / $fail_count failed"
    exit 1
fi
echo "  Discovered ${#hubs[@]} hub(s): ${hubs[*]}"

# ---------------------------------------------------------------------------
# Section 2 — vHub provisioning state + routingState
# ---------------------------------------------------------------------------
hdr "2. vHub Provisioning State"
for hub in "${hubs[@]}"; do
    provState=$(az network vhub show -g "$rg" -n "$hub" \
        --query "provisioningState" -o tsv 2>/dev/null)
    rtState=$(az network vhub show -g "$rg" -n "$hub" \
        --query "routingState" -o tsv 2>/dev/null)
    if [[ "$provState" == "Succeeded" ]]; then
        ok "$hub provisioningState=$provState"
    else
        fail "$hub provisioningState=$provState  (expected Succeeded)"
    fi
    if [[ "$rtState" == "Provisioned" ]]; then
        ok "$hub routingState=$rtState"
    else
        fail "$hub routingState=$rtState  (expected Provisioned)"
    fi
done

# ---------------------------------------------------------------------------
# Section 3 — hubRoutingPreference == ExpressRoute
# ---------------------------------------------------------------------------
hdr "3. Hub Routing Preference (expected: ExpressRoute)"
for hub in "${hubs[@]}"; do
    hrp=$(az network vhub show -g "$rg" -n "$hub" \
        --query "hubRoutingPreference" -o tsv 2>/dev/null)
    if [[ "$hrp" == "ExpressRoute" ]]; then
        ok "$hub hubRoutingPreference=$hrp"
    else
        fail "$hub hubRoutingPreference=$hrp  (expected ExpressRoute)"
    fi
done

# ---------------------------------------------------------------------------
# Section 4 — Azure Firewall per hub
# ---------------------------------------------------------------------------
hdr "4. Azure Firewall per Hub"
declare -A hub_fw_id
for hub in "${hubs[@]}"; do
    # Naming contract: ${hub}-azfw
    fw_name="${hub}-azfw"
    fw_state=$(az network firewall show -g "$rg" -n "$fw_name" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    fw_id=$(az network firewall show -g "$rg" -n "$fw_name" \
        --query "id" -o tsv 2>/dev/null || true)
    if [[ "$fw_state" == "Succeeded" ]]; then
        ok "$fw_name exists (provisioningState=$fw_state)"
        hub_fw_id["$hub"]="$fw_id"
    else
        fail "$fw_name not found or not Succeeded (state='$fw_state')"
        hub_fw_id["$hub"]=""
    fi
done

# ---------------------------------------------------------------------------
# Section 5 — Firewall policy per hub
# ---------------------------------------------------------------------------
hdr "5. Firewall Policy per Hub"
declare -A hub_policy
for hub in "${hubs[@]}"; do
    pol_name="${hub}-fwpolicy"
    pol_state=$(az network firewall policy show -g "$rg" -n "$pol_name" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [[ "$pol_state" == "Succeeded" ]]; then
        ok "$pol_name exists (provisioningState=$pol_state)"
        hub_policy["$hub"]="$pol_name"
    else
        fail "$pol_name not found or not Succeeded (state='$pol_state')"
        hub_policy["$hub"]=""
    fi
done

# ---------------------------------------------------------------------------
# Section 6 — Rule collection group + allow-all rule
# ---------------------------------------------------------------------------
hdr "6. Firewall Policy Rule Collection Group + allow-all Rule"
for hub in "${hubs[@]}"; do
    pol_name="${hub_policy[$hub]:-}"
    if [[ -z "$pol_name" ]]; then
        warn "$hub: policy not found, skipping RCG check"
        continue
    fi
    rcg_name="default-allow-all-rcg"
    rcg_state=$(az network firewall policy rule-collection-group show \
        -g "$rg" --policy-name "$pol_name" -n "$rcg_name" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [[ "$rcg_state" == "Succeeded" ]]; then
        ok "$pol_name / $rcg_name exists (provisioningState=$rcg_state)"
    else
        fail "$pol_name / $rcg_name not found (state='$rcg_state')"
        continue
    fi

    # Verify allow-all rule: Action=Allow, src=*, dst=*, proto=Any, ports=*
    rule_json=$(az network firewall policy rule-collection-group show \
        -g "$rg" --policy-name "$pol_name" -n "$rcg_name" \
        --query "ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]" \
        -o json 2>/dev/null || true)

    if [[ -z "$rule_json" || "$rule_json" == "null" ]]; then
        fail "$pol_name / $rcg_name: 'allow-all' rule not found in 'allow-all-network' collection"
        continue
    fi

    rule_proto=$(echo "$rule_json" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('ipProtocols',[''])[0])" 2>/dev/null || true)
    rule_src=$(echo "$rule_json"   | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('sourceAddresses',[''])[0])" 2>/dev/null || true)
    rule_dst=$(echo "$rule_json"   | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('destinationAddresses',[''])[0])" 2>/dev/null || true)
    rule_port=$(echo "$rule_json"  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('destinationPorts',[''])[0])" 2>/dev/null || true)

    rule_ok=true
    [[ "$rule_proto" == "Any" ]] || rule_ok=false
    [[ "$rule_src"   == "*"   ]] || rule_ok=false
    [[ "$rule_dst"   == "*"   ]] || rule_ok=false
    [[ "$rule_port"  == "*"   ]] || rule_ok=false

    if $rule_ok; then
        ok "$pol_name: allow-all rule: proto=Any src=* dst=* ports=* [ALLOW]"
    else
        fail "$pol_name: allow-all rule mismatch — proto=$rule_proto src=$rule_src dst=$rule_dst ports=$rule_port"
    fi
done

# ---------------------------------------------------------------------------
# Section 7 — Routing Intent per hub
# ---------------------------------------------------------------------------
hdr "7. Routing Intent per Hub"
for hub in "${hubs[@]}"; do
    ri_name="${hub}-ri"
    ri_state=$(az network vhub routing-intent show -g "$rg" \
        --vhub "$hub" -n "$ri_name" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [[ "$ri_state" == "Succeeded" ]]; then
        ok "$ri_name provisioningState=$ri_state"
    else
        fail "$ri_name provisioningState='$ri_state'  (expected Succeeded)"
    fi

    echo "     Routing policies for $ri_name:"
    az network vhub routing-intent show -g "$rg" --vhub "$hub" -n "$ri_name" \
        --query "routingPolicies[].{name:name, destinations:destinations, nextHop:nextHop}" \
        -o table 2>/dev/null || true

    # Detect mode: private / internet / both
    has_private=$(az network vhub routing-intent show -g "$rg" --vhub "$hub" -n "$ri_name" \
        --query "length(routingPolicies[?contains(destinations,'PrivateTraffic')])" \
        -o tsv 2>/dev/null || echo "0")
    has_internet=$(az network vhub routing-intent show -g "$rg" --vhub "$hub" -n "$ri_name" \
        --query "length(routingPolicies[?contains(destinations,'Internet')])" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "${has_private:-0}" -gt 0 && "${has_internet:-0}" -gt 0 ]]; then
        echo "     Mode: Private + Internet (both)"
    elif [[ "${has_private:-0}" -gt 0 ]]; then
        echo "     Mode: Private only"
    elif [[ "${has_internet:-0}" -gt 0 ]]; then
        echo "     Mode: Internet only"
    else
        warn "$ri_name: no Private or Internet destinations detected"
    fi
done

# ---------------------------------------------------------------------------
# Section 8 — ER Gateways (optional per hub)
# ---------------------------------------------------------------------------
hdr "8. ExpressRoute Gateways (where deployed)"
declare -A hub_ergw
for hub in "${hubs[@]}"; do
    ergw_name="${hub}-ergw"
    ergw_state=$(az network express-route gateway show -g "$rg" -n "$ergw_name" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [[ "$ergw_state" == "Succeeded" ]]; then
        ok "$ergw_name exists (provisioningState=$ergw_state)"
        hub_ergw["$hub"]="$ergw_name"
    elif [[ -z "$ergw_state" ]]; then
        warn "$ergw_name not found for $hub (hub may be private-only — skipping)"
        hub_ergw["$hub"]=""
    else
        fail "$ergw_name state='$ergw_state'  (expected Succeeded)"
        hub_ergw["$hub"]=""
    fi
done

# ---------------------------------------------------------------------------
# Section 9 — ER Circuits
# ---------------------------------------------------------------------------
hdr "9. ExpressRoute Circuits"
circuits=()
while IFS= read -r c; do
    [[ -n "$c" ]] && circuits+=("$c")
done < <(az network express-route list -g "$rg" --query "[].name" -o tsv 2>/dev/null | sort)

if [[ ${#circuits[@]} -eq 0 ]]; then
    warn "No ExpressRoute circuits found in resource group $rg"
else
    for circuit in "${circuits[@]}"; do
        echo "  --- Circuit: $circuit ---"
        az network express-route show -g "$rg" -n "$circuit" \
            --query "{Name:name, CircuitProvisioningState:circuitProvisioningState, ServiceProviderProvisioningState:serviceProviderProvisioningState, ServiceKey:serviceKey}" \
            -o table 2>/dev/null || true
        circ_prov=$(az network express-route show -g "$rg" -n "$circuit" \
            --query "circuitProvisioningState" -o tsv 2>/dev/null || true)
        if [[ "$circ_prov" == "Enabled" ]]; then
            ok "$circuit circuitProvisioningState=$circ_prov"
        else
            warn "$circuit circuitProvisioningState=$circ_prov  (may be Disabled if circuit not yet provisioned by provider)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Section 10 — ER Gateway connection state
# ---------------------------------------------------------------------------
hdr "10. ExpressRoute Gateway Connections"
any_ergw=false
for hub in "${hubs[@]}"; do
    ergw_name="${hub_ergw[$hub]:-}"
    [[ -z "$ergw_name" ]] && continue
    any_ergw=true
    echo "  --- Connections for gateway: $ergw_name ---"
    conns=$(az network express-route gateway connection list -g "$rg" \
        --gateway-name "$ergw_name" \
        --query "[].{Name:name, ProvisioningState:provisioningState, ConnectionState:connectionStatus}" \
        -o table 2>/dev/null || true)
    if [[ -n "$conns" ]]; then
        echo "$conns"
        while IFS= read -r conn_name; do
            [[ -z "$conn_name" ]] && continue
            conn_state=$(az network express-route gateway connection show -g "$rg" \
                --gateway-name "$ergw_name" -n "$conn_name" \
                --query "provisioningState" -o tsv 2>/dev/null || true)
            if [[ "$conn_state" == "Succeeded" ]]; then
                ok "$ergw_name / $conn_name provisioningState=$conn_state"
            else
                warn "$ergw_name / $conn_name provisioningState='$conn_state'"
            fi
        done < <(az network express-route gateway connection list -g "$rg" \
            --gateway-name "$ergw_name" --query "[].name" -o tsv 2>/dev/null || true)
    else
        warn "$ergw_name: no connections found"
    fi
done
$any_ergw || warn "No ER gateways deployed — skipping connection checks"

# ---------------------------------------------------------------------------
# Section 11 — Spoke VNet hub connections
# ---------------------------------------------------------------------------
hdr "11. Spoke VNet Hub Connections"
for hub in "${hubs[@]}"; do
    echo "  --- Hub: $hub ---"
    az network vhub connection list -g "$rg" --vhub-name "$hub" \
        --query "[].{Name:name, RemoteVNet:remoteVirtualNetwork.id, ProvisioningState:provisioningState, RoutingState:routingConfiguration.vnetRoutes}" \
        -o table 2>/dev/null || true
    conn_count=$(az network vhub connection list -g "$rg" --vhub-name "$hub" \
        --query "length([])" -o tsv 2>/dev/null || echo "0")
    if [[ "${conn_count:-0}" -gt 0 ]]; then
        ok "$hub has $conn_count spoke connection(s)"
    else
        warn "$hub: no spoke connections found"
    fi

    # Assert enableInternetSecurity (Propagate Default Route) for internetOnly/both RI modes.
    has_internet_ri=$(az network vhub routing-intent show -g "$rg" --vhub "$hub" -n "${hub}-ri" \
        --query "length(routingPolicies[?contains(destinations,'Internet')])" \
        -o tsv 2>/dev/null || echo "0")
    if [[ "${has_internet_ri:-0}" -gt 0 ]]; then
        while IFS= read -r conn_name; do
            [[ -z "$conn_name" ]] && continue
            isec_val=$(az network vhub connection show -g "$rg" --vhub-name "$hub" -n "$conn_name" \
                --query enableInternetSecurity -o tsv 2>/dev/null || echo "false")
            if [[ "$isec_val" == "true" ]]; then
                ok "$hub / $conn_name enableInternetSecurity=true (required for internet RI mode)"
            else
                fail "$hub / $conn_name enableInternetSecurity=$isec_val (expected true — internet/both RI mode requires Propagate Default Route)"
            fi
        done < <(az network vhub connection list -g "$rg" --vhub-name "$hub" \
            --query "[].name" -o tsv 2>/dev/null || true)
    fi
done

# ---------------------------------------------------------------------------
# Section 12 — Ubuntu VMs power state
# ---------------------------------------------------------------------------
hdr "12. VM Power State"
vms=()
while IFS= read -r vm; do
    [[ -n "$vm" ]] && vms+=("$vm")
done < <(az vm list -g "$rg" --query "[].name" -o tsv 2>/dev/null | sort)

if [[ ${#vms[@]} -eq 0 ]]; then
    warn "No VMs found in resource group $rg"
else
    echo "  Public IPs:"
    az network public-ip list -g "$rg" \
        --query "[].{Name:name, IP:ipAddress}" -o table 2>/dev/null || true
    echo ""
    echo "  Private IPs:"
    for nicname in $(az network nic list -g "$rg" --query '[].name' -o tsv 2>/dev/null); do
        echo "    $nicname: $(az network nic show -g "$rg" -n "$nicname" \
            --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>/dev/null)"
    done
    echo ""
    for vm in "${vms[@]}"; do
        power=$(az vm get-instance-view -g "$rg" -n "$vm" \
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" \
            -o tsv 2>/dev/null || true)
        if [[ "$power" == "VM running" ]]; then
            ok "$vm powerState='$power'"
        else
            fail "$vm powerState='$power'  (expected 'VM running')"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Section 13 — Effective routes (NIC + vHub route tables + FW routes)
# ---------------------------------------------------------------------------
hdr "13. Effective Routes"

echo ""
echo "  --- NIC Effective Routes ---"
for nicname in $(az network nic list -g "$rg" --query '[].name' -o tsv 2>/dev/null); do
    echo ""
    echo "  === NIC: $nicname ==="
    az network nic show-effective-route-table -g "$rg" --name "$nicname" \
        --output table 2>/dev/null || warn "  Could not retrieve effective routes for $nicname"
done

echo ""
echo "  --- vHub Effective Route Tables ---"
for hub in "${hubs[@]}"; do
    for rt_id in $(az network vhub route-table list --vhub-name "$hub" \
        -g "$rg" --query "[].id" -o tsv 2>/dev/null); do
        rt_name=$(echo "$rt_id" | awk -F'/' '{print $NF}')
        [[ "$rt_name" == "noneRouteTable" ]] && continue
        echo ""
        echo "  === vHub: $hub | RouteTable: $rt_name ==="
        az network vhub get-effective-routes -g "$rg" -n "$hub" \
            --resource-type RouteTable \
            --resource-id "$rt_id" \
            --query "value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}" \
            --output table 2>/dev/null || warn "  Could not retrieve effective routes for $hub / $rt_name"
    done
done

echo ""
echo "  --- Azure Firewall Effective Routes per Hub ---"
for hub in "${hubs[@]}"; do
    fw_id="${hub_fw_id[$hub]:-}"
    [[ -z "$fw_id" ]] && continue
    fw_name="${hub}-azfw"
    echo ""
    echo "  === vHub: $hub | Firewall: $fw_name ==="
    az network vhub get-effective-routes -g "$rg" -n "$hub" \
        --resource-type AzureFirewalls \
        --resource-id "$fw_id" \
        --query "value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}" \
        --output table 2>/dev/null || warn "  Could not retrieve firewall effective routes for $hub"
done

# ---------------------------------------------------------------------------
# Section 14 — Hub connection status
# ---------------------------------------------------------------------------
hdr "14. Hub Connection Status"
for hub in "${hubs[@]}"; do
    echo ""
    echo "  === Hub: $hub ==="
    az network vhub connection list -g "$rg" --vhub-name "$hub" \
        --query "[].{Name:name, ProvisioningState:provisioningState}" \
        -o table 2>/dev/null || warn "  Could not list connections for $hub"
done

# ---------------------------------------------------------------------------
# Section 15 — Connectivity test hints
# ---------------------------------------------------------------------------
hdr "15. Connectivity Test Hints"
echo ""
echo "  Private IPs of spoke VMs:"
for vm in "${vms[@]:-}"; do
    [[ -z "$vm" ]] && continue
    priv_ip=$(az vm list-ip-addresses -g "$rg" -n "$vm" \
        --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)
    pub_ip=$(az vm list-ip-addresses -g "$rg" -n "$vm" \
        --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || true)
    echo "    $vm: private=$priv_ip  public=$pub_ip"
done

echo ""
echo "  Install tools on each VM if missing:"
echo "    sudo apt-get install -y traceroute iputils-ping curl"
echo ""
echo "  Cross-spoke ping (from any VM):"
for vm in "${vms[@]:-}"; do
    [[ -z "$vm" ]] && continue
    priv_ip=$(az vm list-ip-addresses -g "$rg" -n "$vm" \
        --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)
    [[ -n "$priv_ip" ]] && echo "    ping $priv_ip   # $vm"
done

echo ""
echo "  NOTE: Under Routing Intent (private), ALL inter-spoke/inter-hub traffic"
echo "        traverses the Azure Firewall of the SOURCE hub. Use traceroute to"
echo "        verify the firewall private IP appears in the path."
echo "  NOTE: Under Routing Intent (internet), Internet-bound traffic also traverses"
echo "        the hub Azure Firewall. Check portal FW logs if access is blocked."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hdr "SUMMARY"
total=$((pass_count + fail_count))
echo "  $pass_count / $total checks passed"
echo "  $fail_count / $total checks failed"
echo ""
if [[ $fail_count -eq 0 ]]; then
    echo "  [ALL CHECKS PASSED] Lab deployment looks healthy."
else
    echo "  [ATTENTION] $fail_count check(s) failed. Review [FAIL] items above."
fi
echo ""
