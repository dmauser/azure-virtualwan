# Lab: Single region Virtual WAN Hub and S2S VPN to on-premises

## Intro

This is a simple lab to demonstrate how to build a Virtual WAN Hub with a S2S VPN connection to on-premises (branch1) using a Virtual Network Gateaway (VNG) and connecting over VPN to the vHub using IPSec S2S VPN with BGP.

## Diagram

![](./netdiagram.png)

## Deploy this solution

Use the following command to deploy this solution:

```bash
curl -s https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/single-region-vpn/deploy.azcli | bash
```

**Note:** Run it from Azure Cloud Shell Bash or Azure CLI for Linux. This script does not work over Azure CLI for Windows.

Default username: azureuser and password: Msft123Msft123. You can change it in the script under the section "Variables".