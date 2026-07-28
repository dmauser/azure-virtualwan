#!/usr/bin/env bash
# =============================================================================
# validate-flow.sh — READ-ONLY traffic-breakout validation for nva-spoke-internet-paloalto
#
# Traces: Spoke VM -> vHub (0/0 via VirtualNetworkGateway) -> conn-dmz ->
#   ILB 10.0.0.68 (HA-ports) -> Palo Alto VM-Series (NAT MASQUERADE) ->
#   Public LB -> Internet
#
# Adapted from: nva-spoke-internet/scripts/validate-flow.sh
# NVA type:     Palo Alto VM-Series (BYOL, PAN-OS 10.1+)
#
# Phases 1-3 and 5 are IDENTICAL to the Linux NVA validator — they validate
# the Azure control plane and data plane (effective routes, curl egress, LB
# metrics) which are NVA-agnostic.
#
# Phase 4 (NVA forwarding evidence) replaces iptables/conntrack/tcpdump with:
#   - PA management GUI URL discovery (read-only az CLI)
#   - Manual PAN-OS CLI command hints for operator review
#   - Emits WARN (not FAIL) since PA API/CLI access is not provisioned in the lab
#
# READ-ONLY: never creates or modifies Azure resources.
# vm run-command invocations execute read-only commands inside existing VMs.
#
# Usage:
#   ./scripts/validate-flow.sh
#   RESOURCE_GROUP=my-rg HUB=my-hub NVA_NAMES="pa-fw-0 pa-fw-1" ./scripts/validate-flow.sh
#
# References (authoritative):
#   Effective routes (vWAN):   https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
#   Manage route tables:       https://learn.microsoft.com/azure/virtual-network/manage-route-table
#   NW next-hop:               https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
#   NW IP flow verify:         https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
#   NW connectivity:           https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
#   LB monitoring:             https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
#   LB metric reference:       https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
#   Outbound troubleshoot:     https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
#   PAN-OS session commands:   https://docs.paloaltonetworks.com/pan-os/11-1/pan-os-cli-quick-start/use-the-cli/cli-cheat-sheets
# =============================================================================

set -uo pipefail

# Inline log function (no functions.sh dependency)
log() { echo "$(date -u +%H:%M:%S) $*"; }

RG="${RESOURCE_GROUP:-rg-nva-spoke-internet-pa}"
HUB="${HUB:-hub-nva-si}"
# Space-separated list of PA VM names; override to match your Bicep output
NVA_NAMES="${NVA_NAMES:-pa-fw-0 pa-fw-1}"

PASS=0; FAIL=0; WARN=0

# ---- result helpers ----------------------------------------------------------
check_pass() { log "  ✅ PASS  $1"; PASS=$((PASS+1)); }
check_fail() { log "  ❌ FAIL  $1"; FAIL=$((FAIL+1)); }
check_warn() { log "  ⚠️  WARN  $1"; WARN=$((WARN+1)); }

# Extract an IP address from a string (returns first IPv4 match)
extract_ip() { echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d '[:space:]'; }

# =============================================================================
# Phase 1 -- Pre-checks
# =============================================================================
log "=== Phase 1: Pre-checks ==="

if ! az account show --output none 2>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run: az login"
  exit 1
fi
CURRENT_SUB=$(az account show --query '[name,id]' -o tsv | tr '\t' ' / ')
log "  Logged in: $CURRENT_SUB"

if ! az group show -n "$RG" --output none 2>/dev/null; then
  echo "ERROR: Resource group '$RG' not found. Deploy the lab first."
  exit 1
fi
log "  Resource group: $RG"

HUB_ROUTING=$(az network vhub show -g "$RG" -n "$HUB" --query routingState -o tsv 2>/dev/null || echo "NotFound")
if [[ "$HUB_ROUTING" == "Provisioned" ]]; then
  check_pass "Hub '$HUB' routingState = Provisioned"
else
  check_fail "Hub '$HUB' routingState = $HUB_ROUTING (expected Provisioned)"
fi

HUB_ID=$(az network vhub show -g "$RG" -n "$HUB" --query id -o tsv 2>/dev/null || true)
DEFAULT_RT_ID="${HUB_ID}/hubRouteTables/defaultRouteTable"

