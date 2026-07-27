# Holden — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: repo-improvements (2026-05-04T21:44:17Z)

### Work Completed
- Expanded `README.md` to 35 links covering all 34 lab/resource folders
- Created `docs/SCRIPT_CONVENTIONS.md` — standardized script structure, naming, and error handling
- Created `docs/LAB_README_TEMPLATE.md` — consistent lab documentation sections and format
- Established conventions for future lab development (chosen `.azcli` pattern, optional template adoption)

### Decision Accepted
- **Documentation Standards for azure-virtualwan** — defined conventions for scripts and lab documentation

### Key Insight
Consistency at scale requires clear templates and conventions. Flexible adoption model allows existing labs to update incrementally while new labs follow standards immediately.

## Session: unified-iac-analysis (2026-05-04T16:51:00Z)

### Work Completed
- Deep architectural analysis of ALL 30+ lab scenarios for unified Bicep consolidation
- Cataloged every scenario's resources, routing config, connectivity model, and complexity
- Researched Azure Verified Modules (AVM) — identified 14 relevant resource modules + 1 pattern module
- Identified 7 critical gaps in AVM coverage (Hub BGP Connections, Route Maps, NVA deployment, etc.)
- Produced full architecture proposal with module hierarchy, effort estimation, and risk assessment
- Analysis delivered directly to Daniel as comprehensive report

### Key Findings
- AVM `avm/ptn/network/virtual-wan` pattern module covers ~60% of base infrastructure needs
- Critical gap: No AVM module for `Microsoft.Network/virtualHubs/bgpConnections` (needed by 8+ labs)
- NVA scenarios (OPNsense, Linux FRR) require fully custom modules — no AVM coverage
- Recommended hybrid approach: AVM for core VWAN infra + custom modules for NVA/BGP/advanced routing
- Estimated total effort: XL (16-20 weeks for 2 engineers)

### Decision Proposed
- **Unified IaC Framework Architecture** — hybrid AVM + custom Bicep approach with scenario selection

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Created 3 deployment presets via `.bicepparam` files:
  - `single-hub-vpn.bicepparam` — minimal topology (1 hub, 1 branch, VPN-only)
  - `any-to-any.bicepparam` — full mesh (2+ hubs, 2+ spokes, bidirectional routing)
  - `secured-vhub.bicepparam` — secured hub variant (Azure Firewall, policy routing)


## [ARCHIVED: Early learnings from 2026-05 — 2026-06-15]
See git history for full context.


- The diagram (`.png` + `.excalidraw`) now lives inside `nva-spoke-internet/media/`; README uses `./media/` local paths throughout. Prior decision to use root-level `media/` is superseded.
- The Excalidraw open-instructions block (VS Code extension + excalidraw.com + raw GitHub URL) is the correct pattern for labs that ship `.excalidraw` source inside their folder.
- `bicep/cloud-init/` and `bicep/main.json` must be included in the Files tree; they were present on disk but absent from the README.

## Team Update: 3vhub-er-ri Lab (2026-05-26)
- Naomi delivered new `3vhub-er-ri/` lab: 3-region vWAN with ER (East+West via Megaport), AzFw Basic all hubs, RI (private). Uses native CLI for RI (no Bicep), ASPath hub preference, single interactive script with ER pause-poll pattern. LABS_INDEX.md updated.

---

## Team Update: 2026-07-24

**Lab Status:** nva-spoke-internet Bicep rebuild **COMPLETE & VALIDATED**

The team successfully rebuilt the nva-spoke-internet lab infrastructure as code. All agents contributed:
- naomi: 13 Bicep files
- alex: 6 deployment scripts
- holden: README + topology diagram
- amos: QA validation (8/8 PASS + 1 LOW defect fixed)

Lab is ready for end-to-end testing.

---

## Session: PA Diagram Creation — 2026-07-27

**Task:** Produce flow-first architecture diagrams for the Palo Alto VM-Series NVA lab.

**Files created:**
- `nva-spoke-internet-paloalto/media/nva-spoke-internet-paloalto.svg` (16,360 bytes — hand-authored, self-contained, 1400×720 viewBox)
- `nva-spoke-internet-paloalto/media/nva-spoke-internet-paloalto.excalidraw` (76,557 bytes — 108 elements, Excalidraw v2 JSON)

### Learnings

