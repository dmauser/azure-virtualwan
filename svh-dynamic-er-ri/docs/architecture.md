# Architecture — Dynamic Secured Virtual WAN (svh-dynamic-er-ri)

## Overview

`svh-dynamic-er-ri` deploys a **Standard Azure Virtual WAN** with a user-defined number (1..N) of **Secured Virtual Hubs**. The topology is fully symmetric: every hub gets the same components and configuration guarantees regardless of how many hubs are deployed.

---

## Components

### 1. Azure Virtual WAN (`vwan.bicep`)

- **SKU**: Standard (required for secured hubs, hub-to-hub connectivity, ExpressRoute, and Routing Intent; do not downgrade to Basic)
- `allowBranchToBranchTraffic = true` — enables branch-to-branch traffic flows through the WAN
- `allowVnetToVnetTraffic = true` — enables VNet-to-VNet flows across hubs
- Single WAN resource shared by all N hubs

### 2. Virtual Hubs (`vhub.bicep`)

- **SKU**: Standard
- **`hubRoutingPreference = ExpressRoute`** — hard-coded in `vhub.bicep` for every hub in this lab (lab-wide rule). When the same prefix is learned from both an ExpressRoute circuit and a VPN gateway, the ER-learned route wins. Validation scripts assert this value and will flag any hub not meeting it.
- Address prefix: `10.(i×10).0.0/23` where `i` is the 1-based hub index
- Hub-to-hub connectivity is automatic through the Virtual WAN fabric (any-to-any)

### 3. Azure Firewall Basic (`secured-vhub-firewall.bicep`)

- **SKU name**: `AZFW_Hub` (Hub mode, not VNet mode)
- **Tier**: Basic
- Deployed into the Virtual Hub resource — not a standalone VNet
- Manages its own public IP allocation (`hubIPAddresses.publicIPs.count = 1`); no manually created Public IP resources
- **Provisioning is slow** (~30–45 minutes). The deploy scripts poll firewall provisioning state before proceeding to Routing Intent creation.
- Naming convention: `vhub-{i}-azfw`

### 4. Firewall Policy (`firewall-policy.bicep`)

One policy per hub (policies are not shared across hubs).

- **Tier**: Basic (matches firewall tier)
- **Rule Collection Group**: `default-allow-all-rcg` (priority 200)
  - **Rule Collection**: `allow-all-network` (type: FilterRuleCollection, priority 100, action: Allow)
    - **Rule**: `allow-all` — protocols: Any, source: `*`, destination: `*`, ports: `*`

> ⚠️ **LAB USE ONLY**: This rule permits ALL traffic through the firewall — spoke-to-spoke, inter-hub, branch-to-spoke, branch-to-branch, and outbound Internet. It exists to eliminate firewall rules as a variable during routing tests. **Never use in production.**

Rule names are stable and explicit so validation scripts can assert their existence via `az network firewall policy rule-collection-group list`.

### 5. Routing Intent (`routing-intent.bicep`)

- Resource type: `Microsoft.Network/virtualHubs/routingIntent`
- Name pattern: `{hubName}/{hubName}-ri`
- One resource per hub; mode applies uniformly across all hubs

**Modes**:

| Mode | Routing Policies Created | Next Hop |
|------|--------------------------|----------|
| `privateOnly` | `PrivateTraffic` (RFC-1918) | Hub Azure Firewall |
| `internetOnly` | `Internet` (0.0.0.0/0) | Hub Azure Firewall |
| `both` | `PrivateTraffic` + `Internet` | Hub Azure Firewall (both) |

**Sequencing**: Routing Intent creation requires the firewall to be in `Succeeded` state. In pure-Bicep deployments, the `routing-intent.bicep` module must `dependsOn` the firewall resource. In the interactive script flow, RI is created via `az network vhub routing-intent create` after a successful firewall provisioning poll.

### 6. ExpressRoute Gateways (`expressroute-gateway.bicep`)

