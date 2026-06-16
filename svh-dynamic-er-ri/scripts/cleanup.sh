#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Cleanup for svh-dynamic-er-ri (Secured Virtual WAN lab)
#
# Usage:
#   ./cleanup.sh                        # prompts for RG, then deletes it
#   ./cleanup.sh --rg <RG>              # specify RG, still prompts to confirm
#   ./cleanup.sh --rg <RG> --vms-only   # delete only VMs + NICs + PIPs
#   ./cleanup.sh --rg <RG> --er-only    # delete ER connections, gateways, circuits
#   ./cleanup.sh --rg <RG> --all        # delete entire resource group (default)
#
# ⚠️  ER circuits and gateways accrue hourly cost.
# ⚠️  Provider-side VXCs / cross-connects must be removed separately.
# =============================================================================

set -euo pipefail

rg=""
mode="all"   # vms-only | er-only | all

# ---------- Parse arguments -------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rg)        rg="$2"; shift 2 ;;
    --vms-only)  mode="vms-only"; shift ;;
    --er-only)   mode="er-only"; shift ;;
    --all)       mode="all"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- Banner ----------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        svh-dynamic-er-ri — Lab Cleanup                          ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  ER circuits and gateways accrue hourly cost.                ║"
echo "║  ⚠️  Provider-side VXCs must be removed separately.              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Prompt for RG if not provided
if [[ -z "$rg" ]]; then
  read -r -p "Resource group to clean up [lab-svh-dynamic-er-ri]: " rg
  rg="${rg:-lab-svh-dynamic-er-ri}"
fi

# Verify RG exists
if ! az group show -n "$rg" &>/dev/null; then
  echo "ERROR: Resource group '$rg' not found or not accessible."
  exit 1
fi

# ---------- Mode: delete entire RG ------------------------------------------
if [[ "$mode" == "all" ]]; then
  echo ""
  echo "  Mode: DELETE ENTIRE RESOURCE GROUP"
  echo "  Resource group: $rg"
  echo ""
  echo "  This will permanently delete ALL resources including:"
  echo "    • All vHubs, vWAN, Azure Firewalls"
  echo "    • All ExpressRoute circuits (billing stops immediately)"
  echo "    • All VMs, VNets, Key Vault"
  echo ""
  read -r -p "  Type 'yes' to confirm deletion of '$rg': " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "  Cleanup cancelled."
    exit 0
  fi
  echo ""
  echo "  Deleting resource group $rg (--no-wait, runs in background)..."
  az group delete -n "$rg" --yes --no-wait
  echo "  Deletion submitted. Monitor with:"
  echo "    az group show -n $rg --query provisioningState -o tsv"
  echo ""
  echo "  NOTE: Key Vault enters soft-delete (7-day retention). To purge:"
  echo "    az keyvault list-deleted --query '[].name' -o tsv"
  echo "    az keyvault purge -n <KV_NAME>"
  exit 0
fi

