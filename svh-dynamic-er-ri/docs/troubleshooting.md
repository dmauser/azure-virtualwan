# Troubleshooting — svh-dynamic-er-ri

## Issue: ExpressRoute Provider Provisioning is Slow

**Symptom**: The deploy script is polling `serviceProviderProvisioningState` but it remains `NotProvisioned` or `Provisioning` for a long time.

**Root cause**: ER circuit provisioning is entirely provider-controlled. Megaport VXC provisioning typically takes minutes to a few hours; Equinix or telco carriers can take hours to days. This is expected behaviour.

**Actions**:
- Verify your VXC order is placed correctly in the provider portal (correct service key, correct Microsoft peering location).
- Check the provider portal for order status. Megaport shows near-real-time VXC state.
- The poll timeout (`MAX_WAIT_MIN`, default 180 minutes) is intentionally long. If it expires, the script exits with a resume instruction. Re-run once the circuit is `Provisioned`.
- To check circuit state manually:
  ```bash
  az network express-route show \
    -g <rg> -n <circuitName> \
    --query "serviceProviderProvisioningState" -o tsv
  ```

**Not a bug**: Do not re-create the circuit if the service key was already handed to the provider — a new circuit generates a new service key and requires a new provider order.

---

## Issue: Azure Firewall Takes 30–45 Minutes to Provision

**Symptom**: `az network firewall show ... --query provisioningState` returns `Updating` for a long time after Bicep deployment completes.

**Root cause**: Azure Firewall Basic in Hub mode provisions the firewall infrastructure, allocates managed public IPs, and wires the data plane inside the vHub. This routinely takes 30–45 minutes per firewall.

**Actions**:
- Wait. This is normal and expected.
- Do not re-run the Bicep deployment while the firewall is `Updating` — it will block or conflict.
- The deploy scripts poll firewall state before attempting Routing Intent creation. If you are running steps manually, poll first:
  ```bash
  while true; do
    state=$(az network firewall show -g <rg> -n vhub-1-azfw --query provisioningState -o tsv)
    echo "$(date) — $state"
    [[ "$state" == "Succeeded" ]] && break
    sleep 60
  done
  ```

---

## Issue: Routing Intent `routingState` Not `Provisioned`

**Symptom**: `az network vhub routing-intent show ... --query provisioningState` returns `Failed` or never reaches `Succeeded`.

**Root cause A**: Routing Intent was created before the Azure Firewall reached `Succeeded` state.  
**Fix**: Delete the Routing Intent resource and re-create it after the firewall is `Succeeded`:
```bash
az network vhub routing-intent delete \
  -g <rg> --vhub-name vhub-1 -n vhub-1-ri --yes

# Wait for firewall to be Succeeded, then:
az network vhub routing-intent create \
  -g <rg> --vhub-name vhub-1 -n vhub-1-ri \
  --routing-policies '[{"name":"PrivateTraffic","destinations":["PrivateTraffic"],"nextHop":"<firewallId>"}]'
```

**Root cause B**: The Virtual Hub itself is still in `Updating` state.  
**Check**:
```bash
az network vhub show -g <rg> -n vhub-1 --query "routingState" -o tsv
```
Wait for `Provisioned` before creating Routing Intent.

**Root cause C**: The hub has no firewall deployed (Routing Intent requires a Secured Hub).  
**Check**: Verify the firewall exists in the hub before attempting RI creation.

---

## Issue: Internet Traffic Not Routing Through Firewall Basic