# =============================================================================
# Phase 2 -- Control-plane
# Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
# =============================================================================
log ""
log "=== Phase 2: Control-plane routes ==="

# 2a. defaultRouteTable: 0.0.0.0/0 -> conn-dmz
log ""
log "  [2a] Hub defaultRouteTable routes:"
DRT=$(az network vhub route-table show \
  -g "$RG" --vhub-name "$HUB" --name defaultRouteTable \
  --query 'routes[].{destinations:destinations,nextHopType:nextHopType,nextHop:nextHop}' \
  -o table 2>/dev/null || echo "ERROR fetching defaultRouteTable")
log "$DRT"
DRT_CHK=$(az network vhub route-table show \
  -g "$RG" --vhub-name "$HUB" --name defaultRouteTable \
  --query "routes[?contains(destinations, '0.0.0.0/0')]" \
  -o tsv 2>/dev/null || echo "")
if [[ -n "$DRT_CHK" && "$DRT_CHK" != ERROR* ]]; then
  check_pass "defaultRouteTable contains 0.0.0.0/0 route"
else
  check_fail "defaultRouteTable missing 0.0.0.0/0 route (routing wiring incomplete)"
fi

# 2b. conn-dmz static route: 0.0.0.0/0 -> 10.0.0.68 (ILB)
log ""
log "  [2b] conn-dmz static routes (expected: 0.0.0.0/0 -> 10.0.0.68):"
CONNROUTES=$(az network vhub connection show \
  -g "$RG" --vhub-name "$HUB" -n conn-dmz \
  --query 'routingConfiguration.vnetRoutes.staticRoutes[].{name:name,prefix:addressPrefixes,nextHop:nextHopIpAddress}' \
  -o table 2>/dev/null || echo "ERROR fetching conn-dmz")
log "$CONNROUTES"
CONN_CHK=$(az network vhub connection show \
  -g "$RG" --vhub-name "$HUB" -n conn-dmz \
  --query "routingConfiguration.vnetRoutes.staticRoutes[?contains(addressPrefixes, '0.0.0.0/0')].nextHopIpAddress" \
  -o tsv 2>/dev/null || echo "")
if [[ -n "$CONN_CHK" && "$CONN_CHK" != ERROR* ]]; then
  check_pass "conn-dmz static route 0.0.0.0/0 -> ${CONN_CHK} (ILB) present"
  if [[ "$CONN_CHK" != "10.0.0.68" ]]; then
    check_warn "conn-dmz nextHop = $CONN_CHK (expected 10.0.0.68 -- ILB frontend)"
  fi
else
  check_fail "conn-dmz static route 0.0.0.0/0 missing"
fi

# 2c. Spoke1 NIC effective routes
# Ref: https://learn.microsoft.com/azure/virtual-network/manage-route-table
# Expected: 0.0.0.0/0 via nextHopType=VirtualNetworkGateway (vHub BGP router)
log ""
log "  [2c] Spoke1 NIC (nic-vm-spoke1) effective routes:"
log "       Expecting 0.0.0.0/0 via VirtualNetworkGateway (this is how the vHub"
log "       default route appears in spoke NICs -- see effective-routes-virtual-hub doc)"
EFF1=$(az network nic show-effective-route-table \
  -g "$RG" -n nic-vm-spoke1 -o table 2>/dev/null || echo "ERROR")
log "$EFF1"
if echo "$EFF1" | grep -q "VirtualNetworkGateway"; then
  check_pass "Spoke1 NIC: 0.0.0.0/0 via VirtualNetworkGateway (vHub)"
else
  check_fail "Spoke1 NIC: missing 0.0.0.0/0 via VirtualNetworkGateway"
fi

# 2d. Spoke2 NIC effective routes
log ""
log "  [2d] Spoke2 NIC (nic-vm-spoke2) effective routes:"
EFF2=$(az network nic show-effective-route-table \
  -g "$RG" -n nic-vm-spoke2 -o table 2>/dev/null || echo "ERROR")