- **Demand-driven**: a gateway is created on a hub only when:
  - A circuit definition maps to that hub (script prompts which hub each circuit connects to), OR
  - The hub has `deployErGateway = true` set explicitly
- **Scale units**: 1 (minimum, lowest cost). Each scale unit ≈ 2 Gbps throughput.
- Naming convention: `ergw-{hubName}`

Hubs with no ExpressRoute requirement have **no ER gateway** — this avoids the ~$0.073/hr gateway charge on hubs that don't need it.

### 7. ExpressRoute Circuits (`expressroute-circuit.bicep`)

- Standard tier, MeteredData billing by default (lowest cost)
- Default bandwidth: 50 Mbps
- **Interactive flow** (scripts): circuits are created via `az CLI` first so service keys can be printed and handed to the provider before Azure infra work begins. This module (`expressroute-circuit.bicep`) is available for pure-Bicep / non-interactive pipelines.
- After circuit creation the script pauses for provider handoff, then polls `serviceProviderProvisioningState` until `Provisioned` (or timeout)

### 8. Spoke VNets and NSGs (`spoke-vnet.bicep`)

- One spoke VNet per hub, address space: `10.(i×10+1).0.0/24`
- Single subnet `main` at `10.(i×10+1).0.0/27` (first /27 in the /24)
- NSG `nsg-{spokeName}`: allows inbound TCP/22 from the deployer's public IP only; no other inbound rules
- No Azure Bastion (cost reduction)
- Hub VNet connection is created **post-router-ready** by the deploy scripts (not in Bicep) so the hub router state can be polled first. `connectToHub = true` is available for one-shot Bicep deployments.
- **Propagate Default Route (`enableInternetSecurity`)**: when the Routing Intent mode is `internetOnly` or `both`, every spoke VNet connection is created with `enableInternetSecurity = true`. This is required for Routing Intent to inject the `0.0.0.0/0` default route into the spoke — without it, internet traffic bypasses the hub firewall silently. For `privateOnly` mode the flag remains `false` (no default route propagated). The Bicep path (`spoke-vnet.bicep`) always sets `enableInternetSecurity: true`; the CLI script path conditionally sets `--internet-security true` based on the selected RI mode.

### 9. Ubuntu VMs (`ubuntu-vm.bicep`)

- **Image**: Ubuntu 22.04 LTS Gen2 (`0001-com-ubuntu-server-jammy`, `22_04-lts-gen2`)
- **VM size**: auto-selected from `Standard_B2s` → `Standard_D2s_v5` → `Standard_D2s_v3` (first available in region)
- **Authentication**: Username + auto-generated password stored in Key Vault. `disablePasswordAuthentication = false` so Serial Console and password SSH work. SSH public keys are optional and unused by default.
- **No public IP** by default (`attachPublicIp = false`)
- **Boot diagnostics**: managed account (no `storageUri`) — also enables Serial Console
- **cloud-init** installs on first boot: `traceroute`, `tcpdump`, `net-tools`, `dnsutils`, `curl`, `iputils-ping`
- OS disk: `StandardSSD_LRS`

### 10. Key Vault (`keyvault.bicep`)

- Standard tier, soft-delete enabled (7-day retention)
- Access policy: deploying user/principal gets `get`, `list`, `set`, `delete` on secrets
- Secrets stored:
  - `vm-admin-username` — dynamically generated at deploy time
  - `vm-admin-password` — dynamically generated at deploy time, never echoed to stdout
- Used to retrieve credentials for Serial Console access

---

## Topology