**Symptom**: Routing Intent mode is `internetOnly` or `both`, but Internet traffic from spoke VMs bypasses the firewall (e.g., `curl https://ifconfig.me` returns a public IP that is not the firewall's managed IP, or traceroute to 8.8.8.8 does not show a firewall hop).

**Root cause**: Azure Firewall **Basic** has documented limitations in Secured Hub mode when steering Internet traffic via Routing Intent. Internet traffic steering in secured-hub mode is fully supported on **Standard** and **Premium** SKUs.

**Mitigation options**:
1. **Upgrade to Azure Firewall Standard** — change `tier = 'Standard'` in `secured-vhub-firewall.bicep` and `firewall-policy.bicep`. Standard SKU costs ~10× more per hub.
2. **Use `privateOnly` mode** — if Internet traffic inspection is not the goal of your lab, switch back to `privateOnly`. Internet traffic will bypass the firewall and exit via Azure Internet directly.
3. **Accept the limitation** — if you only need to validate private routing behaviour (spoke-to-spoke, hub-to-hub, branch-to-spoke), the Basic SKU + `privateOnly` mode works reliably.

---

## Issue: Spoke VNet Connection Fails or Hub Connection State Is `Failed`

**Symptom**: `az network vhub connection show ... --query provisioningState` returns `Failed`.

**Root cause A**: The hub `routingState` was not `Provisioned` when the VNet connection was created.  
**Check**:
```bash
az network vhub show -g <rg> -n vhub-1 --query "routingState" -o tsv
```
**Fix**: Delete and re-create the VNet connection after hub reaches `Provisioned`.

**Root cause B**: The Routing Intent creation failed and left the hub in a bad state. Resolve the Routing Intent issue first (see above), then retry the VNet connection.

**Root cause C**: Address space overlap between the spoke VNet and the hub prefix.  
**Check**: Confirm the spoke prefix (`10.11.0.0/24`) is fully within the hub's `/23` but does not conflict with any hub-reserved ranges.

---

## Issue: VM SKU Restrictions — Cannot Deploy VM in Region

**Symptom**: The deploy script exits before deployment with a message like: *"No available VM SKU found in region X. Candidates: Standard_B2s, Standard_D2s_v5, Standard_D2s_v3."*

**Root cause**: Azure subscription quotas or regional SKU restrictions block all three candidate VM sizes in the requested region.

**Actions**:
1. Check SKU restrictions in the target region:
   ```bash
   az vm list-skus -l <region> \
     --size Standard_B2s --query "[?restrictions==[]]" -o table
   ```
2. Request quota increase in the Azure portal (Subscription → Usage + quotas).
3. Choose a different region that has the required SKUs available.
4. Specify an alternative VM size that is available in the region (the scripts accept a custom `--vm-size` override):
   ```bash
   ./deploy.sh ... --vm-size Standard_D4s_v5
   ```

---

## Issue: No Public IP on VM — Cannot SSH from Internet

**Symptom**: You cannot SSH to the VM directly from your workstation.

**Root cause**: VMs are deployed with `attachPublicIp = false` (cost and security default).

**Options**:
1. **Azure Serial Console** (recommended for lab): Navigate to the VM in the Azure portal → **Serial Console**. Use credentials from Key Vault:
   ```bash
   az keyvault secret show --vault-name <kvName> -n vm-admin-username --query value -o tsv
   az keyvault secret show --vault-name <kvName> -n vm-admin-password --query value -o tsv
   ```
   VMs use **username + auto-generated password** (no SSH key). Password is stored in Key Vault at deploy time.
2. **VM-to-VM SSH within the lab**: From another VM, SSH with the Key Vault password:
   ```bash
   ssh <username>@<private-ip>   # enter password when prompted
   ```
3. **Add a public IP** (not recommended for production labs): Re-deploy with `attachPublicIp = true`. This incurs additional cost and increases attack surface.
4. **Azure Bastion** (not included by default): You can add an Azure Bastion host to any spoke VNet at additional cost.

---

## Issue: Key Vault Access Denied When Retrieving VM Password

**Symptom**: `az keyvault secret show` returns a `403 Forbidden` error.

**Root cause A**: The deployer object ID was not provided or was incorrect when the Key Vault was created (the `deployerObjectId` parameter in `keyvault.bicep`). The access policy was not set.  
**Fix**: Add an access policy manually:
```bash
az keyvault set-policy \
  --name <kvName> \
  --upn <your-upn> \
  --secret-permissions get list
```

**Root cause B**: The Key Vault is in soft-delete retention from a previous cleanup. A new deployment with the same Key Vault name will fail to create it, leaving no access policy.  
**Fix**: Purge the soft-deleted vault first:
```bash
az keyvault purge -n <kvName>
```
Then re-run the deployment.

---

## Issue: Hub routingState Is `None` or Stays in `Provisioning`

**Symptom**: `az network vhub show -g <rg> -n vhub-1 --query routingState` returns `None` or `Provisioning` for more than 30 minutes after hub creation.

**Root cause**: The Virtual Hub control plane is still initializing. This can take 10–30 minutes for a new hub with Azure Firewall.

**Actions**:
- Wait and poll periodically. The deploy scripts handle this automatically.
- If it persists beyond 45 minutes, check Azure Service Health for outages in the hub region.

---

## Issue: ER Connection Shows `Provisioned` But Routes Not Appearing in Hub

**Symptom**: ER connection state is `Succeeded` but the hub effective route table does not show on-premises prefixes.

**Root cause**: Microsoft peering (BGP session) between the ER gateway and the provider edge has not yet established, or BGP filters are blocking route advertisement.

**Actions**:
1. Check ER circuit BGP session state:
   ```bash
   az network express-route list-arp-tables \
     -g <rg> -n <circuitName> --path primary --peering-name AzurePrivatePeering
   ```
2. Verify the provider has configured BGP and is advertising prefixes.
3. Check that private peering is configured on the circuit (not just created):
   ```bash
   az network express-route peering show \
     -g <rg> --circuit-name <circuitName> -n AzurePrivatePeering \
     --query "state" -o tsv
   ```

---

## Useful Diagnostic Commands

```bash
# Hub routing state
az network vhub show -g <rg> -n vhub-1 \
  --query "{routing:routingState, pref:hubRoutingPreference}" -o json

# Hub effective routes
az network vhub get-effective-routes \
  -g <rg> -n vhub-1 \
  --resource-type RouteTable \
  --resource-id $(az network vhub show -g <rg> -n vhub-1 --query "id" -o tsv)/hubRouteTables/defaultRouteTable

# Firewall state
az network firewall list -g <rg> \
  --query "[].{name:name, state:provisioningState}" -o table

# Routing intent state
az network vhub routing-intent list -g <rg> --vhub-name vhub-1 -o table

# All VNet connections
az network vhub connection list -g <rg> --vhub-name vhub-1 -o table

# ER circuit summary
az network express-route list -g <rg> \
  --query "[].{name:name, prov:serviceProviderProvisioningState}" -o table
```
