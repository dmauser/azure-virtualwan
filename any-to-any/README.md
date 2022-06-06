# Lab - Virtual WAN Scenario: Any-to-Any

## Intro

The goal of this lab is to demonstrate and validate the Azure Virtual WAN scenario...

### Lab diagram

The lab uses the same amount of VNETs (six total) and two regions with Hubs, and the remote connectivity to two branches using site-to-site VPN using and BGP. Below is a diagram of what you should expect to get deployed:

![net diagram](./media/networkdiagram.png)

### Components

- Two Virtual WAN Hubs in two different regions (default EastUS and WestUS).
- Six VNETs (Spoke 1 to 6) that are connected directly to their respective vHUBs.
- All Linux VMs include basic networking utilities such as: traceroute, tcptraceroute, hping3, nmap, curl.
    - For connectivity tests, you can use curl <"Destnation IP"> and the output should be the VM name.

### Deploy this solution

The lab is also available in the above .azcli that you can rename as .sh (shell script) and execute. You can open [Azure Cloud Shell (Bash)](https://shell.azure.com) and run the following commands build the entire lab:

```bash
wget -O a2a-deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/any-to-any/a2a-deploy.azcli
chmod +xr a2a-deploy.sh
./a2a-deploy.sh 
```

**Note:** the provisioning process will take around 45 minutes to complete.

Alternatively (recommended), you can run step-by-step to get familiar with the provisioning process and the components deployed:

```bash

```

### Validation

```bash
```

### Clean-up

```bash
```