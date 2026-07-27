# SKILL: vWAN Custom NVA 0/0 Internet Routing

**Skill ID:** `vwan-nva-routing`  
**Author:** Alex  
**Last Updated:** 2026-07-24  
**Applies To:** Any Azure Virtual WAN lab using a custom NVA (not Azure Firewall) for internet egress inspection/SNAT via an HA-ports ILB

---

## Problem Statement

Route internet-bound traffic from spoke VMs through custom NVAs sitting in a DMZ VNet connected to a Virtual WAN hub, without using Routing Intent (which requires Azure Firewall as the next-hop).

---

## Solution Pattern

Two az CLI operations produce the full 0/0 routing chain from spokes through the hub to NVAs:

### Step 1 — DMZ VNet Connection with Connection-Level Static Route

Set the static route at `az network vhub connection create` time.  This tells the hub: "when resolving 0/0 for traffic going through conn-dmz, forward to the ILB frontend IP."

```bash
DMZ_CONN_STATIC_ROUTE_NAME="default-via-ilb"
ILB_FRONTEND_IP="10.0.0.68"   # HA-ports ILB in DMZ VNet

az network vhub connection create \
  -g "$RG" --vhub-name "$HUB" -n "conn-dmz" \
  --remote-vnet "$DMZ_VNET_ID" \
  --associated-route-table "$DEFAULT_RT_ID" \
  --propagated-route-tables "$DEFAULT_RT_ID" \
  --labels "default" \
  --route-name "$DMZ_CONN_STATIC_ROUTE_NAME" \
  --address-prefixes "0.0.0.0/0" \
  --next-hop "$ILB_FRONTEND_IP"
```

### Step 2 — defaultRouteTable Route: 0/0 → conn-dmz (ResourceID)

After the connection is Succeeded, add a static route to the hub's defaultRouteTable pointing at conn-dmz.  This causes spoke VMs (associated to defaultRouteTable) to learn the 0/0 default route.

```bash
# Wait for conn-dmz to be Succeeded before reading its ID
CONN_DMZ_ID=$(az network vhub connection show \
  -g "$RG" --vhub-name "$HUB" -n "conn-dmz" \
  --query "id" -o tsv)

az network vhub route-table route add \
  -g "$RG" --vhub-name "$HUB" --name "defaultRouteTable" \
  --route-name "to-internet" \
  --destination-type "CIDR" --destinations "0.0.0.0/0" \
  --next-hop-type "ResourceID" --next-hop "$CONN_DMZ_ID"
```

### defaultRouteTable Resource ID Construction

```bash
SUBSCRIPTION=$(az account show --query id -o tsv)
DEFAULT_RT_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Network/virtualHubs/${HUB}/hubRouteTables/defaultRouteTable"
```

---

## Verification

```bash
# Spoke VM effective routes — confirm 0/0 → conn-dmz
az network nic show-effective-route-table -g $RG --name <spoke-nic> -o table | grep '0.0.0.0/0'

# Hub defaultRouteTable routes
az network vhub route-table show -g $RG --vhub-name $HUB --name defaultRouteTable \
  --query 'routes' -o table

# Egress test from spoke VM (expected: NVA Public LB PIP)
# Via serial console or az vm run-command:
curl -s --max-time 10 https://ifconfig.me
```

---

## Common Pitfalls

| Mistake | Consequence | Fix |
|---------|-------------|-----|
| Setting `--internet-security true` on spoke connections (not needed for custom static routes) | Flag is only for Routing Intent internet modes; may cause unexpected behavior | Omit `--internet-security` unless using RI |
| Creating VNet connections in Bicep before hub is Provisioned | Connection create fails with hub timing error | Always poll `routingState == Provisioned` in scripts before creating connections |
| Adding step 2 before step 1 connection is Succeeded | `az network vhub route-table route add` with a ResourceID next-hop may fail if resource is not fully provisioned | Poll conn-dmz to Succeeded before reading its ID |
| Using `az network vhub routing-intent` (wrong command for custom NVA) | RI requires Azure Firewall as next-hop; fails or silently misbehaves with custom NVA | Use static route pattern above; RI is only for AzFw-secured hubs |
| Confusing `--vhub-name` vs `--vhub` | `az network vhub routing-intent` uses `--vhub`; `az network vhub connection` uses `--vhub-name` — mixing them causes CLI error | Always check `--help` for each sub-command |

---

## On-prem BGP-over-IPsec Bring-up Pattern

For optional on-prem connectivity via strongSwan + FRR:

```bash
# 1. Create VPN site
az network vpn-site create -g $RG -n "onprem-vpnsite" -l $LOCATION \
  --virtual-wan $VWAN_NAME \
  --ip-address $ONPREM_NVA_PIP \
  --asn 65001 --bgp-peering-address $ONPREM_NVA_PRIVATE_IP \
  --address-prefixes "192.168.100.0/24" \
  --link-name "onprem-link"

# 2. Create VPN connection (BGP enabled)
az network vpn-gateway connection create \
  -g $RG --gateway-name $VPN_GW_NAME -n "conn-onprem" \
  --vpn-site "onprem-vpnsite" --enable-bgp true --vpn-site-link "onprem-link"

# 3. Set PSK on link index 0 (separate command — cannot set at create time)
az network vpn-gateway connection vpn-site-link-conn sharedkey update \
  -g $RG --gateway-name $VPN_GW_NAME --connection-name "conn-onprem" \
  --index 0 --value "$VPN_SHARED_KEY"

# 4. Fetch hub GW public IPs + BGP peer IPs
HUB_GW_PIP0=$(az network vpn-gateway show -g $RG -n $VPN_GW_NAME \
  --query "ipConfigurations[0].publicIpAddress" -o tsv)
HUB_BGP_PEER0=$(az network vpn-gateway show -g $RG -n $VPN_GW_NAME \
  --query "bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]" -o tsv)
```

**FRR BGP config notes:**
- `ebgp-multihop 5` is required — BGP peer is not directly adjacent (traverses IPsec tunnel)
- Two neighbors: one per hub GW instance (active/active = 2 BGP peer IPs)
- `network 192.168.100.0/24` to advertise on-prem prefix

**strongSwan notes:**
- One `conn` block per hub GW instance IP
- `leftsubnet=0.0.0.0/0` + `rightsubnet=0.0.0.0/0` (route-based; traffic selectors do not restrict BGP TCP)
- `auto=start`, `dpdaction=restart`
- PSK: `openssl rand -hex 24` (hex-only, no special chars that break ipsec.secrets)

---

## Validation Patterns (added by Amos 2026-07-24)

### Pre-deploy contract cross-check

```bash
# 1. All 16 required output names present in main.bicep
grep -P "^output " nva-spoke-internet/bicep/main.bicep | awk '{print $2}' | sort

# 2. All get_output calls in deploy.sh resolve to actual output names
grep "get_output " nva-spoke-internet/scripts/deploy.sh | \
  grep -oP 'get_output \K\w+' | sort

# 3. No old CIDR references (must return zero lines)
grep -r "10\.200\.0\.0" nva-spoke-internet/

# 4. ILB frontend IP consistency across files (must all print '10.0.0.68')
grep -r "10\.0\.0\.68" nva-spoke-internet/
```

### Cloud-init NVA completeness check

For a custom NVA cloud-init to support spoke internet egress AND ILB TCP/22 health probes, the YAML `runcmd` must contain all four:

```
net.ipv4.ip_forward = 1          # ip forwarding
MASQUERADE                        # SNAT on eth0
FORWARD -j ACCEPT                 # allow transit
INPUT -p tcp --dport 22 -j ACCEPT # ILB TCP/22 health probe
```

Validate with: `grep -E "ip_forward|MASQUERADE|FORWARD|dport 22" nva-spoke-internet/bicep/cloud-init/nva.yaml`

### Boot diagnostics check

All VMs must pass: `grep -A2 "bootDiagnostics" nva-spoke-internet/bicep/modules/vm.bicep`  
Required: `enabled: true` with NO `storageUri` line (enables Azure Serial Console via managed storage).

### Dead variable detection

```bash
# Any variable appearing exactly once (only assignment) is suspect
for var in HUB_ID SUBSCRIPTION VWAN_NAME; do
  count=$(grep -c "\b${var}\b" nva-spoke-internet/scripts/deploy.sh || true)
  echo "$var: $count occurrences"
done
```

---

## Windows PowerShell Gotchas (deploy.ps1 context)

### Empty-string args to `az` CLI are silently dropped

**Problem:** `az vm create --public-ip-address ""` on Windows PowerShell drops the empty string → `az` receives `--public-ip-address` with no value → `ERROR: argument --public-ip-address: expected one argument` → exit code 2.  
In a preflight loop that tests multiple SKUs, all SKUs fail immediately — misdiagnosed as capacity exhaustion.

**Fix:** Pre-create a NIC (no public IP) and use `--nics <nicName>` instead of `--public-ip-address ""`

```powershell
az network nic create -g $rg -n "capchk-nic" --vnet-name "capchk-vnet" --subnet "capchk-snet" --no-wait 2>$null
az vm create -g $rg -n "capchk-vm" --image "UbuntuLTS" --size $sku --nics "capchk-nic" ...
```

**Rule:** Never pass `""` as an optional argument to `az` in PowerShell. The absence of the flag (not an empty-string argument) is always safer for optional resource-name parameters.  
Affects: `--public-ip-address`, `--subnet`, `--vnet-name`, `--network-security-group` and similar optional string args.

### Switch parameter prompt suppression

`[switch]$DeployOnPrem` is `$false` in BOTH of these cases:
- Omitted entirely: `.\deploy.ps1`
- Passed explicitly: `.\deploy.ps1 -DeployOnPrem:$false`

Use `$PSBoundParameters.ContainsKey('DeployOnPrem')` to distinguish them:
```powershell
# Only prompt if genuinely absent from command line
if (-not $PSBoundParameters.ContainsKey('DeployOnPrem')) {
    $DeployOnPrem = (Read-Host "Deploy on-prem? [y/N]") -ieq 'y'
}
```

### Unattended password injection

For CI / agent contexts, use an env-var fallback before the interactive loop:
```powershell
if (-not [string]::IsNullOrWhiteSpace($env:ADMIN_PASSWORD) -and $env:ADMIN_PASSWORD.Length -ge 12) {
    $AdminPasswordPlain = $env:ADMIN_PASSWORD
}
while ([string]::IsNullOrWhiteSpace($AdminPasswordPlain)) { ... interactive loop ... }
```

---

## Live Deploy Validation (2026-07-24, DMAUSER-FDPO eastus2)

Confirmed egress test via `az vm run-command invoke`:
```powershell
az vm run-command invoke -g rg-nva-spoke-internet --name vm-spoke1 `
  --command-id RunShellScript `
  --scripts "curl -s --max-time 20 https://ifconfig.io" `
  --query 'value[0].message' -o tsv
# Output: 20.65.77.169  ← matches Public LB PIP
```

East-west (Spoke1 → Spoke2 10.2.0.4): 3/3 pings, 0% loss, TTL=63 (vWAN hub = 1 hop).

Effective routes on spoke NIC: `0.0.0.0/0 → VirtualNetworkGateway (10.100.0.68)` — the `VirtualNetworkGateway` type with hub IP is correct for vWAN; it does NOT mean a standalone VPN GW is present.

---

## Related Files
- `nva-spoke-internet/scripts/functions.sh` — pick_vm_sku, preflight_vm_capacity, poll_until
- `nva-spoke-internet/scripts/deploy.sh` — full 13-phase deploy orchestration
- `nva-spoke-internet/scripts/configure-onprem.sh` — on-prem NVA bring-up via az vm run-command invoke
- `.squad/decisions/inbox/alex-nva-spoke-internet-vwan-routing.md` — formal decision record
