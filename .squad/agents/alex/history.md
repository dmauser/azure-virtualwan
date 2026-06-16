# Alex — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Built `main.bicep` orchestrator to drive Phase 1 topology decisions
- Implemented decision-tree logic selecting preset configuration based on user topology preference
- Created 2 connectivity modules:
  - `vnet-connection.bicep` — vWAN vNet connection with delegation and route propagation
  - `vpn-site.bicep` — VPN site provisioning with address prefix and link bandwidth config
- Established module composition pattern that allows main.bicep to call core modules (from Naomi) + connectivity modules as single declarative flow

### Key Insight
Orchestrator layer benefits from clear module interfaces (input parameters, output IDs). Decision-tree logic in main.bicep decouples topology selection from infrastructure details, enabling presets to drive deployment without orchestrator rewrites. Module interdependencies require careful dependency ordering (hubs before sites, connections after both).

## Learnings

- `Microsoft.Network/virtualHubs/routingIntent` rejects deployment if the hub firewall is not in `Succeeded` state; Bicep modules must enforce `dependsOn` on the firewall resource, while CLI scripts use post-provisioning `az network vhub routing-intent create`.
- Routing Intent destination strings are ARM-canonical: `'PrivateTraffic'` (RFC-1918 aggregate) and `'Internet'` (0.0.0.0/0). Policy names (`PrivateTraffic`, `InternetTraffic`) are labels only.
- Azure Firewall Basic tier in secured-hub mode supports `internetOnly`/`both` Routing Intent for connectivity testing but lacks IDPS and TLS inspection; document the Basic-tier caveat in any lab that uses these modes.
- Routing Intent is mutually exclusive with custom hub route tables; never add static routes to `defaultRouteTable` that overlap RI destinations.
- `hubRoutingPreference = ExpressRoute` is a lab-wide invariant for svh-dynamic-er-ri; fixed in `vhub.bicep` and validated by assertion scripts.
- **VNet connection `enableInternetSecurity` (Propagate Default Route)** is a silent prerequisite for Routing Intent internet modes: if omitted (default false), the `0.0.0.0/0` default route is NOT injected into the spoke and internet traffic bypasses the hub firewall. Must be set to `true` via `--internet-security true` in CLI (`az network vhub connection create`) for any `internetOnly` or `both` RI mode. The Bicep path sets it unconditionally (`enableInternetSecurity: true`); the CLI path must set it conditionally based on the selected RI mode.
- In multi-hub deployments with private Routing Intent, inter-hub spoke-to-spoke traffic is inspected by the firewall in BOTH the source and destination hubs (double inspection). Azure Firewall Basic is ~250 Mbps aggregate — cross-hub throughput is approximately halved in lab measurements.
- When validating RI internet mode, the most reliable assertion is `az network vhub connection show ... --query enableInternetSecurity` — this checks the control-plane flag directly without requiring data-plane traffic. Asserting the presence of `0.0.0.0/0` in effective routes requires the connection and RI to be fully provisioned and the route table to be populated, which can be timing-dependent in CI.

## Team Update: 3vhub-er-ri Lab (2026-05-26)
- Naomi delivered new `3vhub-er-ri/` lab: 3-region vWAN with ER (East+West via Megaport), AzFw Basic all hubs, RI (private). Uses native CLI for RI (no Bicep), ASPath hub preference, single interactive script with ER pause-poll pattern. LABS_INDEX.md updated.

## Session: svh-dynamic-er-ri Lab Delivery (2026-06-15)

### Lab Delivered
**svh-dynamic-er-ri** — Dynamic replacement for `3vhub-er-ri`. Parameterized 1–4 hubs with ExpressRoute, Azure Firewall Basic, Routing Intent. Uses **ExpressRoute** hubRoutingPreference (not ASPath as in 3vhub-er-ri).

### Work Completed
- Authored `routing-intent.bicep` defining all three RI modes (privateOnly, internetOnly, both) with canonical ARM JSON shapes
- Documented routing design in `alex-routing-design.md`: ExpressRoute preference rationale, RI JSON schemas, destination strings, global mode enforcement, Azure Firewall Basic caveat, no custom route tables rule, resource naming convention
- Validated RI modes against reference lab and ARM API requirements

### Key Decisions Made
1. **ExpressRoute preference (not ASPath)**: Simpler, more predictable for single-ER-per-hub topologies in dynamic labs
2. **All RI modes supported**: privateOnly (default), internetOnly, both — with documented Basic SKU Internet caveat
3. **No custom hub route tables**: RI incompatible with static routes overlapping destinations
4. **Naming contract**: `<hubName>/<hubName>-ri` for RI child resources

### Learnings Confirmed
- RI destination strings are ARM-canonical: `PrivateTraffic` (RFC-1918 aggregate), `Internet` (0.0.0.0/0)
- Basic tier lacks IDPS/TLS inspection; document for internetOnly/both modes
- Routing Intent requires firewall `Succeeded` state; CLI creation after firewall deployment (Naomi's scripts)
- Global RI mode (same mode on all hubs) prevents asymmetric routing