**Layout choices matching Linux diagram:**
- Identical canvas (1400×720), same background (#f8fafc), same container color vocabulary (hub=blue, dmz=amber, spokes=green, internet=blue, on-prem=slate dashed).
- Same numbered-hop badge style (double-circle: white outer r=13, colored inner r=10, white bold numeral).
- Same footer legend bar across bottom.
- Arrow weight/style conventions preserved: data path stroke-width=3 (main), 2.5 (secondary), purple dashed for route advertisement, brown dashed bidirectional for IPsec.

**PA-specific differences from Linux diagram:**
- 7 hops (vs 5 in Linux) — added Internal LB (hop 4) and Public LB (hop 6) explicitly as distinct hops.
- PA-FW-1 / PA-FW-2 replace Ubuntu NVA-1 / NVA-2; boxes include 3-tier NIC callout (mgmt · untrust · trust) and trust→untrust SNAT label.
- ILB explicitly labeled "HA Ports · trust side" with frontend IP 10.0.0.68 (same as Linux; ILB is what the hub's 0/0 points at in both labs).
- Public LB labeled with SNAT outbound + pip-lb-pa-public placeholder (no live public IP in diagram).
- On-prem block is visually identical to Linux diagram (same Linux IPsec NVA + vm-onprem + UDR note) — the on-prem portion does not change between Linux and PA variants.

**Windows write gotcha:**
- PowerShell heredoc (`@'...'@`) piped to `Out-File` fails with OS error 206 for JSON >~8KB on Windows.
- Solution: write via `python -c` inline script using `json.dump()`, which handles any content size reliably.

**2026-07-24 — DEPLOYMENT STATUS:** lab is LIVE in DMAUSER-FDPO (eastus2, B2s), 7/7 validation PASS — Alex

---

## Session: PA Lab Documentation — 2026-07-27

**Task:** Author `nva-spoke-internet-paloalto/README.md` and `nva-spoke-internet-paloalto/EXPECTED-RESULTS.md` for the Palo Alto VM-Series lab.

**Files created:**
- `nva-spoke-internet-paloalto/README.md` (~29,125 chars) — full lab README mirroring Linux lab structure exactly
- `nva-spoke-internet-paloalto/EXPECTED-RESULTS.md` (~20,525 chars) — expected validation baseline, Phase 1–5

### Learnings

**NVA_NAMES default mismatch (critical gotcha for any PA lab user):**
- `validate-flow.sh` defaults to `NVA_NAMES="pa-nva-0 pa-nva-1"`
- Bicep `palo-alto.bicep` names VMs `pa-fw-0` and `pa-fw-1`
- User must run: `NVA_NAMES="pa-fw-0 pa-fw-1" ./scripts/validate-flow.sh`
- Documented prominently in README Validation section and in EXPECTED-RESULTS Phase 4 preamble.
- Flagged also in Alex's bootstrap decision drop as a low-severity residual risk.

**Phase 4 WARN-only design (architectural rationale documented):**
- PAN-OS session tables and NAT counters are only accessible via management plane (HTTPS/SSH).
- `az vm run-command` cannot execute PAN-OS CLI commands — credentials not provisioned.
- Phase 3 `curl` data-plane result is the authoritative PASS/FAIL signal.
- Phase 4 = WARN × 2 (one per firewall) regardless of actual firewall state; this is correct and expected.
- Expected final score: PASS 12 / FAIL 0 / WARN 4.

**ILB inside snet-trust (not a dedicated snet-ilb):**
- Linux lab used a separate `snet-ilb` (/26) for the ILB frontend.
- PA lab places the ILB frontend (`10.0.0.68`) directly inside `snet-trust` (10.0.0.64/27).
- Hub routing contract is unchanged: `conn-dmz` static route `0/0 → 10.0.0.68` is identical.
- Documented in Address Plan table and How Default Route Works section.

**snet-trust has NO UDR (by design — must be clearly explained):**
- `snet-mgmt` and `snet-untrust` carry UDR `0/0 → Internet`.
- `snet-trust` deliberately has NO UDR — adding `0/0 → Internet` on the trust subnet would black-hole return traffic from the Internet (traffic arriving from the Public LB needs to reach the PA trust NIC directly, not be re-routed).
- This asymmetric UDR design is not obvious to first-time readers; explanation added to Address Plan section.

**BYOL eval mode table in README:**
- Explicitly documented what works unlicensed vs. what requires a license.
- UNLICENSED (eval): routing, NAT, security policy, HA — the full lab validation passes.
- LICENSED only: Threat Prevention, URL Filtering, WildFire.
- Added to both README (Palo Alto VM-Series Details section) and EXPECTED-RESULTS Summary.

**Bootstrap graceful degradation:**
- If the storage account or bootstrap files are absent at VM boot, PA boots in minimal DHCP mode.
- The deploy script warns but continues — the VM will be reachable but unconfigured (no NAT policy, no security zones from bootstrap.xml).
- Documented in README bootstrap flow section.

**Double-SNAT explanation (needed for log correlation):**
- Spoke source IP → PA NAT (to untrust NIC IP) → Azure Public LB SNAT (to pip-lb-public).
- PAN-OS session logs show spoke IP; Azure LB logs show PA untrust IP. Need both to correlate.
- Documented in EXPECTED-RESULTS Phase 3 and README How Default Route Works.

**16-output contract preserved:**
- All output names match the Linux lab exactly — same keys, same semantics.
- `nvaNames` array output now contains `['pa-fw-0', 'pa-fw-1']` instead of the Linux NVA names.

---

## Session: PA Doc Corrections — 2026-07-27T20:35:00Z

**Task:** Review and correct `nva-spoke-internet-paloalto/README.md` and `EXPECTED-RESULTS.md` ahead of review gate.

### Corrections Applied

**Excalidraw link — exact form required (task contract):**
- Prior session wrote: `> 🖉 **[▶ Open this diagram in Excalidraw](...)**` with `🖉` emoji and bold-linked text.
- Task contract specifies: `> 📐 [Open the editable diagram in Excalidraw](...)` with `📐` emoji and plain link text.
- Corrected line 13 of README.md to the exact specified form. Removed the secondary multi-line Excalidraw options block (VS Code extension, manual open, raw URL) which conflicted with the single-line format.
- **Pattern for future labs:** Always use `> 📐 [Open the editable diagram in Excalidraw](<excalidraw.com URL>)` immediately under the SVG embed, no further Excalidraw text on adjacent lines.

**PASS count inconsistency corrected:**
- Prior session noted "Expected final score: PASS 12 / FAIL 0 / WARN 4" — this was copied from the Linux lab header without adjusting for the PA differences.
- Actual check count without Network Watcher: PASS 10 (Phase 1 + 2a–2f + 3a–3b + Phase 5 LB) / WARN 4 (2g + 2h NW checks + Phase 4 pa-fw-0 + pa-fw-1) / FAIL 0.
- With Network Watcher enabled: PASS 12 / WARN 2 / FAIL 0.
- The Linux lab could reach PASS 12 without NW because Phase 4 was fully scriptable (iptables counters + tcpdump evidence = 2 PASSes). For PA, Phase 4 is always WARN × 2. Subtracting those 2 from 12 gives 10.
- Corrected in: EXPECTED-RESULTS.md header line, EXPECTED-RESULTS.md Summary code block, README.md EXPECTED-RESULTS reference, README.md Files tree comment.

**RESOURCE_GROUP mismatch between deploy.sh and validate-flow.sh:**
- `deploy.sh` creates resource group `rg-nva-spoke-internet-pa` (default).
- `validate-flow.sh` defaults to `rg-nva-spoke-internet-paloalto` (stale name from earlier script iteration).
- Prior README documented the validate-flow.sh default correctly but only showed `NVA_NAMES=` in the example command, not `RESOURCE_GROUP=`.
- Corrected: example commands now show `RESOURCE_GROUP=rg-nva-spoke-internet-pa NVA_NAMES="pa-fw-0 pa-fw-1"` in Bash, `-ResourceGroup rg-nva-spoke-internet-pa -NvaNames "pa-fw-0,pa-fw-1"` in PowerShell, with a dedicated 2-item override callout box.

**Residual Risks section added to EXPECTED-RESULTS.md:**
- Task required: "a residual-risks/caveats note (BYOL unlicensed eval, PAN-OS config version 10.1.0 conservative — validate Marketplace SKU before first deploy)".
- Prior session embedded BYOL info inline at the end of the Summary table but did not create a formal Residual Risks section.
- Added 6-item risks table covering: BYOL eval mode, bootstrap.xml config version conservatism, SSH-on-untrust lab exposure, double-SNAT visibility, NVA_NAMES/RESOURCE_GROUP mismatch, and snet-trust no-UDR design rationale.

### Learnings

- When copying PASS scores from a source-lab template, always recount from the actual check types in the PA-specific validate script. PA's Phase 4 WARN-only design removes 2 PASSes compared to the Linux lab.
- RESOURCE_GROUP is as important as NVA_NAMES to override — always show both in the "quick start" validate command.
- Residual Risks sections belong in EXPECTED-RESULTS (not just README) so reviewers see them at the canonical baseline validation step.
- `📐` (U+1F4D0 "triangular ruler") is the correct Excalidraw callout emoji for this repo. `🖉` is the pencil-alt; do not use it for diagram links.
**2026-07-27:** PA lab (nva-spoke-internet-paloalto) passed review gate — Amos PASS verdict, live deploy ready (separate opt-in).

