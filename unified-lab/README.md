# 🌐 Azure Virtual WAN — Unified Lab Builder

A **decision-tree based** Bicep deployment that covers all 30+ Azure Virtual WAN lab scenarios in this repository. Instead of running individual scripts per lab, select your scenario through parameters and deploy a complete environment in one command.

## 🚀 Quick Start

```bash
# 1. Pick a preset (or customize your own)
# 2. Deploy
cd unified-lab
./scripts/deploy.sh single-hub-vpn

# PowerShell alternative:
.\scripts\deploy.ps1 -Preset single-hub-vpn
```

## 🌳 Decision Tree

Build your lab by choosing:

| Decision | Options |
|----------|---------|
| **Hub count** | 1 (single region) / 2 (dual region) / N (multi-hub) |
| **Branch connectivity** | S2S VPN (BGP) / ExpressRoute / VPN-over-ER / None |
| **Security model** | None / Azure Firewall / NVA in spoke / NVA in hub (BGP) |
| **Routing** | Default (any-to-any) / Routing Intent / Custom route tables / BGP peering |
| **Add-ons** | Test VMs / Log Analytics / DNS / P2S VPN |

## 📦 Available Presets

Each preset maps to an existing lab scenario in this repo:

| Preset | Scenario | Hubs | VPN | Firewall | Routing |
|--------|----------|------|-----|----------|---------|
| `single-hub-vpn` | Basic hub + branch VPN | 1 | ✅ | ❌ | Default |
| `any-to-any` | Multi-region hub-branch | 2 | ✅ | ❌ | Default |
| `secured-vhub` | Secured hub + routing intent | 1 | ✅ | ✅ | Routing Intent |
| *More coming in Phase 2-4...* | | | | | |

## 🏗️ Architecture

```
unified-lab/
├── main.bicep              # Entry point (decision tree parameters)
├── presets/                 # Pre-built scenario configs (.bicepparam)
├── modules/
│   ├── core/               # vWAN, spokes, branches
│   ├── connectivity/       # VPN sites, ER, VNet connections
│   ├── security/           # Azure Firewall, NVAs (Phase 2-3)
│   ├── routing/            # Route tables, routing intent (Phase 2)
│   └── shared/             # Log Analytics, ILB (Phase 3)
├── types/                  # Bicep user-defined types
└── scripts/                # Deploy/cleanup helpers
```

## 💰 Cost Optimization

This lab builder uses minimal SKUs by default:

| Resource | SKU/Size | Approx. cost/hr |
|----------|----------|-----------------|
| Test VMs | Standard_B2s | ~$0.04 |
| VPN Gateway | VpnGw1 (1 scale unit) | ~$0.19 |
| Azure Firewall | Standard | ~$1.25 |
| ER Gateway | 1 scale unit | ~$0.21 |

**💡 Tip:** Delete the resource group when done: `az group delete --name rg-vwan-lab --yes`

## 🔧 Custom Scenarios

Create your own `.bicepparam` file:

```bicep
using '../main.bicep'

param labName = 'my-custom-lab'
param primaryLocation = 'eastus2'
param hubs = [
  {
    name: 'my-hub'
    location: 'eastus2'
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: true
    deployFirewall: true
    firewallSku: 'Standard'
    enableRoutingIntent: true
    routingIntentMode: 'InternetAndPrivate'
    deployErGateway: false
  }
]
// ... add spokes, branches, etc.
```

## 📋 Prerequisites

- Azure CLI 2.50+ (`az --version`)
- Bicep CLI 0.24+ (`az bicep version`)
- An Azure subscription with permissions to create networking resources
- Sufficient quota for VPN Gateways and VMs in your target region

## 🗺️ Roadmap

- [x] **Phase 1** — Core (vWAN + hubs + spokes + branches + VPN)
- [ ] **Phase 2** — Security (Azure Firewall + Routing Intent + custom routes)
- [ ] **Phase 3** — NVA & BGP (Linux FRR, OPNsense, hub BGP peering)
- [ ] **Phase 4** — Advanced (ExpressRoute, VRF, Route Maps, PA-NGFW)
