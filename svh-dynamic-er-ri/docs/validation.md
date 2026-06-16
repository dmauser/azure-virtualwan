# Validation Guide — svh-dynamic-er-ri

## Overview

The `validate.sh` (Bash) and `validate.ps1` (PowerShell) scripts run an automated checklist against the deployed lab. This guide explains what each check validates, how to read the results, and how to run manual connectivity tests.

---

## What the Validate Scripts Check

### 1. Hub Routing Preference

```bash
az network vhub list -g <rg> \
  --query "[].{name:name, pref:hubRoutingPreference}" -o table
```

**Expected**: Every hub shows `ExpressRoute`.  
**Failure**: Any hub showing `ASPath` or `VpnGateway` indicates `vhub.bicep` was modified or a manual override was applied. The validation script exits with an error.

---

### 2. Routing Intent Provisioning State

```bash
az network vhub routing-intent show \
  -g <rg> --vhub-name <hubName> -n <hubName>-ri \
  --query "provisioningState" -o tsv
```

**Expected**: `Succeeded` for every hub.  
**If `Updating`**: Routing Intent is still being applied — wait and retry.  
**If `Failed`**: The firewall may not have been in `Succeeded` state when RI was created. See [Troubleshooting](troubleshooting.md).

---

### 3. Azure Firewall Provisioning State

```bash
az network firewall show \
  -g <rg> -n <hubName>-azfw \
  --query "provisioningState" -o tsv
```

**Expected**: `Succeeded`.  
**Note**: Firewall provisioning takes 30–45 minutes. If the validate script runs before provisioning completes it will report `Updating` — this is normal; re-run after the firewall finishes.

---

### 4. Firewall Policy Rule Existence

The script verifies `default-allow-all-rcg` exists on every hub's policy:

```bash
az network firewall policy rule-collection-group list \
  -g <rg> --policy-name <policyName> \
  --query "[?name=='default-allow-all-rcg'].{name:name, priority:priority}" -o table
```

**Expected**: One row per hub policy with `name = default-allow-all-rcg` and `priority = 200`.

---

### 5. Spoke VNet Connection Status

```bash
az network vhub connection show \
  -g <rg> --vhub-name <hubName> -n <spokeName>-conn \
  --query "provisioningState" -o tsv
```

**Expected**: `Succeeded` for every hub/spoke pair.  
**If `Updating`**: Connection is still being applied — normal in the first few minutes after hub VNet connection creation.

---

### 6. VM Private IPs

```bash
az vm show -g <rg> -n vm-spoke-<i> \
  -d --query "privateIps" -o tsv
```

The script lists every VM's private IP. Cross-check that IPs fall within the expected spoke subnet range (`10.(i×10+1).0.0/27`).

---

### 7. VM Effective Routes

```bash
az network nic show-effective-route-table \
  -g <rg> -n nic-vm-spoke-<i> -o table
```

**What to look for** with `privateOnly` Routing Intent:

| Prefix | Next hop type | Next hop IP |
|--------|--------------|-------------|
| `10.0.0.0/8` (or RFC-1918 summaries) | VirtualAppliance | Hub firewall private IP |
| `10.(i×10).0.0/23` (hub prefix) | VNetLocal | — |
| `0.0.0.0/0` | Internet | — (should NOT be via firewall with `privateOnly`) |

With `internetOnly` mode: `0.0.0.0/0` should point to the hub firewall as next hop.  
With `both` mode: both RFC-1918 and `0.0.0.0/0` should route via hub firewall.

---

### 8. Hub Effective Route Table

```bash
az network vhub get-effective-routes \
  -g <rg> -n <hubName> \
  --resource-type RouteTable \
  --resource-id <defaultRouteTableId> -o table
```

Check that learned routes from ER, VPN, and VNet connections appear and point to the correct next hops.

---

### 9. ER Circuit and Connection State (if applicable)

```bash
# Circuit provisioning state
az network express-route show \
  -g <rg> -n <circuitName> \
  --query "{state:serviceProviderProvisioningState, provision:provisioningState}" -o table

# Connection provisioning state
az network express-route gateway connection show \
  -g <rg> --gateway-name ergw-<hubName> -n <connectionName> \
  --query "provisioningState" -o tsv
```

**Expected**: `serviceProviderProvisioningState = Provisioned`, `provisioningState = Succeeded`.

---

### 10. Key Vault Secrets

```bash
az keyvault secret list \
  --vault-name <kvName> \
  --query "[].name" -o tsv
```

**Expected**: Both `vm-admin-username` and `vm-admin-password` are present.

---

## Reading Hub Effective Route Tables

The hub effective route table shows all prefixes the hub router has learned. Key columns:

| Column | Meaning |
|--------|---------|
| `addressPrefixes` | The prefix (e.g., `10.11.0.0/24`) |
| `nextHopType` | How the hub will forward traffic |
| `nextHops` | Next hop IP (for `RemoteHub` or `VirtualAppliance`) |
| `origin` | Who advertised the route (`VNet`, `ExpressRoute`, `VPN`) |
| `asPath` | BGP AS path if learned via ER or VPN |

With Routing Intent active, you should see the hub's own firewall IP as the next hop for `PrivateTraffic` prefixes.

---

## Reading Hub VNet Connection Status

```bash
az network vhub connection list \
  -g <rg> --vhub-name <hubName> -o table
```

| Column | Expected |
|--------|---------|
| `provisioningState` | `Succeeded` |
| `enableInternetSecurity` | `true` (set by the spoke-vnet module) |
| `routingConfiguration` | Default unless custom route tables are configured |

---

## Manual Connectivity Tests

### Prerequisites

SSH to `vm-spoke-1` (via Azure Serial Console or direct SSH if NSG allows):

```bash
# Retrieve SSH details
az vm show -g <rg> -n vm-spoke-1 -d --query "privateIps" -o tsv
az keyvault secret show --vault-name <kvName> -n vm-admin-username --query value -o tsv
```

Or use Serial Console in the Azure portal — credentials are in Key Vault.

---

### Test 1: Spoke-to-Spoke (Same Hub)

From `vm-spoke-1`, trace to another VM in the same spoke subnet:

```bash
traceroute 10.11.0.5   # adjust to actual IP
```

**Expected**: Direct path within the spoke VNet (no firewall hop for intra-VNet traffic).

---

### Test 2: Inter-Hub (Spoke 1 → Spoke 2)

```bash
traceroute 10.21.0.4   # vm-spoke-2 private IP
```

**Expected**: Traffic transits hub-1 firewall → hub-2 firewall → vm-spoke-2. With `privateOnly` RI, you should see two firewall hops (one per hub).

---

### Test 3: Internet Egress (with `internetOnly` or `both` mode)

```bash
curl -s https://ifconfig.me
traceroute 8.8.8.8
```

**Expected**: Traffic exits via hub firewall. The source IP seen by the destination should be the firewall's managed public IP. With `privateOnly` mode, this traffic bypasses the firewall and exits directly via Azure Internet.

---

### Test 4: On-Premises (Branch) to Spoke (ER required)

From on-premises host, trace to `vm-spoke-1`:

```bash
traceroute 10.11.0.4
```

**Expected**: Traffic enters via ER, transits hub firewall (RI), reaches spoke VM. Return path follows the same firewall-steered route.

---

### Test 5: Branch-to-Branch (ER required, two circuits)

From on-premises host connected via circuit-1 (hub-1), trace to on-premises host on circuit-2 (hub-2):

**Expected**: Traffic transits hub-1 firewall → hub-2 firewall → exit via circuit-2. Branch-to-branch traffic is enabled by `allowBranchToBranchTraffic = true` on the Virtual WAN.

---

## Validating Route Preference

To explicitly confirm `ExpressRoute` preference wins over VPN when both advertise the same prefix:

1. Advertise the same prefix from both ER and a VPN site.
2. Check the hub effective route table — the ER-learned route (lower AD/preference) should appear as active.
3. The `hubRoutingPreference = ExpressRoute` setting ensures this without manual weight configuration.

---

## Serial Console Access (VM with No Public IP)

1. In the Azure portal, navigate to `vm-spoke-<i>` → **Serial Console**
2. Log in with:
   - Username: retrieved from Key Vault secret `vm-admin-username`
   - Password: retrieved from Key Vault secret `vm-admin-password`

```bash
az keyvault secret show \
  --vault-name <kvName> \
  --name vm-admin-password \
  --query value -o tsv
```

Serial Console works because boot diagnostics are enabled with a managed storage account (`bootDiagnostics.enabled = true`, no `storageUri`).
