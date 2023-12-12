
# Lab: Virtual WAN and forced tunneling over ExpressRoute

## Intro

This lab aims to build a Virtual WAN with tree spokes and force tunneling Internet traffic over ExpressRoute using [Megaport Internet](https://docs.megaport.com/megaport-internet/).

## Lab Diagram

## Lab Steps

- Step 1: Build vWAN base environment using CLI script: ![ft-deploy.wan.cli](./ft-deploy-vwan.azcli).
  
Note: CLI is bash format. Please, use Azure Cloud Shell Bash to run the script or Azure CLI for Linux. This script does not work over Azure CLI for Windows.

```bash
- Step 2: Provision a MCR and create two connections:
  
    1) VXC for Azure / ExpressRoute See: [Creating an ExpressRoute connection](https://docs.megaport.com/cloud/megaport/microsoft/#creating-an-expressroute-connection).
    2) VXC for Megaport Internet.

- Step 3: Connect ft-hub1-er-circuit to the vhub or use the script ![ft-conn.azcli](./ft-conn.azcli)

## Validations

1) Review Megaport Internet connection status and Public IP.

2) Review how default route is injected on the ExpressRoute Circuit.

3) Check in Virtual WAN default route table the default route injected.

4) Ensure the VNET connections have default route enabled as shown:

5) Validate if the VM is 