
# Lab: Virtual WAN and forced tunneling over ExpressRoute

## Intro

This lab aims to build a Virtual WAN with tree spokes and force tunneling Internet traffic over ExpressRoute using [Megaport Internet](https://docs.megaport.com/megaport-internet/) to simulate scenarios where the customer wants to use ExpressRoute for Internet access (also known as forced tunneling).

This lab leverages [MegaPort Cloud Router (MCR)](https://docs.megaport.com/mcr/) and two Virtual Cross Connects (VXCs) where one is for ExpressRoute and the other for Megaport Internet.

## Lab Diagram

![](./media/ft-wan.png)

## Lab Steps

To provision this lab, follow those two simple steps:

- Step 1: Build vWAN base environment using CLI script: ![ft-deploy.wan.sh](./ft-deploy-vwan.azcli), or run the following command:

```bash
curl -s https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/ft-wan/ft-deploy-vwan.azcli | bash
```	
  
Note 1: CLI is bash format. Please, use Azure Cloud Shell Bash to run the script or Azure CLI for Linux. This script does not work over Azure CLI for Windows.

- Step 2: Provision a MCR and create two VXCs:
  
    2.1 - First VXC Azure ExpressRoute. For more details, consult: [Creating an ExpressRoute connection](https://docs.megaport.com/cloud/megaport/microsoft/#creating-an-expressroute-connection).
    
    2.2 - Second VXC for Megaport Internet. For more details, consult: [Creating a Megaport Internet Connection for an MCR](https://docs.megaport.com/megaport-internet/mcr/).

    Here is how the MCR options during the process of creating both VXCs:
    
    ![](./media/megaport-step2.png)


    Note 2: The script will finish only when the ER Circuit is provisioned at the Provider side.

    Here is how the MCR should look like with both VXCs (ExpressRoute and Megaport Internet) should look like:

    ![](./media/mcr-vxcs.png)

## Validations

1) Review Megaport Internet connection status and Public IP.

![](./media/megaport-internet-details.png)

2) Review how default route is injected on the MCR via Looking Glass.

![](./media/mcr-looking-glass.png)

3) Review how default route is injected on the ExpressRoute Circuit.

![](./media/defaultroute-ercircuit.png)


4) Check in Virtual WAN default route table the default route injected.

![](./media/vhub-effectiveroutes.png)

5) Ensure the VNET connections have default route enabled as shown:

![](./media/vnet-propagatedefaultroute.png)

6) Dump Spoke1VM NIC effective routes and check if default route is populated with the Virual Newtork Gateways as next hop.

![](./media/spoke1vmnic.png)

7) Login to Spoke1VM validated the its Public IP:
    
    ```bash
    curl ifconfig.io
    ```
![](./media/spoke1vm-ifconfig.png)