```
Virtual WAN (Standard)
└── Hub 1 (Region₁, 10.10.0.0/23, RoutePreference=ExpressRoute)
│   ├── Azure Firewall Basic (vhub-1-azfw)
│   ├── Firewall Policy (default-allow-all-rcg → allow-all)
│   ├── Routing Intent (vhub-1-ri) → next hop: vhub-1-azfw
│   ├── ER Gateway (ergw-vhub-1) [demand-driven]
│   └── VNet Connection → spoke-1 (10.11.0.0/24) → vm-spoke-1
├── Hub 2 (Region₂, 10.20.0.0/23, RoutePreference=ExpressRoute)
│   ├── Azure Firewall Basic (vhub-2-azfw)
│   ├── Firewall Policy
│   ├── Routing Intent (vhub-2-ri)
│   ├── ER Gateway (ergw-vhub-2) [demand-driven]
│   └── VNet Connection → spoke-2 (10.21.0.0/24) → vm-spoke-2
...
└── Hub N (RegionN, 10.(N×10).0.0/23, RoutePreference=ExpressRoute)
    ├── Azure Firewall Basic
    ├── Firewall Policy
    ├── Routing Intent
    └── VNet Connection → spoke-N

Key Vault (shared)
├── Secret: vm-admin-username
└── Secret: vm-admin-password
```

---

## Address Plan

| Resource | Formula | Hub 1 Example | Hub 2 Example | Hub 4 Example |
|----------|---------|---------------|---------------|---------------|
| Hub address | `10.(i×10).0.0/23` | `10.10.0.0/23` | `10.20.0.0/23` | `10.40.0.0/23` |
| Spoke VNet | `10.(i×10+1).0.0/24` | `10.11.0.0/24` | `10.21.0.0/24` | `10.41.0.0/24` |
| VM subnet | First /27 in spoke | `10.11.0.0/27` | `10.21.0.0/27` | `10.41.0.0/27` |

All values are configurable at deploy time; the formula above is the default.

---

## Routing Design

### Hub Routing Preference = ExpressRoute

`hubRoutingPreference = ExpressRoute` is **hard-coded** in `vhub.bicep`. This means:

- When the hub router receives the same prefix from both an ExpressRoute circuit and a VPN Gateway (or site), the ER-learned route takes priority.
- This models the most common enterprise scenario where on-premises connectivity is primary via ER and VPN is a backup path.
- Validation scripts assert this value. Any hub not reporting `ExpressRoute` preference will cause a validation failure.

This differs from the `3vhub-er-ri` reference lab, which uses `ASPath` preference. The ASPath preference is appropriate when equal-cost ER paths from different circuits need fine-grained BGP selection. ExpressRoute preference is simpler and more predictable for a single ER circuit per hub.

### Routing Intent

Routing Intent is a **Global** setting on the hub — it applies to ALL attachments (VNet connections, VPN connections, ER connections) regardless of where traffic enters or exits. The next hop for all steered traffic is the hub's own Azure Firewall.

**Traffic flows enabled by Routing Intent + allow-all policy**:

| Flow | Required RI mode |
|------|-----------------|
| Spoke A → Spoke B (same hub) | `privateOnly` or `both` |
| Spoke A (hub 1) → Spoke B (hub 2) | `privateOnly` or `both` |
| On-premises (ER) → Spoke | `privateOnly` or `both` |
| On-premises → On-premises (branch-to-branch) | `privateOnly` or `both` |
| Spoke → Internet | `internetOnly` or `both` |

> ⚠️ **Internet + Firewall Basic caveat**: Azure Firewall Basic has documented restrictions on inspecting Internet-bound traffic in Secured Hub mode via Routing Intent. If `internetOnly` or `both` is selected and Internet traffic does not flow as expected, upgrade to Azure Firewall Standard or Premium.

> ⚠️ **Multi-hub double-inspection (privateOnly / both)**: In a multi-hub deployment with private Routing Intent, spoke-to-spoke traffic crossing hub boundaries is inspected by the Azure Firewall in **both** the source hub and the destination hub. This is expected behaviour — traffic leaves the source spoke → source hub firewall → WAN fabric → destination hub firewall → destination spoke. Be aware that Azure Firewall Basic is rated at approximately **250 Mbps** aggregate throughput per instance; double-firewall traversal effectively halves the available cross-hub bandwidth for lab measurements.

### Bicep vs. Script-Driven Steps