log "$EFF2"
if echo "$EFF2" | grep -q "VirtualNetworkGateway"; then
  check_pass "Spoke2 NIC: 0.0.0.0/0 via VirtualNetworkGateway (vHub)"
else
  check_fail "Spoke2 NIC: missing 0.0.0.0/0 via VirtualNetworkGateway"
fi

# 2e. vHub effective routes from the defaultRouteTable
# Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
log ""
log "  [2e] vHub effective routes for defaultRouteTable:"
az network vhub get-effective-routes \
  --resource-type RouteTable \
  --resource-id "$DEFAULT_RT_ID" \
  -g "$RG" -n "$HUB" \
  -o table 2>/dev/null \
  && check_pass "vHub get-effective-routes returned successfully" \
  || check_warn "vhub get-effective-routes failed (may need az-cli >= 2.57)"

# 2f. Network Watcher next-hop: vm-spoke1 -> 8.8.8.8
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
log ""
log "  [2f] NW next-hop: vm-spoke1 (10.1.0.4) -> 8.8.8.8"
NH_JSON=$(az network watcher show-next-hop \
  -g "$RG" \
  --vm vm-spoke1 \
  --source-ip 10.1.0.4 \
  --dest-ip 8.8.8.8 \
  --nic nic-vm-spoke1 \
  -o json 2>/dev/null || echo '{"nextHopType":"ERROR"}')
NH_TYPE=$(echo "$NH_JSON" | grep -o '"nextHopType":"[^"]*"' | cut -d'"' -f4)
NH_IP=$(echo "$NH_JSON" | grep -o '"nextHopIpAddress":"[^"]*"' | cut -d'"' -f4)
log "       nextHopType: $NH_TYPE   nextHopIpAddress: $NH_IP"
if [[ "$NH_TYPE" == "VirtualNetworkGateway" || "$NH_TYPE" == "VirtualHub" ]]; then
  check_pass "NW next-hop: 0.0.0.0/0 -> $NH_TYPE (vHub router -- valid for vWAN spoke)"
elif [[ "$NH_TYPE" == "ERROR" ]]; then
  check_warn "NW next-hop returned ERROR (Network Watcher may not be enabled; enable via Portal or enable-monitoring.sh)"
else
  check_fail "NW next-hop type = '$NH_TYPE' (expected VirtualNetworkGateway or VirtualHub)"
fi

# 2g. Network Watcher IP flow verify: vm-spoke1 -> 8.8.8.8:443 TCP Outbound
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
log ""
log "  [2g] NW IP flow verify: vm-spoke1 -> 8.8.8.8:443 TCP Outbound"
IFV_JSON=$(az network watcher test-ip-flow \
  -g "$RG" \
  --vm vm-spoke1 \
  --direction Outbound \
  --protocol TCP \
  --local 10.1.0.4:0 \
  --remote 8.8.8.8:443 \
  --nic nic-vm-spoke1 \
  -o json 2>/dev/null || echo '{"access":"ERROR"}')
IFV_ACCESS=$(echo "$IFV_JSON" | grep -o '"access":"[^"]*"' | cut -d'"' -f4)
IFV_RULE=$(echo "$IFV_JSON" | grep -o '"ruleName":"[^"]*"' | cut -d'"' -f4)
log "       access: $IFV_ACCESS   ruleName: $IFV_RULE"
if [[ "$IFV_ACCESS" == "Allow" ]]; then
  check_pass "NW IP flow verify: Outbound TCP 10.1.0.4 -> 8.8.8.8:443 = Allow"
elif [[ "$IFV_ACCESS" == "ERROR" ]]; then
  check_warn "NW IP flow verify failed (Network Watcher may not be enabled)"
else
  check_fail "NW IP flow verify: access = '$IFV_ACCESS' (expected Allow) — check NSG rules"
fi

# 2h. Network Watcher connectivity test: vm-spoke1 -> ifconfig.io:80
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
log ""
log "  [2h] NW connectivity test: vm-spoke1 -> ifconfig.io:80"
CT_JSON=$(az network watcher test-connectivity \
  -g "$RG" \
  --source-resource vm-spoke1 \
  --dest-address ifconfig.io \
  --dest-port 80 \
  -o json 2>/dev/null || echo '{"connectionStatus":"ERROR"}')
