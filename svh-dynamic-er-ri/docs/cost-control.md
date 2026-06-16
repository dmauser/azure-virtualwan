# Cost Control — svh-dynamic-er-ri

> ⚠️ **LAB USE ONLY**: This lab intentionally uses an allow-all firewall policy (`default-allow-all-rcg` → `allow-all-network` → `allow-all` rule). This rule permits any source, any destination, any protocol on any port. It is designed exclusively for routing behaviour validation in a lab environment. **This policy must never be used in production.** Always clean up this lab when your session ends.

---

## Cost Line Items

The following resources represent the primary ongoing charges. All costs are approximate USD and vary by region and commitment model.

| Resource | Approx. hourly cost | Notes |
|----------|-------------------|-------|
| **Standard Virtual Hub** | ~$0.25/hr each | Charged while the hub exists, even idle. N hubs = N × $0.25. |
| **Azure Firewall Basic** | ~$0.246/hr each | Per hub. Charged while the firewall exists. |
| **ExpressRoute Gateway** | ~$0.073/hr per scale unit | Per hub with a gateway. Scale unit 1 (minimum). |
| **ExpressRoute Circuit** | Varies by provider | Monthly port fee (Megaport 50 Mbps ≈ $55–$110/mo) + per-GB egress charges. Billed from creation, not from provider provisioning. |
| **VM (Standard_B2s)** | ~$0.042/hr each | Per spoke (one per hub). Deallocatable without data loss. |
| **Key Vault** | Negligible | ~$0.03/10,000 operations. |
| **Managed Disk (StandardSSD_LRS)** | ~$0.008/hr (30 GB) | Persists even when VM is deallocated. |
| **Public IP** | ~$0.005/hr | Only if `attachPublicIp = true` (not default). |

### Monthly estimate by hub count (no ER)

| Hubs | vWAN hubs | Firewalls | VMs | Est. monthly |
|------|-----------|-----------|-----|-------------|
| 1 | $180 | $177 | $30 | **~$387/mo** |
| 2 | $360 | $354 | $60 | **~$774/mo** |
| 3 | $540 | $531 | $90 | **~$1,161/mo** |
| 4 | $720 | $708 | $120 | **~$1,548/mo** |

Adding one ER gateway per hub adds **~$53/mo per hub**. Adding one ER circuit (Standard/50 Mbps/MeteredData via Megaport) adds **~$55–$110/mo per circuit** plus egress.

---

## The Highest-Cost Resources

### 1. ExpressRoute Gateway (~$0.073/hr = ~$53/mo per hub)

This is the most impactful per-hub cost after the hub and firewall themselves.

**Reduction strategies**:
- Use the demand-driven model: only create ER gateways on hubs that need circuit connectivity (default behaviour).
- Delete gateways when not actively testing ER connectivity — re-creating takes ~5–10 minutes.
- Use the `--skip-er` flag to avoid ER gateway creation entirely.

### 2. ExpressRoute Circuit (~$55–$110+/mo per circuit)

**Critical**: ER circuits are billed from the moment they are created in Azure, **regardless of whether the provider has provisioned their side**. The port reservation starts immediately.

**Reduction strategies**:
- Only create ER circuits when you are actively working on ER connectivity testing.
- Delete circuits promptly when no longer needed.
- Ensure Megaport VXCs or other provider resources are also removed before circuit deletion to avoid orphaned provider charges.
- Use the `--skip-er` flag during non-ER routing tests.

### 3. Azure Firewall Basic (~$0.246/hr = ~$177/mo per hub)

Azure Firewall cannot be "stopped" like a VM — the only way to eliminate the charge is to delete the firewall.

**Reduction strategies**:
- Deploy only as many hubs (and therefore firewalls) as you need for the test.
- Use a single-hub deployment (`--hub-count 1`) for basic routing tests.
- Delete the entire lab when done — the `cleanup.sh` / `cleanup.ps1` scripts remove everything.

### 4. Standard Virtual Hub (~$0.25/hr = ~$180/mo per hub)

Like Azure Firewall, the hub cannot be stopped — only deleted.

**Reduction strategy**: Minimize hub count for the test scenario.

### 5. Virtual Machines (~$0.042/hr = ~$30/mo per VM)

VMs can be **deallocated** without data loss, stopping the compute charge (disk still billed at ~$8/mo).

```bash
# Deallocate all spoke VMs
az vm deallocate -g <rg> -n vm-spoke-1 --no-wait
az vm deallocate -g <rg> -n vm-spoke-2 --no-wait
```

Restart before the next test session:
```bash
az vm start -g <rg> -n vm-spoke-1 --no-wait
az vm start -g <rg> -n vm-spoke-2 --no-wait
```

---

## How to Reduce Cost

### Option A: Skip ER Gateways and Circuits (Routing-Only Labs)

Use the `--skip-er` flag. No ER circuits, no ER gateways. Tests spoke-to-spoke, inter-hub, and Routing Intent behaviour without ER cost:

```bash
./deploy.sh --hub-count 2 --regions "eastus,westus" \
  --routing-intent-mode privateOnly --skip-er
```

### Option B: Minimum Single Hub

```bash
./deploy.sh --hub-count 1 --regions "eastus" \
  --routing-intent-mode privateOnly --skip-er
```

Monthly estimate: ~$387 (hub + firewall + VM). No ER cost.

### Option C: Deallocate VMs Between Sessions

```bash
# Deallocate all VMs in the resource group
az vm list -g lab-svh-dynamic-er-ri --query "[].name" -o tsv | \
  xargs -I {} az vm deallocate -g lab-svh-dynamic-er-ri -n {} --no-wait
```

### Option D: Remove ER Gateways When Not Testing ER

```bash
# Remove ER connection first, then gateway
az network express-route gateway connection delete \
  -g <rg> --gateway-name ergw-vhub-1 -n <connectionName> --yes

az network express-route gateway delete \
  -g <rg> -n ergw-vhub-1 --yes
```

Re-create when needed (takes ~5–10 minutes).

### Option E: Remove ER Circuits When Done with Provider Testing

```bash
# Delete ER circuit (removes Azure-side resource and port reservation)
az network express-route delete -g <rg> -n <circuitName> --yes
```

> ⚠️ Delete the Megaport VXC **before** deleting the Azure circuit, or the VXC will become orphaned. Verify provider-side cleanup in the Megaport portal.

---

## Disable ER Gateway Per Hub (Bicep)

To explicitly prevent ER gateway creation on specific hubs in a Bicep deployment, ensure `deployErGateway = false` (the default) for those hubs and do not map any ER circuits to them.

The `expressroute-gateway.bicep` module is only invoked when:
- A circuit definition maps to the hub (script-driven), or
- The hub has `deployErGateway = true` set explicitly

---

## Clean Up Everything

The fastest way to eliminate all charges is to delete the resource group:

```bash
# Bash
./cleanup.sh

# PowerShell
.\cleanup.ps1

# Manual
az group delete -n lab-svh-dynamic-er-ri --yes --no-wait
```

**Before running cleanup**:
1. Remove any Megaport VXCs or provider cross-connects that reference the ER circuits.
2. Confirm no other resources in the subscription depend on resources in this lab.
3. Note that the Key Vault has soft-delete enabled (7-day retention). If you redeploy with the same Key Vault name within 7 days, you must purge it first:
   ```bash
   az keyvault purge -n <kvName>
   ```

The cleanup scripts will:
- Delete all VNet connections
- Delete Routing Intent on all hubs
- Delete ER connections and gateways (if present)
- Delete ER circuits
- Delete the resource group (which deletes all remaining resources)

---

## Allow-All Firewall Rule — Lab Only

> ⚠️ **PRODUCTION WARNING**: The firewall policy deployed by this lab (`firewall-policy.bicep`) contains:
> - Rule Collection Group: `default-allow-all-rcg` (priority 200)
> - Rule Collection: `allow-all-network` (Action: Allow)
> - Rule: `allow-all` — Source: `*`, Destination: `*`, Protocol: Any, Port: `*`
>
> This rule **allows all traffic** through the firewall. It exists to eliminate firewall rule management as a variable during routing validation. There is no traffic inspection, no threat protection, and no access control.
>
> **This configuration is NOT production-safe. Do not use it in any environment where security matters. The purpose of this lab is to test Azure Virtual WAN routing and Routing Intent behaviour, not firewall security posture.**

If you want to test with more realistic firewall rules while keeping the lab, replace or supplement `default-allow-all-rcg` with specific allow rules, then delete or disable the `allow-all` rule collection group.
