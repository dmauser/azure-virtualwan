# Lab - Virtual WAN Scenario: IPsec VPN over ER

### Lab diagram

![network diagram](./media/vpnoverer-vwan.png)

### Deploy this solution

The lab is also available in the above .azcli that you can rename as .sh (shell script) and execute. You can open [Azure Cloud Shell (Bash)](https://shell.azure.com) and run the following steps to build the entire lab:


#### Step 1 - Deploy the Lab

```bash
wget -O vwan-vpner-deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/vpn-over-er/vpner-deploy.azcli
chmod +xr vwan-vpner-deploy.sh
./vwan-vpner-deploy.sh
```

#### Step 2 - Provision ER Circuits with Provider 

Ensure that ExpressRoute Circuits er-circuit-vhub1 and er-circuit-

#### Step 3 - Connect ER Circuit