CT_STATUS=$(echo "$CT_JSON" | grep -o '"connectionStatus":"[^"]*"' | cut -d'"' -f4)
CT_LATENCY=$(echo "$CT_JSON" | grep -o '"avgLatencyInMs":[0-9]*' | cut -d: -f2)
log "       connectionStatus: $CT_STATUS   avgLatencyInMs: ${CT_LATENCY:-n/a}"
if [[ "$CT_STATUS" == "Reachable" ]]; then
  check_pass "NW connectivity: vm-spoke1 -> ifconfig.io:80 = Reachable"
elif [[ "$CT_STATUS" == "ERROR" ]]; then
  check_warn "NW connectivity test failed (Network Watcher may not be enabled)"
else
  check_fail "NW connectivity: '$CT_STATUS' (expected Reachable)"
fi

# =============================================================================
# Phase 3 -- Data-plane: curl from spoke VMs (proves SNAT egress via PA NVA)
# Ref: https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
# =============================================================================
log ""
log "=== Phase 3: Data-plane — curl from spoke VMs ==="

PUBLIC_LB_PIP=$(az network public-ip show \
  -g "$RG" -n pip-lb-public \
  --query ipAddress -o tsv 2>/dev/null | tr -d '[:space:]' || true)
log "  Public LB PIP (pip-lb-public): ${PUBLIC_LB_PIP:-<not resolved>}"
log "  Expected: spoke VMs return this IP proving SNAT through PA NVA/Public LB"

log ""
log "  [3a] curl https://ifconfig.io from vm-spoke1 (via az vm run-command):"
RAW1=$(az vm run-command invoke \
  -g "$RG" -n vm-spoke1 \
  --command-id RunShellScript \
  --scripts 'curl -s --max-time 15 https://ifconfig.io' \
  --query 'value[0].message' -o tsv 2>/dev/null || echo "ERROR")
CURL1=$(extract_ip "$RAW1")
log "       returned IP: ${CURL1:-<parse failed>}  (raw: $(echo "$RAW1" | head -1))"
if [[ -n "$PUBLIC_LB_PIP" && "$CURL1" == "$PUBLIC_LB_PIP" ]]; then
  check_pass "vm-spoke1 egress IP = $PUBLIC_LB_PIP (Public LB PIP) -- SNAT through PA NVA confirmed"
elif [[ "$RAW1" == "ERROR" ]]; then
  check_warn "vm-spoke1 run-command failed (VM unreachable or NW extension not ready)"
else
  check_fail "vm-spoke1 returned '$CURL1', expected Public LB PIP '$PUBLIC_LB_PIP'"
fi

log ""
log "  [3b] curl https://ifconfig.io from vm-spoke2:"
RAW2=$(az vm run-command invoke \
  -g "$RG" -n vm-spoke2 \
  --command-id RunShellScript \
  --scripts 'curl -s --max-time 15 https://ifconfig.io' \
  --query 'value[0].message' -o tsv 2>/dev/null || echo "ERROR")
CURL2=$(extract_ip "$RAW2")
log "       returned IP: ${CURL2:-<parse failed>}"
if [[ -n "$PUBLIC_LB_PIP" && "$CURL2" == "$PUBLIC_LB_PIP" ]]; then
  check_pass "vm-spoke2 egress IP = $PUBLIC_LB_PIP (Public LB PIP) -- SNAT through PA NVA confirmed"
elif [[ "$RAW2" == "ERROR" ]]; then
  check_warn "vm-spoke2 run-command failed"
else
  check_fail "vm-spoke2 returned '$CURL2', expected '$PUBLIC_LB_PIP'"
fi

