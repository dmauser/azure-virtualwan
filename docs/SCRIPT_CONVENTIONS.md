# Script Conventions

Standards for new Azure CLI scripts in this repository.

## File Naming

Use the pattern `{prefix}-{action}.azcli` where:

- **prefix** — lab abbreviation for disambiguation (e.g., `svhri-intra`, `inter-nva`, `any2any`)
- **action** — what the script does: `deploy`, `validate`, `cleanup`, `config`, etc.

Examples:
```
svhri-intra-deploy.azcli
svhri-intra-validate.azcli
svhri-intra-cleanup.azcli
```

For simple labs with a single script, `deploy.azcli` is acceptable.

## Parameter Section

Every script must start with a parameter block defining key variables:

```bash
# Parameters
region=eastus
rg=lab-svhri-intra-rg
vwanname=lab-svhri-vwan
hubname=lab-svhri-hub1
username=azureuser
password="YourSecurePassword123!"  # Change before running
vmsize=Standard_B2ms
```

Conventions:
- Use lowercase variable names with no spaces
- Group related parameters together
- Always include `region` and `rg` (resource group) at the top
- Use descriptive names that include the lab prefix

## Pre-requisite Checks

Include prerequisite validation near the top of the script:

```bash
# Pre-requisites
# Ensure Azure CLI is installed and logged in
az account show -o none 2>/dev/null || { echo "ERROR: Not logged in. Run 'az login' first."; exit 1; }

# Check for required extensions
az extension show --name virtual-wan -o none 2>/dev/null || {
  echo "Installing virtual-wan extension..."
  az extension add --name virtual-wan --only-show-errors
}

# Minimum CLI version check (optional but recommended)
echo "Azure CLI version: $(az version --query '"azure-cli"' -o tsv)"
```

## Error Handling

- For bash wrapper scripts, use `set -e` to exit on first error
- Echo progress messages before long-running commands so users know what's happening
- Use `--no-wait` judiciously — only when subsequent commands don't depend on completion

```bash
# Good: progress messages
echo "Creating Virtual WAN..."
az network vwan create -g $rg -n $vwanname --type Standard -o none

echo "Creating Virtual Hub (this takes ~10 minutes)..."
az network vhub create -g $rg -n $hubname --vwan $vwanname \
  --address-prefix 192.168.1.0/24 --location $region -o none
```

## Comments

- Describe the **why**, not the what — the Azure CLI command itself shows what it does
- Add context about architectural decisions, timing dependencies, or non-obvious ordering

```bash
# Bad: repeats the command
# Create a VNet
az network vnet create ...

# Good: explains the rationale
# Spoke VNet uses /24 to allow future subnet expansion for AKS
az network vnet create -g $rg -n spoke1 --address-prefix 10.1.0.0/24 ...
```

## Cleanup Scripts

Every lab **must** include a cleanup script or section. At minimum:

```bash
# Cleanup
echo "Deleting resource group $rg and all resources..."
az group delete -n $rg --yes --no-wait
echo "Resource group deletion initiated (runs in background)."
```

For labs that create resources across multiple resource groups, list all of them:

```bash
# Cleanup - remove all resource groups created by this lab
for group in $rg $rg-onprem $rg-branch; do
  echo "Deleting $group..."
  az group delete -n $group --yes --no-wait
done
```
