# Palo Alto VM-Series + Azure Load Balancer — Configuration Reference

This document is the consolidated configuration reference for the two moving parts that
make spoke egress work in this lab: the **Azure Load Balancers** (Public + Internal) and
the **PAN-OS day-0 configuration** applied to each VM-Series firewall.

It is the authoritative "what is configured and why" companion to the top-level
[`README.md`](./README.md). The README explains the *deployment flow*; this file documents
the *steady-state config* you would inspect or reproduce by hand.

Everything below reflects what is actually deployed by the Bicep modules and the
`scripts/apply-panos-config.ps1` / `bicep/bootstrap/bootstrap.xml` config push — not an
idealized version.

---

## 1. Data flow (one screen)

```
Spoke1 / Spoke2 VM
   │  0.0.0.0/0 learned from hub defaultRouteTable
   ▼
vWAN Hub ── static 0/0 → conn-dmz ──► DMZ VNet
                                        │
                                        ▼
                          Internal LB  (HA ports, VIP 10.0.0.68)   ◄── health probe TCP/22
                                   │              │
                                   ▼              ▼
                               PA-FW-0        PA-FW-1     (active/active)
                             ethernet1/2    ethernet1/2   (trust — Azure eth2)
                                   │              │
                                   ├── VR-Trust  0/0 → next-vr VR-Untrust
                                   │              │
                                   ▼              ▼   zone trust→untrust
                               NAT: dynamic-ip-and-port (masquerade to eth1/1 IP)
                               Security: permit trust→untrust
                                   │              │
                             ethernet1/1    ethernet1/1   (untrust — Azure eth1)
                                   │              │
                                   ▼              ▼
                              Public LB  (outbound rule, SNAT → pip-lb-public)  ◄── probe TCP/22
                                          │
                                          ▼
                                      Internet
```

This is a **double-SNAT** design that mirrors the Linux `iptables MASQUERADE` variant:
PAN-OS SNATs spoke traffic to its untrust interface IP, then the Public LB outbound rule
SNATs that to the Public LB public IP.

---

## 2. Azure Load Balancer reference

Two Standard Load Balancers front the firewall pair. Source modules:
[`bicep/modules/internal-lb.bicep`](./bicep/modules/internal-lb.bicep) and
[`bicep/modules/public-lb.bicep`](./bicep/modules/public-lb.bicep).

### 2.1 Internal Load Balancer (`lb-ilb`) — spoke ingress

| Setting | Value | Notes |
|---------|-------|-------|
| SKU | **Standard**, Regional | HA ports require Standard SKU |
| Frontend | **Static private IP `10.0.0.68`** in `snet-trust` (`10.0.0.64/27`) | This is the fixed `0.0.0.0/0` next-hop that the hub `conn-dmz` connection points to |
| Backend pool `nva-backend` | PA **trust** NICs (`nic-pa-*-trust` → `ethernet1/2`) | |
| Health probe | **TCP / 22**, interval 5s, 2 probes | Answered by the `allow-ssh-ping` PAN-OS mgmt profile, not a real SSH server |
| Rule `ha-ports-rule` | protocol **All**, frontendPort **0**, backendPort **0** | **HA ports** — load-balances all TCP/UDP on all ports |
| Floating IP | **Enabled** | Required for HA-port / DSR-style forwarding so the backend sees the original destination |

