# Lab - Secured Virtual Hubs and Routing Intent (Inter-Region)

**Content**

- [Intro](#intro)
- [Lab diagram](#lab-diagram)
- [Deploy this solution](#deploy-this-solution)
- [Validation](#validation)
  - [Examples](#examples)
- [Clean up](#clean-up)

### Intro

This lab deploys a Virtual WAN with two regions and two Secured Virtual Hubs (SVH) with Routing Intent (RI).

### Lab Diagram

The lab uses six VNETs and two regions with Secured Virtual Hubs, and remote connectivity to two branches using site-to-site VPN using and BGP. Below is a diagram of what you should expect to get deployed:

![net diagram](./media/networkdiagram.png)

### Components

TBD

### Deploy this solution

The lab is also available in the above .azcli that you can rename as .sh (shell script) and execute. You can open [Azure Cloud Shell (Bash)](https://shell.azure.com) or Azure CLI via Linux (Ubuntu) and run the following commands to build the entire lab:

```bash
curl -s https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/svh-ri-inter-region/svhri-inter-deploy.azcli | bash
```

**Note:** the provisioning process will take 60-90 minutes to complete. Also, note that Azure Cloud Shell has a 20 minutes timeout and make sure you watch the process to make sure it will not timeout causing the deployment to stop. You can hit enter during the process just to make sure Serial Console will not timeout. Otherwise, you can install it using any Linux. In can you have Windows OS you can get a Ubuntu + WSL2 and install Azure CLI.

Alternatively (recommended), you can run step-by-step to get familiar with the provisioning process and the components deployed:

```bash
Coming soon...
```