# ---------- Mode: VMs only --------------------------------------------------
if [[ "$mode" == "vms-only" ]]; then
  echo ""
  echo "  Mode: VMs ONLY (delete VMs, NICs, and public IPs)"
  echo "  Resource group: $rg"
  echo ""
  vm_ids=$(az vm list -g "$rg" --query '[].id' -o tsv 2>/dev/null || echo "")
  if [[ -z "$vm_ids" ]]; then
    echo "  No VMs found in $rg. Nothing to do."
    exit 0
  fi

  echo "  VMs found:"
  az vm list -g "$rg" --query '[].{Name:name,Region:location}' -o table
  echo ""
  read -r -p "  Delete all VMs, NICs, and public IPs? Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "  Cleanup cancelled."
    exit 0
  fi

  # Collect NIC and PIP IDs before deleting VMs
  declare -a nic_ids pip_ids
  while IFS= read -r vm_id; do
    vm_name=$(basename "$vm_id")
    nic_id=$(az vm show --id "$vm_id" \
      --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null || echo "")
    [[ -n "$nic_id" ]] && nic_ids+=("$nic_id")
    pip_id=$(az network public-ip show -g "$rg" \
      -n "pip-${vm_name}" --query id -o tsv 2>/dev/null || echo "")
    [[ -n "$pip_id" ]] && pip_ids+=("$pip_id")
  done <<< "$vm_ids"

  echo "  Deleting VMs..."
  # shellcheck disable=SC2086
  az vm delete --ids $vm_ids --yes --output none
  echo "  VMs deleted."

  if [[ ${#nic_ids[@]} -gt 0 ]]; then
    echo "  Deleting NICs..."
    az network nic delete --ids "${nic_ids[@]}" --output none
    echo "  NICs deleted."
  fi

  if [[ ${#pip_ids[@]} -gt 0 ]]; then
    echo "  Deleting public IPs..."
    az network public-ip delete --ids "${pip_ids[@]}" --output none
    echo "  Public IPs deleted."
  fi

  echo "  VM cleanup complete."
  exit 0
fi

# ---------- Mode: ER only ---------------------------------------------------
if [[ "$mode" == "er-only" ]]; then
  echo ""
  echo "  Mode: ER ONLY (delete ER connections, gateways, and circuits)"
  echo "  Resource group: $rg"
  echo ""
  echo "  ⚠️  Provider-side VXCs / cross-connects must be deprovisioned FIRST."
  echo "  ⚠️  Deleting the circuit while the provider VXC is active may orphan the order."
  echo ""

  er_gw_names=$(az resource list -g "$rg" \
    --resource-type Microsoft.Network/expressRouteGateways \
    --query '[].name' -o tsv 2>/dev/null || echo "")
  er_circuit_names=$(az resource list -g "$rg" \
    --resource-type Microsoft.Network/expressRouteCircuits \
    --query '[].name' -o tsv 2>/dev/null || echo "")

  if [[ -z "$er_gw_names" && -z "$er_circuit_names" ]]; then
    echo "  No ER gateways or circuits found in $rg. Nothing to do."
    exit 0
  fi

  echo "  ER Gateways:"
  [[ -n "$er_gw_names" ]] && echo "$er_gw_names" | sed 's/^/    /' || echo "    (none)"
  echo "  ER Circuits:"
  [[ -n "$er_circuit_names" ]] && echo "$er_circuit_names" | sed 's/^/    /' || echo "    (none)"
  echo ""
  read -r -p "  Delete all ER connections, gateways, and circuits? Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "  Cleanup cancelled."
    exit 0
  fi

  # Delete ER gateway connections first (per gateway)
  if [[ -n "$er_gw_names" ]]; then
    while IFS= read -r gw_name; do
      [[ -z "$gw_name" ]] && continue
      conn_ids=$(az network express-route gateway connection list \
        -g "$rg" --gateway-name "$gw_name" --query '[].id' -o tsv 2>/dev/null || echo "")
      if [[ -n "$conn_ids" ]]; then
        echo "  Deleting connections for gateway $gw_name..."
        while IFS= read -r conn_id; do
          [[ -z "$conn_id" ]] && continue
          conn_nm=$(basename "$conn_id")
          az network express-route gateway connection delete \
            --name "$conn_nm" -g "$rg" --gateway-name "$gw_name" --yes -o none
        done <<< "$conn_ids"
      fi
    done <<< "$er_gw_names"
    echo "  ER gateway connections deleted."

    # Delete ER gateways
    echo "  Deleting ER gateways..."
    while IFS= read -r gw_name; do
      [[ -z "$gw_name" ]] && continue
      az network express-route gateway delete -g "$rg" -n "$gw_name" --yes -o none &
    done <<< "$er_gw_names"
    wait
    echo "  ER gateways deleted."
  fi

  # Delete ER circuits
  if [[ -n "$er_circuit_names" ]]; then
    echo "  Deleting ER circuits..."
    while IFS= read -r circ_name; do
      [[ -z "$circ_name" ]] && continue
      az network express-route delete -g "$rg" -n "$circ_name" --yes -o none &
    done <<< "$er_circuit_names"
    wait
    echo "  ER circuits deleted."
  fi

  echo "  ER cleanup complete."
  exit 0
fi