# =============================================================================
# Phase 4 -- PA NVA forwarding evidence
#
# PALO ALTO NOTE: Unlike the Linux NVA (where iptables/conntrack can be queried
# via az vm run-command), Palo Alto VM-Series session tables and NAT counters
# are accessible ONLY through the PAN-OS management plane (GUI or CLI over SSH/
# API).  The bootstrap.xml enables SSH on both data interfaces for LB health
# probes, but PA credentials are not provisioned in the lab.
#
# This phase:
#   1. Discovers the PA management NIC public IP via az CLI (read-only).
#   2. Prints the PA HTTPS GUI URL and manual CLI commands for the operator.
#   3. Emits WARN (not FAIL) for missing PA API evidence — the data-plane curl
#      in Phase 3 is the authoritative pass/fail signal.
#
# Manual PAN-OS CLI evidence commands (run via SSH or Web GUI > CLI):
#   show session all filter source-zone trust
#   show session all filter destination-zone untrust
#   show running nat-policy
#   show counter global | match nat
#   show interface ethernet1/1
#   show interface ethernet1/2
# =============================================================================
log ""
log "=== Phase 4: PA NVA forwarding evidence (MANUAL — see instructions below) ==="

for NVA_NAME in $NVA_NAMES; do
  log ""
  log "  ---- $NVA_NAME ----"

  # 4a. Discover the management NIC public IP (eth0 / first NIC in Azure)
  log "  [4a] Discovering PA management IP for $NVA_NAME ..."
  NIC_ID=$(az vm show -g "$RG" -n "$NVA_NAME" \
    --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null || echo "")

  MGMT_PIP=""
  if [[ -n "$NIC_ID" && "$NIC_ID" != "None" ]]; then
    PIP_ID=$(az network nic show --ids "$NIC_ID" \
      --query 'ipConfigurations[0].publicIPAddress.id' -o tsv 2>/dev/null || echo "")
    if [[ -n "$PIP_ID" && "$PIP_ID" != "None" ]]; then
      MGMT_PIP=$(az network public-ip show --ids "$PIP_ID" \
        --query ipAddress -o tsv 2>/dev/null | tr -d '[:space:]' || echo "")
    fi
  fi

  if [[ -n "$MGMT_PIP" && "$MGMT_PIP" != "<"* ]]; then
    log "  ✅ PA management public IP: $MGMT_PIP"
    log ""
    log "  ┌─────────────────────────────────────────────────────────────────────"
    log "  │  MANUAL STEP — Connect to $NVA_NAME management plane"
    log "  │"
    log "  │  HTTPS GUI:  https://${MGMT_PIP}"
    log "  │  SSH CLI:    ssh admin@${MGMT_PIP}"
    log "  │"
    log "  │  Run these PAN-OS CLI commands to confirm forwarding:"
    log "  │    admin@pan> show session all filter source-zone trust"
    log "  │    admin@pan> show session all filter destination-zone untrust"
    log "  │    admin@pan> show running nat-policy"
    log "  │    admin@pan> show counter global | match nat"
    log "  │    admin@pan> show interface ethernet1/1"
    log "  │    admin@pan> show interface ethernet1/2"
    log "  │"
    log "  │  Expected NAT policy output (similar to):"
    log "  │    trust-to-untrust-masquerade  trust -> untrust  dynamic-ip-and-port"
    log "  │"
    log "  │  Expected counters (non-zero after Phase 3 curl runs):"
    log "  │    flow_nat_translate   (NAT translations performed)"
    log "  │    flow_fwd_l3          (L3 forwards)"
    log "  └─────────────────────────────────────────────────────────────────────"
    check_warn "$NVA_NAME: PA forwarding evidence is MANUAL (see GUI/CLI instructions above)"
  else
    log "  ⚠️  Could not resolve management public IP for $NVA_NAME."
    log "     If the management NIC has no public IP, connect via Azure Bastion or"
    log "     VPN to reach the snet-mgmt (10.0.0.0/27) address."
    log ""
    log "     Manual PAN-OS CLI evidence commands:"
    log "       show session all filter source-zone trust"
    log "       show session all filter destination-zone untrust"
    log "       show running nat-policy"
    log "       show counter global | match nat"
    check_warn "$NVA_NAME: management IP not resolvable via az CLI (manual access required)"
  fi
done

# =============================================================================
# Phase 5 -- LB Metrics
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
# Ref: https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli
# =============================================================================
log ""
log "=== Phase 5: Standard Load Balancer metrics ==="
log "  (30-min window; non-zero values confirm active traffic; zero is normal when lab is idle)"

