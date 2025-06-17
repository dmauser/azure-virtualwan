# LAB: Azure Virtual WAN Next Hop IP

# Description
This lab demonstrates how to configure a Next Hop IP in Azure Virtual WAN. It includes the deployment of a Virtual WAN, Virtual Hub, and the necessary configurations to set up a Next Hop IP.

# Prerequisites
- Use [Azure CLI Bash on Linux](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux) or [Azure Cloud Shell CLI Bash](https://shell.azure.com).
- The scripts on this repo do not work in the Azure Cloud Shell PowerShell or CMD.

# Lab Network Diagram


# Deployment Steps

1. Open your Azure CLI Bash and run the following commands to deploy the lab:

```bash
wget -q -O 1deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/1deploy.sh
chmod +x 1deploy.sh
./1deploy.sh
```
2. After the deployment is complete, run the following command to verify the resources:

```bash