Some Azure operations have ordering constraints that cannot be expressed cleanly in a single Bicep deployment. The table below shows which steps are Bicep-managed and which are script-managed:

| Step | Managed by | Reason |
|------|-----------|--------|
| Virtual WAN creation | Bicep (`vwan.bicep`) | No ordering dependency |
| Virtual Hub creation | Bicep (`vhub.bicep`) | Parallel across hubs |
| Firewall Policy + rules | Bicep (`firewall-policy.bicep`) | No ordering dependency |
| Azure Firewall deployment | Bicep (`secured-vhub-firewall.bicep`) | Long-running but idempotent |
| Key Vault + secrets | Bicep (`keyvault.bicep`) | No ordering dependency |
| Spoke VNets + NSGs | Bicep (`spoke-vnet.bicep`) | No ordering dependency |
| Spoke VMs | Bicep (`ubuntu-vm.bicep`) | No ordering dependency |
| ER Circuit creation | Script (az CLI) | Service key must be printed and handed to provider interactively |
| Routing Intent | **Script (az CLI)** | Firewall must be `Succeeded` first; timing is too variable for Bicep `dependsOn` in multi-hub scenarios |
| Spoke VNet connections to hub | **Script (az CLI)** | Hub `routingState` must be `Provisioned` before connections succeed |
| ER Gateway creation | **Script (az CLI)** | Only on demand-driven hubs; depends on circuit being `Provisioned` by provider |
| ER Connection (circuit→gateway) | **Script (az CLI)** | Depends on both gateway and circuit being `Provisioned` |

---

## Demand-Driven ER Gateway Model

The default flow for ER circuit connectivity:

1. **Bicep deploys** all hubs, firewalls, spokes, VMs, Key Vault.
2. **Script creates** ER circuits via `az network express-route create`.
3. Script **prints service keys** and **pauses** — user hands keys to provider portal.
4. Script **overlaps** remaining Azure work (Routing Intent, VNet connections) with provider provisioning.
5. For each ER circuit, once its `serviceProviderProvisioningState = Provisioned`:
   - Script **prompts which vHub** this circuit connects to (or reads from non-interactive params)
   - Script **creates ER gateway** on that hub (`expressroute-gateway.bicep` or `az CLI`)
   - Script **creates ER connection** (circuit → gateway)
6. Script **validates** routing and prints a summary.

Hubs that no circuit maps to **never receive an ER gateway**. This is the primary cost-control mechanism for the ER gateway line item (~$0.073/hr each).

---

## Key Vault Secret Handling

The deploy scripts generate two values dynamically at runtime:

- **`adminUsername`**: a randomized username (not `root`, `admin`, or other reserved names)
- **`adminPassword`**: a cryptographically random password meeting Azure complexity requirements

Both values are passed to `keyvault.bicep` as `@secure()` parameters and stored as Key Vault secrets (`vm-admin-username`, `vm-admin-password`). They are **never echoed to stdout or logged**. To retrieve them after deployment:

```bash
az keyvault secret show \
  --vault-name <kv-name> \
  --name vm-admin-password \
  --query value -o tsv
```

The password is auto-generated at deploy time and stored in Key Vault. Retrieve it for Serial Console login or VM-to-VM SSH:

```bash
az keyvault secret show \
  --vault-name <kv-name> \
  --name vm-admin-username \
  --query value -o tsv

az keyvault secret show \
  --vault-name <kv-name> \
  --name vm-admin-password \
  --query value -o tsv
```

VMs use **username + password** authentication only. SSH public keys are optional and unused by default. `disablePasswordAuthentication = false` in the VM `linuxConfiguration` ensures Serial Console and password SSH always work.

---

## Resource Tagging

All resources receive the following tags:

| Tag key | Value |
|---------|-------|
| `labName` | `svh-dynamic-er-ri` (or user-specified) |
| `owner` | Deployer UPN |
| `purpose` | `lab` |
| `environment` | `lab` |
| `createdBy` | `svh-dynamic-er-ri-deploy` |