> **Why HA ports + floating IP.** A single HA-ports rule (`protocol - all`, `port - 0`)
> lets one rule forward every TCP/UDP port of an internal Standard Load Balancer to the
> backend — exactly what an NVA needs, since it must handle arbitrary spoke traffic, not a
> fixed app port. Floating IP preserves the original destination in the delivered packet so
> the firewall routes/NATs correctly.
> Refs: [HA ports overview](https://learn.microsoft.com/azure/load-balancer/load-balancer-ha-ports-overview) ·
> [Manage rules → HA ports](https://learn.microsoft.com/azure/load-balancer/manage-rules-how-to#high-availability-ports) ·
> [Floating IP](https://learn.microsoft.com/azure/load-balancer/load-balancer-floating-ip)

### 2.2 Public Load Balancer (`lb-public`) — internet egress

| Setting | Value | Notes |
|---------|-------|-------|
| SKU | **Standard** | |
| Frontend | Static Standard **public IP** `pip-lb-public` | The internet-facing SNAT address for all spoke egress |
| Backend pool `nva-backend` | PA **untrust** NICs (`nic-pa-*-untrust` → `ethernet1/1`) | |
| Health probe | **TCP / 22**, interval 5s, 2 probes | Answered by `allow-ssh-ping` on `ethernet1/1` |
| Inbound rule `ssh-inbound` | TCP 22→22, `enableFloatingIP: false`, **`disableOutboundSnat: true`** | Disables the rule's automatic outbound SNAT so it doesn't conflict with the dedicated outbound rule |
| Outbound rule `snat-outbound` | protocol **All**, `allocatedOutboundPorts: 0` (auto), `enableTcpReset: true`, idle 4 min | This is what actually SNATs PA untrust egress to the public IP |

> **Why a dedicated outbound rule.** Load-balancing rules auto-program outbound NAT, but
> disabling it on the inbound rule (`disableOutboundSnat: true`) and defining an explicit
> **outbound rule** gives full control of the egress SNAT (port allocation, TCP reset, idle
> timeout) independent of the inbound path.
> Refs: [Outbound rules](https://learn.microsoft.com/azure/load-balancer/outbound-rules) ·
> [Outbound connections](https://learn.microsoft.com/azure/load-balancer/load-balancer-outbound-connections)

### 2.3 Health probe source — why the VR return route matters

Every IPv4 Load Balancer health probe originates from **`168.63.129.16`** (identified by the
`AzureLoadBalancer` service tag). **Both** LBs probe from this same address — the ILB hits
`ethernet1/2`, the Public LB hits `ethernet1/1`. If the firewall answered a probe out the
wrong interface the probe would be asymmetric and the backend would be marked *down*. This is
the entire reason for the **dual virtual-router** design in §3.3.
Ref: [Health probes → probe source IP](https://learn.microsoft.com/azure/load-balancer/load-balancer-custom-probe-overview#probe-source-ip-address).

---

## 3. PAN-OS configuration reference

Applied identically to both firewalls. Two sources keep it reproducible:

- **`bicep/bootstrap/bootstrap.xml`** — full day-0 candidate config consumed via Azure Files
  bootstrap on first boot.
- **`scripts/apply-panos-config.ps1`** — an idempotent XML-API push (`type=config&action=set`
  subtrees + commit) that re-applies the *same* config to firewalls that booted at factory
  default. The two are kept 1:1.

Image pin: `paloaltonetworks:vmseries-flex:byol:11.1.612` (config version `11.1.0`). PAN-OS
12.x is intentionally avoided — it forces a first-use GUI wizard that blocks all API access.

### 3.1 Interfaces & NIC mapping

| Azure NIC (index) | Subnet | PAN-OS interface | Zone | Role |
|-------------------|--------|------------------|------|------|
| `nic-pa-N-mgmt` (0) | `snet-mgmt` `10.0.0.0/27` | Management plane (via `mgmt-interface-swap`) | — | GUI/SSH/licensing |
| `nic-pa-N-untrust` (1) | `snet-untrust` `10.0.0.32/27` | `ethernet1/1` | `untrust` | Public LB backend, internet egress |
| `nic-pa-N-trust` (2) | `snet-trust` `10.0.0.64/27` | `ethernet1/2` | `trust` | ILB HA-ports backend, spoke ingress |

Both data interfaces are **DHCP clients** with **`create-default-route: no`** — the Azure DHCP
option-3 default route is suppressed so it can't fight the explicit `0/0` static routes in the
virtual routers. Both carry the `allow-ssh-ping` interface-management-profile so LB probes on
TCP/22 succeed without a real SSH daemon.

### 3.2 Interface management profile

```
profiles/interface-management-profile: allow-ssh-ping  → ssh=yes, ping=yes
```

HTTP/HTTPS are intentionally omitted on the data interfaces. This profile is the PAN-OS
equivalent of the Linux lab's `iptables -A INPUT -p tcp --dport 22 -j ACCEPT`.

### 3.3 Virtual routers (dual-VR)

Two virtual routers are used because **both** LBs probe from `168.63.129.16` and each probe
must return out the interface it arrived on. A single VR cannot route one address
symmetrically for two interfaces at once.

**VR-Untrust** (owns `ethernet1/1` — Public LB / internet egress):

| Destination | Next hop | Interface | Metric | Purpose |
|-------------|----------|-----------|--------|---------|
| `0.0.0.0/0` | `10.0.0.33` | `ethernet1/1` | 10 | Internet egress + symmetric Public-LB probe return |
| `10.0.0.0/8` | next-vr **VR-Trust** | — | 20 | Hand RFC1918 back to the trust VR |

**VR-Trust** (owns `ethernet1/2` — ILB HA-ports backend / spoke ingress):

| Destination | Next hop | Interface | Metric | Purpose |
|-------------|----------|-----------|--------|---------|
| `168.63.129.16/32` | `10.0.0.65` | `ethernet1/2` | 10 | ILB probe symmetry (beats the `0/0` below) |
| `10.0.0.0/8` | `10.0.0.65` | `ethernet1/2` | 10 | Spoke return path back through the vHub |
| `0.0.0.0/0` | next-vr **VR-Untrust** | — | 10 | Internet egress hand-off (triggers zone crossing → NAT + security) |

Egress path in full: `spoke → eth1/2 → VR-Trust 0/0 → VR-Untrust → eth1/1 → SNAT → Public LB PIP`.

### 3.4 Zones & vsys import

```
vsys1 import: ethernet1/1, ethernet1/2   (zones may only reference imported interfaces)
zone untrust → ethernet1/1
zone trust   → ethernet1/2
```

The vsys import block is mandatory — without it the commit fails even though `load config`
accepts the candidate.

### 3.5 NAT policy

```
rule trust-to-untrust-masquerade
  from trust  to untrust  source any  destination any  service any
  source-translation: dynamic-ip-and-port → interface-address ethernet1/1
```

`dynamic-ip-and-port` + `interface-address` = MASQUERADE to the DHCP IP on `ethernet1/1`.
The Public LB outbound rule then re-SNATs that to `pip-lb-public` (the double-SNAT).

### 3.6 Security policy

```
rule permit-trust-to-untrust
  from trust  to untrust  source/dest/app/service any  action allow  log-end yes
```

**Lab-only** permit-all. PAN-OS evaluates security *after* NAT. The implicit
`intrazone-default: allow` / `interzone-default: deny` rules still apply underneath.

> ⚠️ **Production:** replace the permit-all with App-ID / service-scoped rules and restrict
> the `nsg-dmz` mgmt exposure (TCP/443 + TCP/22 are open from `*` in the lab).

### 3.7 Session setting for HA-ports failover

```
deviceconfig/setting/session: tcp-reject-non-syn = no
```

Allows non-SYN TCP (mid-flow FIN/RST) so that connections the ILB may redistribute to the
other instance after a failover are not dropped.

---

## 4. End-to-end packet walk (spoke → internet)

1. Spoke VM sends to `0.0.0.0/0`; hub `defaultRouteTable` (learned) forwards to `conn-dmz`.
2. `conn-dmz` static `0/0 → 10.0.0.68` delivers to the **ILB** frontend.
3. ILB HA-ports rule (floating IP) forwards to a PA **trust** NIC (`ethernet1/2`), original
   destination preserved.
4. **VR-Trust** matches `0/0 → next-vr VR-Untrust`; crossing into VR-Untrust exits `ethernet1/1`.
5. Zone **trust → untrust** triggers **NAT** (masquerade to eth1/1 IP) and the **security**
   permit rule.
6. Packet leaves `ethernet1/1` toward `10.0.0.33`; the **Public LB** outbound rule SNATs the
   source to `pip-lb-public` and sends it to the internet.
7. Return traffic reverses: Public LB → eth1/1 → NAT un-translate → VR-Trust `10.0.0.0/8 →
   10.0.0.65` → eth1/2 → ILB → hub → spoke.

Health probes are independent: `168.63.129.16` → ILB → eth1/2 (returned via VR-Trust `/32`)
and `168.63.129.16` → Public LB → eth1/1 (returned symmetrically via VR-Untrust `0/0`).

---

## 5. Verification

```bash
# --- Azure side ---
az network lb rule list -g rg-nva-spoke-internet-pa --lb-name lb-ilb -o table            # ha-ports-rule, All/0/0
az network lb outbound-rule list -g rg-nva-spoke-internet-pa --lb-name lb-public -o table # snat-outbound
az network lb address-pool address list -g rg-nva-spoke-internet-pa --lb-name lb-ilb --pool-name nva-backend -o table

# ILB frontend must be 10.0.0.68
az network lb frontend-ip show -g rg-nva-spoke-internet-pa --lb-name lb-ilb -n <fe-name> --query privateIPAddress -o tsv

# --- PAN-OS side (SSH to a mgmt PIP) ---
show interface all
show routing route virtual-router VR-Trust
show routing route virtual-router VR-Untrust
test routing fib-lookup virtual-router VR-Trust ip 8.8.8.8
show running nat-policy
show running security-policy

# --- Data-plane proof (from a spoke VM) ---
curl -s https://ifconfig.io          # should return the Public LB PIP
```

If a firewall shows *down* in an LB backend pool, the cause is almost always the probe
return path — confirm the `168.63.129.16/32` route in **VR-Trust** and the symmetric `0/0`
in **VR-Untrust** (§3.3), and that `allow-ssh-ping` is bound to the probed interface.

---

## 6. Azure documentation references

- Load Balancer HA ports — https://learn.microsoft.com/azure/load-balancer/load-balancer-ha-ports-overview
- Manage rules (HA ports) — https://learn.microsoft.com/azure/load-balancer/manage-rules-how-to#high-availability-ports
- Floating IP — https://learn.microsoft.com/azure/load-balancer/load-balancer-floating-ip
- Outbound rules — https://learn.microsoft.com/azure/load-balancer/outbound-rules
- Outbound connections (SNAT) — https://learn.microsoft.com/azure/load-balancer/load-balancer-outbound-connections
- Health probes / probe source IP — https://learn.microsoft.com/azure/load-balancer/load-balancer-custom-probe-overview#probe-source-ip-address
- About IP `168.63.129.16` — https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16
- SKU comparison — https://learn.microsoft.com/azure/load-balancer/skus#sku-comparison

PAN-OS bootstrap references are cited inline in [`bicep/bootstrap/bootstrap.xml`](./bicep/bootstrap/bootstrap.xml).
