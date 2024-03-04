## Intro

This lab aims to build a two Virtual WANs with two spokes and interconnect them over ExpressRoute.

## Lab Diagram

![](./diagram.png)

## Deploy this solution

Build vWAN base environment using CLI script: [deploy.azcli](./deploy.azcli), or run the following command:

```bash
curl -s https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/two-vwans/deploy.azcli | bash
```

**Note 1**: CLI is in bash format. PPlease run the script using Azure Cloud Shell Bash or Azure CLI for Linux. This script does not work over Azure CLI for Windows.