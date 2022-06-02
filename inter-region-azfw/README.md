# Lab - Virtual WAN with Isolated VNETs using custom route tables

## Intro

The goal of this lab is to demonstrate and validate Azure Virtual WAN using Isolated VNETs by leveraging a similar scenario to the one published by the vWAN official document [Scenario: Custom isolation for VNets](https://docs.microsoft.com/en-us/azure/virtual-wan/scenario-isolate-vnets-custom).


### Lab diagram

The lab uses the same amount of VNETs (six total) and two regions with Hubs, and the remote connectivity to two branches using site-to-site VPN using and BGP. Below is a diagram of what you should expect to get deployed:


### Deploy this solution

All the content of this lab has been also available in above .azcli that you can rename as .sh (shell script) and execute them. You can open Azure Cloud Shell (Bash) and run the following command to run build the entire lab:

```bash
wget -o irazfw-deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/inter-region-azfw/irazfw-deploy.azcli
chmod +xr irazfw-deploy.sh
./irazfw-deploy.sh 
```

However, it is recommended that you run step-by-step to get familiar with the provisioning process and the components deployed:

