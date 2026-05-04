# Azure Virtual WAN — Lab Index

> Comprehensive catalog of all lab scenarios in this repository.

## Learning Path (Recommended Order)

1. **any-to-any** — Start here: basic Virtual WAN any-to-any connectivity
2. **single-region-vpn** — Single region with S2S VPN branches
3. **isolate-vnets-custom** — Isolated VNets using custom route tables
4. **secured-vhub** — Add Azure Firewall to your Virtual Hub (Secured vHub)
5. **svh-ri-intra-region** — Secured vHub with Routing Intent (intra-region)
6. **svh-ri-inter-region** — Secured vHub with Routing Intent (inter-region)
7. **svh-bgp** — Secured vHub with BGP endpoint
8. **inter-region-azfw** — Route inter-region traffic through Azure Firewall spoke
9. **inter-region-nva** — Route traffic through an NVA spoke
10. **inter-region-nvabgp** — NVA spoke routing with BGP peering
11. **nva-spoke-internet** — NVA on spoke for internet egress
12. **nva-spoke-internet-inter-hub** — Multi-hub NVA internet egress
13. **vpn-over-er** — IPsec VPN over ExpressRoute
14. **natvpn-over-er** — IPsec VPN with NAT over ExpressRoute
15. **ft-wan** — Forced tunneling over ExpressRoute
16. **svh-inter-region-er** — Inter-region SVH via ExpressRoute
17. **two-vwans** — Two interconnected Virtual WANs
18. **vrf-vwan** — VRF scenarios in Virtual WAN
19. **migration-single-region** — Migrate hub-spoke to Virtual WAN (single region)
20. **migration-multi-region** — Migrate hub-spoke to Virtual WAN (multi-region)

## Full Lab Catalog

| Lab Folder | Topic | Key Scripts | README | Status |
|-----------|-------|-------------|--------|--------|
| [any-to-any](./any-to-any/) | Basic any-to-any connectivity | a2a-deploy.azcli, a2a-validate.azcli | ✅ | Complete |
| [ft-wan](./ft-wan/) | Forced tunneling over ExpressRoute | ft-deploy-vwan.azcli | ✅ | Complete |
| [gr-vwan](./gr-vwan/) | Global routing / multi-region VWAN | deploy-vwan.azcli, deploy-branches.azcli | — | 📝 Scripts only |
| [inter-region-azfw](./inter-region-azfw/) | Route traffic through Azure Firewall spoke | irazfw-deploy.azcli, irazfw-validate.azcli | ✅ | Complete |
| [inter-region-nva](./inter-region-nva/) | Route traffic through NVA spoke | irnva-deploy.azcli, irnva-validate.azcli | ✅ | Complete |
| [inter-region-nva-srp](./inter-region-nva-srp/) | Inter-region NVA with SRP variant | irnvasrp-deploy.azcli, irnvasrp-validate.azcli | ✅ | Complete |
| [inter-region-nvabgp](./inter-region-nvabgp/) | NVA spoke routing with BGP peering | irbgp-deploy.azcli, irbgp-validate.azcli | ✅ | Complete |
| [inter-region-transitbgp](./inter-region-transitbgp/) | Inter-region transit via BGP | 1-irbgp-deploy-repro.azcli, 2-vnethub-transit-deploy-opn.azcli | — | 📝 Scripts only |
| [isolate-vnets-custom](./isolate-vnets-custom/) | Isolated VNets with custom route tables | ivc-deploy.azcli, ivc-validate.azcli | ✅ | Complete |
| [migration-multi-region](./migration-multi-region/) | Multi-region migration to Virtual WAN | 1-deploy-hub-spoke.azcli, 3-deploy-vwan-svh.azcli | — | 📝 Scripts only |
| [migration-single-region](./migration-single-region/) | Single-region migration to Virtual WAN | 1-deploy-hub-spoke.azcli, 3-deploy-vwan-svh.azcli | — | 📝 Scripts only |
| [natvpn-over-er](./natvpn-over-er/) | IPsec VPN with NAT over ExpressRoute | natvpner-deploy.azcli, natvpner-validate.azcli | ✅ | Complete |
| [nva-spoke-internet](./nva-spoke-internet/) | NVA on spoke for internet egress | nva-spoke-internet.azcli | ✅ | Complete |
| [nva-spoke-internet-inter-hub](./nva-spoke-internet-inter-hub/) | Multi-hub NVA spoke internet egress | nva-spk-internet-deploy.azcli, nva-spk-internet-validate.azcli | ✅ | Complete |
| [p2s-usrgrp-svh](./p2s-usrgrp-svh/) | Point-to-Site VPN with user groups on SVH | *(config JSONs only)* | — | 📝 Scripts only |
| [pa-ngfw-saas](./pa-ngfw-saas/) | Palo Alto NGFW SaaS integration | deploy.azcli | ✅ | Complete |
| [secured-vhub](./secured-vhub/) | Secured Virtual Hub with Azure Firewall | svh-deploy.azcli, svh-routing.azcli | ⚠️ | Draft |
| [single-region-vpn](./single-region-vpn/) | Single-region S2S VPN to on-premises | deploy.azcli | ✅ | Complete |
| [static-route-considerations](./static-route-considerations/) | Static route + ExpressRoute considerations | *(no scripts)* | ⚠️ | Draft |
| [svh-bgp](./svh-bgp/) | Secured Virtual Hub with BGP endpoint | svhbgp-deploy.azcli | ✅ | Complete |
| [svh-inter-region-er](./svh-inter-region-er/) | Inter-region SVH over ExpressRoute | svh-irer-deploy.azcli, svh-irer-erconn.azcli | ✅ | Complete |
| [svh-multi-hub](./svh-multi-hub/) | Multi-hub Secured Virtual Hub | deploy-base.azcli, deploy-vpn.azcli | — | 📝 Scripts only |
| [svh-ri-bgp](./svh-ri-bgp/) | SVH Routing Intent with BGP | svh-ri-deploy.azcli, 1deploy-base.azcli | — | 📝 Scripts only |
| [svh-ri-inter-region](./svh-ri-inter-region/) | Inter-region SVH with Routing Intent | svhri-inter-deploy.azcli, svhri-inter-validate.azcli | ✅ | Complete |
| [svh-ri-intra-region](./svh-ri-intra-region/) | Intra-region SVH with Routing Intent | svhri-intra-deploy.azcli, svhri-intra-validate.azcli | ✅ | Complete |
| [two-vwans](./two-vwans/) | Two interconnected Virtual WANs | deploy.azcli | ✅ | Complete |
| [vhub-nvafw-bgp](./vhub-nvafw-bgp/) | vHub NVA firewall with BGP | nvafw-bgp-deploy.azcli, validate.azcli | — | 📝 Scripts only |
| [vnet-conn-perf](./vnet-conn-perf/) | VNet connection performance testing | 1-deploy-vnets.sh, 2-connect-vnets.sh | — | 📝 Scripts only |
| [vpn-over-er](./vpn-over-er/) | IPsec VPN over ExpressRoute | vpner-deploy.azcli, vpner-conn.azcli | ✅ | Complete |
| [vrf-vwan](./vrf-vwan/) | VRF scenarios in Virtual WAN | vrf-vwan-azfw.azcli, vrf-validate.azcli | ✅ | Complete |

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Complete — has README with documentation |
| ⚠️ | Draft — README says "under construction" or is minimal |
| 📝 | Scripts only — no README documentation |

---

*Last updated: 2026-05-04*