LB_PUBLIC_ID=$(az network lb show -g "$RG" -n lb-public --query id -o tsv 2>/dev/null || true)
LB_ILB_ID=$(az network lb show -g "$RG" -n lb-ilb --query id -o tsv 2>/dev/null || true)

# Compute 30-minute window (GNU date -d, BSD date -v, fallback to current time)
METRICS_START=$(TZ=UTC date -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || TZ=UTC date -v-30M              +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || TZ=UTC date                     +"%Y-%m-%dT%H:%M:%SZ")
METRICS_END=$(TZ=UTC date +"%Y-%m-%dT%H:%M:%SZ")
log "  Window: $METRICS_START -> $METRICS_END"

# run_metric <resource-id> <metric-name> <aggregation>
run_metric() {
  local resource_id="$1" metric="$2" agg="$3"
  log "  -- $metric ($agg):"
  local az_out az_rc=0
  az_out=$(az monitor metrics list \
    --resource   "$resource_id" \
    --metric     "$metric" \
    --start-time "$METRICS_START" \
    --end-time   "$METRICS_END" \
    --interval PT5M \
    --aggregation "$agg" \
    -o table 2>&1) || az_rc=$?
  if [[ $az_rc -ne 0 ]]; then
    log "     ERROR (exit $az_rc): $az_out"
    check_warn "$metric: az metrics call failed (see above)"
  else
    log "$az_out"
  fi
}

if [[ -z "$LB_PUBLIC_ID" ]]; then
  check_warn "lb-public not found — metrics phase skipped"
else
  log ""
  log "  Public LB (lb-public) — SNAT, availability, and traffic metrics:"
  log "  Note: correct metric names are UsedSnatPorts / AllocatedSnatPorts (lowercase 'nat')"
  # Per https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli
  # aggregations: Average for ports/availability; Total for counts/bytes
  run_metric "$LB_PUBLIC_ID" "UsedSnatPorts"       "Average"
  run_metric "$LB_PUBLIC_ID" "AllocatedSnatPorts"  "Average"
  run_metric "$LB_PUBLIC_ID" "SnatConnectionCount" "Total"
  run_metric "$LB_PUBLIC_ID" "ByteCount"           "Total"
  run_metric "$LB_PUBLIC_ID" "PacketCount"         "Total"
  run_metric "$LB_PUBLIC_ID" "VipAvailability"     "Average"
  run_metric "$LB_PUBLIC_ID" "DipAvailability"     "Average"

  log ""
  log "  ILB (lb-ilb) — backend health (DipAvailability only):"
  log "  NOTE: ILB ByteCount/PacketCount are ZERO by design for UDR-forwarded traffic."
  log "  Ref: https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics#multi-dimensional-metrics"
  if [[ -n "$LB_ILB_ID" ]]; then
    run_metric "$LB_ILB_ID" "DipAvailability" "Average"
  else
    check_warn "lb-ilb not found — ILB metrics skipped"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
log ""
log "╔═══════════════════════════════════════════════════════════════════╗"
log "║  validate-flow.sh SUMMARY (nva-spoke-internet-paloalto)          ║"
log "╠═══════════════════════════════════════════════════════════════════╣"
log "║  PASS: $PASS   FAIL: $FAIL   WARN: $WARN"
log "╚═══════════════════════════════════════════════════════════════════╝"

if [[ $FAIL -gt 0 ]]; then
  log ""
  log "  Some checks FAILED. Common causes:"
  log "    - Lab not fully deployed or routing phases not completed"
  log "    - PA NVA bootstrap not completed (check: az vm boot-diagnostics get-boot-log)"
  log "    - ILB backend pool empty (PA trust NICs not registered)"
  log "    - Network Watcher not enabled for the region"
  log "    - PA management profile not allowing SSH on data interfaces (LB probe fails)"
  exit 1
fi

log ""
log "  All critical checks passed. Internet breakout Spoke->PA NVA->Public LB is functioning."
log "  Review Phase 4 WARN items above for manual PA session/NAT evidence."
