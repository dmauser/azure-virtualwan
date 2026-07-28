---
name: "azure-ilb-probe-symmetry"
description: "Azure LB health-probe 168.63.129.16 symmetric routing for multi-NIC NVAs — canonical dual-VR solution"
domain: "azure-networking, nva, panos, routing"
confidence: "high"
source: "earned — live defect on pa-fw-0/pa-fw-1, validated by Amos 2026-07-27; dual-VR confirmed via reference scenario3"
tools: []
---

## Context

Any Network Virtual Appliance (NVA) placed as an Azure Standard Load Balancer backend must handle health probe traffic symmetrically. This is critical for multi-NIC NVAs (e.g., Palo Alto VM-Series, Cisco CSR, FortiGate) where the probe arrives on one NIC but the NVA's routing table might send the reply out a different NIC — causing Azure SDN to drop it as a spoofed packet.

**When this bites you:**
- ILB health probe shows 0% healthy despite the NVA being up and responsive
- Spoke/branch egress through the NVA is completely blackholed
- The NVA can ping or curl the internet but the ILB never marks it healthy

## Patterns

### The Invariant

**Azure Standard LB health probes always originate from `168.63.129.16`** (the Azure platform fabric IP, RFC non-routable, used for all Azure platform traffic including IMDS, Azure DNS, and LB probes). This address does NOT appear in any standard BGP table, RFC-1918 summary, or DHCP-assigned route — you must handle it explicitly.

**CRITICAL: Both the External LB (ELB) and the Internal LB (ILB) probe from the SAME source IP `168.63.129.16`.** This is the root cause of the single-VR approach failing when both LBs are present.

### The Asymmetric Routing Failure (Single-VR)

```
Azure ILB probe → trust NIC (eth1/2, 10.0.0.64/27)
  PAN-OS generates SYN-ACK to 168.63.129.16
  No /32 route → falls to default 0.0.0.0/0 → ethernet1/1 (untrust)
  SYN-ACK exits untrust NIC with trust source IP
  Azure SDN: source IP belongs to trust subnet, wrong NIC → DROP
  Probe: no ACK received → backend marked unhealthy
```

### ⚠️ Anti-Pattern: Single-VR Host Route (ELB + ILB topology)

When **both** an ELB and an ILB are present, adding a `/32` host route for 168.63.129.16 in a single virtual router trades one 0%-healthy probe for another:

```
Before fix (no /32):
  ILB probe (arrives eth1/2) → 0/0 → eth1/1 → WRONG → 0% healthy ✗
  ELB probe (arrives eth1/1) → 0/0 → eth1/1 → correct ✓

After single-VR /32 fix (168.63.129.16/32 → eth1/2):
  ILB probe (arrives eth1/2) → /32 → eth1/2 → correct ✓
  ELB probe (arrives eth1/1) → /32 → eth1/2 → WRONG → 0% healthy ✗
```

A single VR has exactly one route for a given destination. It is **impossible** to route 168.63.129.16 symmetrically for both probed NICs simultaneously in one VR.

### ✅ Canonical Fix: Dual Virtual Routers

Create one VR per dataplane NIC. Each VR is scoped to its NIC, so each LB's probe naturally returns via the interface it arrived on.

**Reference:** [microhack-azure-panfw scenario3](https://github.com/davidsntg/microhack-azure-panfw/blob/main/scenario3/README.md):
> "define TWO distinct Virtual Routers (Trusted and Untrusted) per firewall instance, as the Azure Internal Load Balancer and External Load Balancer rely on the SAME probing source IP address 168.63.129.16."

#### VR-Untrust (owns the ELB-probed NIC: ethernet1/1)

```xml
<entry name="VR-Untrust">
  <interface><member>ethernet1/1</member></interface>
  <routing-table><ip><static-route>

    <!-- 0/0 → eth1/1: internet egress + ELB probe symmetric return -->
    <entry name="default-via-untrust">
      <destination>0.0.0.0/0</destination>
      <nexthop><ip-address>10.0.0.33</ip-address></nexthop>
      <interface>ethernet1/1</interface>
      <metric>10</metric>
    </entry>

    <!-- 10/8 → next-vr: inbound DNAT return path to spoke subnets -->
    <entry name="rfc1918-10-to-vr-trust">
      <destination>10.0.0.0/8</destination>
      <nexthop><next-vr>VR-Trust</next-vr></nexthop>
      <metric>20</metric>
    </entry>

  </static-route></ip></routing-table>
</entry>
```

ELB probe (from 168.63.129.16) arrives `eth1/1` → no /32 in this VR → 0/0 → exits `eth1/1` → **symmetric** ✓

#### VR-Trust (owns the ILB-probed NIC: ethernet1/2)

```xml
<entry name="VR-Trust">
  <interface><member>ethernet1/2</member></interface>
  <routing-table><ip><static-route>

    <!-- /32 probe route: ILB probe arrives eth1/2, must return eth1/2 -->
    <entry name="azure-probe-via-trust">
      <destination>168.63.129.16/32</destination>
      <nexthop><ip-address>10.0.0.65</ip-address></nexthop>
      <interface>ethernet1/2</interface>
      <metric>10</metric>
    </entry>

    <!-- Spoke return path: hub routes spoke replies via eth1/2 trust gw -->
    <entry name="rfc1918-10-via-trust">
      <destination>10.0.0.0/8</destination>
      <nexthop><ip-address>10.0.0.65</ip-address></nexthop>
      <interface>ethernet1/2</interface>
      <metric>10</metric>
    </entry>

    <!-- Internet egress hand-off: spoke traffic → VR-Untrust → eth1/1 → SNAT -->
    <entry name="default-to-vr-untrust">
      <destination>0.0.0.0/0</destination>
      <nexthop><next-vr>VR-Untrust</next-vr></nexthop>
      <metric>10</metric>
    </entry>

  </static-route></ip></routing-table>
</entry>
```

ILB probe (from 168.63.129.16) arrives `eth1/2` → /32 matches → exits `eth1/2` → **symmetric** ✓

#### PAN-OS Inter-VR Nexthop Notes

- Use `<next-vr>VR-NAME</next-vr>` inside `<nexthop>` — do NOT include `<interface>` alongside it (the receiving VR resolves the outbound interface)
- Zone crossing still occurs at the physical interface egress — trust→untrust zone policy and NAT rules still fire for egress traffic
- Available in PAN-OS 8.x+ (confirmed working in 10.1.x)

### LB Probe Coverage: Management Profile vs Security Policy

Azure LB probe traffic (TCP/22 to the PA interface IP itself) is **PAN-OS self-traffic** — processed by the management plane, NOT the dataplane security policy.

- Apply `interface-management-profile` with `ssh=yes` to **both** data interfaces (eth1/1 and eth1/2)
- This instructs PAN-OS to respond to TCP/22 on those interfaces — equivalent to `iptables -A INPUT -p tcp -m tcp -port 22 -j ACCEPT`
- No security policy rules required specifically for probe traffic

```xml
<interface-management-profile>
  <entry name="allow-ssh-ping">
    <ssh>yes</ssh>
    <ping>yes</ping>
  </entry>
</interface-management-profile>
```

Both data interfaces reference this profile in their `<interface-management-profile>` element.

## Examples

### NIC Convention Warning

The microhack reference and our lab use **opposite NIC assignments**. Do not copy directly:

| | Our lab (nva-spoke-internet-paloalto) | microhack scenario3 reference |
|---|---|---|
| ethernet1/1 | Untrust (Public LB backend) | Trust (ILB backend) |
| ethernet1/2 | Trust (ILB backend) | Untrust (Public LB backend) |

The dual-VR logic is identical; just the NIC-to-VR assignments swap. VR-X must own the NIC that LB-X probes.

### Subnet Layout (nva-spoke-internet-paloalto lab)

```
snet-untrust 10.0.0.32/27  gw 10.0.0.33 → ethernet1/1 (Public LB / ELB backend)
snet-trust   10.0.0.64/27  gw 10.0.0.65 → ethernet1/2 (ILB HA-ports backend)
ILB frontend: 10.0.0.68
```

### Complete Route Table (dual-VR, 5 routes total)

| VR | Route Name | Destination | Next-Hop | Interface | Purpose |
|---|---|---|---|---|---|
| VR-Untrust | `default-via-untrust` | 0.0.0.0/0 | 10.0.0.33 | ethernet1/1 | Internet egress + ELB probe return |
| VR-Untrust | `rfc1918-10-to-vr-trust` | 10.0.0.0/8 | next-vr:VR-Trust | — | Inbound DNAT hand-off |
| VR-Trust | `azure-probe-via-trust` | 168.63.129.16/32 | 10.0.0.65 | ethernet1/2 | ILB probe symmetric return |
| VR-Trust | `rfc1918-10-via-trust` | 10.0.0.0/8 | 10.0.0.65 | ethernet1/2 | Spoke return path |
| VR-Trust | `default-to-vr-untrust` | 0.0.0.0/0 | next-vr:VR-Untrust | — | Internet egress hand-off |

### Linux NVA Equivalent (for reference)

```bash
# Probe return routes (symmetric, one per probed NIC)
ip route add 168.63.129.16/32 via 10.0.0.65 dev eth2   # ILB probe via trust NIC
# ELB probe already symmetric: main routing table default → eth1 (untrust)
```

For Linux, a single routing table plus policy routing (`ip rule`) can achieve the same result without dual VRs. PAN-OS's VR model is the equivalent mechanism.

## Anti-Patterns

| Anti-Pattern | Why It Fails |
|---|---|
| **Single-VR /32 host route (ELB + ILB topology)** | A single VR has one route for 168.63.129.16; it can only be symmetric for ONE of the two probed NICs — fixes ILB, breaks ELB (or vice versa) |
| Relying on 10/8 or RFC-1918 to cover 168.63.129.16 | 168.63.129.16 is NOT in any RFC-1918 range — it's 168.63.x.x, a public /16 owned by Microsoft for Azure fabric use |
| Adding 168.63.129.16 to a security allow-list but not routing | Probe reachability is a routing problem, not a security policy problem |
| Using a less-specific route like /16 | Works functionally but routes the entire 168.63.0.0/16 (some of which is legitimate internet) out the wrong interface |
| Expecting PAN-OS DHCP-assigned routes to handle this | DHCP-injected routes only cover the directly connected subnet + gateway, not the Azure fabric IP |
| Single-VR /32 fix when only ILB is present (no ELB) | This works correctly for ILB-only designs — the anti-pattern only applies when BOTH an ELB AND ILB are present |

