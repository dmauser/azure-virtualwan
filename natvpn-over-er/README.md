# Lab - Virtual WAN Scenario: IPsec VPN with NAT over ER

### Intro

The goal of this lab is to validate IPSec over Express oute using Virtual WAN leveraging only Azure to emulate On-premises.
There are two networks using the same IP prefix (10.3.0.0/24), one the on-premises (extended branch) and another in Azure VNET (Spoke4) connected to Virtual WAN.
That is to demonstrate that you can use IPSec + NAT VPN Gateway functionality to handle overlapping IP scenarios usually common on Vendor integration or merging and acquisitions.
Another important point to highlight for the context of this lab is the overlapping traffic goes over IPSec VPN the other non-overlapping traffic goes over regular ExpressRoute.

### Lab Diagram

On the diagram below extended branch VM (10.3.0.4) always goes over IPSec over ExpressRoute when communicating with any Spoke Azure VM. It will always show it with source IP

![network diagram](./media/vpnnatoverer-vwan.png)

### Considerations and requirements

- An Extended-Branch with prefix range 10.3.0.0/24 overlaps with Spoke4 VNET connected to the vHUB.
 - 100.64.1.0/24 is the NAT address prefix associated with the Spoke4 VNET.
 - 100.64.2.0/24 is the NAT address prefix associated with the extended branch.
- Traffic between Extended-Branch and all vWAN-connected spokes (1,2,3 and 4) will always go over IPSec over ER and get translated to 100.64.2.0/24 (as source) when hits any of those VNETS. On the other way, vWAN-connected spokes will reach Extended-Branch using IPSec over ER but only Spoke4 VNET gets translated to 100.64.2.0/24. The remaining spoke VNETs 1,2 and 3 will retain their address space (see connectivity tests output for more information)
- Branch (10.100.0.0/24) has an NVA OPNSense preconfigured with S2S VPN reaching both vWAN VPN Gateway instances using private IPs 192.168.1.4 and 192.168.1.5
  - Note that **OPNsense** used as VPN Server has **username:root** and **password:opnsense**
  - A BGP session is configured between the VTI interfaces (10.200.0.1) and both vWAN VPN Gateway instances BGP IPs 192.168.1.14 and 192.168.1.15.
  - You have to advertise the 10.3.0.0/24 (overlapping with Azure) in order to vWAN VPN Gateway NAT rule to translate it to 100.64.2.0/24.
  - **Special note** BGP over APIPA does not work over NAT, you have to use default BGP IP addresses vWAN VPN Gateway .14 and .15
 - This lab creates two Expressroute circuits and requires you to provision them with an ER connectivity provider. In this particular lab, I used MegaPort Cloud Router (MCR) to connect both ER circuits.

### Deploy this solution

The lab is also available in the above .azcli that you can rename as .sh (shell script) and execute. You can open [Azure Cloud Shell (Bash)](https://shell.azure.com).

Review the parameters below and make changes based on your needs:

```Bash
#Parameters
region=southcentralus
rg=lab-vwan-vpner
vwanname=vwan-vpner
hubname=vhub1
username=azureuser
password="Msft123Msft123" #Please change your password
vmsize=Standard_B1s #VM Size
mypip=$(curl -4 ifconfig.io -s) #Replace with your home Public IP in case you run this over Cloudshell
```

Please, run the following steps to build the entire lab:

#### Step 1 - Deploy the Lab

```bash
wget -O vwan-natvpner-deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/natvpn-over-er/natvpner-deploy.azcli
chmod +xr vwan-natvpner-deploy.sh
./vwan-natvpner-deploy.sh
```

#### Step 2 - Provision ER Circuits with Provider

Ensure that ExpressRoute Circuits er-circuit-vhub1 and er-circuit-branch are provisioned. That is required to connect them to the respective ER Gateways in Step 3.

#### Step 3 - Connect ER Circuit

In this step, the script below connect branch-er-circuit to the Branch ER Gateway and vhub1-er-circuit to the vHub ER Gateway.

```bash
wget -O vwan-natvpner-conn.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/vpn-over-er/natvpner-conn.azcli
chmod +xr vwan-natvpner-conn.sh
./vwan-natvpner-conn.sh
```

### Validation

