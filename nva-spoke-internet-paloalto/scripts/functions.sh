#!/usr/bin/env bash
# =============================================================================
# functions.sh — Shared helpers for nva-spoke-internet-paloalto deploy/cleanup.
# Source this file; do not execute directly.
#
# Provides:
#   log             — timestamp-prefixed progress output
#   VM_SKU_CANDIDATES — ordered DS3_v2-series SKU list (PA-compatible)
#   pick_vm_sku     — selects first unrestricted SKU via az vm list-skus
#   poll_until      — polls a command until output matches a target
#   preflight_vm_capacity — real synchronous allocation probe (throw-away RG)
# =============================================================================

# ---------- Logging ----------------------------------------------------------
# Every progress line is prefixed with [HH:MM:SS] so stalls are obvious.
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------- VM SKU candidates (DS3_v2-series, preference order) --------------
# Override before sourcing to test with different SKUs.
# Standard_B-series are NOT supported for Palo Alto VM-Series (PAYG/BYOL).
VM_SKU_CANDIDATES=(Standard_DS3_v2 Standard_DS4_v2 Standard_D3_v2 Standard_D4_v2)

# ---------- pick_vm_sku ------------------------------------------------------
# Usage: pick_vm_sku REGION RESULT_VAR
# Iterates VM_SKU_CANDIDATES; selects the first SKU that az vm list-skus
# reports with no restrictions in REGION.  Sets RESULT_VAR via printf -v.
# NOTE: az vm list-skus is best-effort only — capacity blocks are invisible to
#       it.  Always follow this with preflight_vm_capacity.
pick_vm_sku() {
  local region="$1" result_var="$2"
  local picked="" restrictions=""
  for sku in "${VM_SKU_CANDIDATES[@]}"; do
    restrictions=$(az vm list-skus -l "$region" \
      --resource-type virtualMachines \
      --query "[?name=='${sku}'].restrictions" \
      -o tsv 2>/dev/null || echo "error")
    # Accept the SKU if the restrictions field is empty or "None"
    if [[ "$restrictions" != "error" ]] && \
       [[ -z "$restrictions" || "$restrictions" == "None" ]]; then
      picked="$sku"
      break
    fi
  done
  if [[ -z "$picked" ]]; then
    log "  WARNING: No PA-compatible (DS3_v2-series) SKU with empty restrictions found in '$region'."
    log "           Tried: ${VM_SKU_CANDIDATES[*]}"
    log "           Using first candidate; preflight_vm_capacity will verify actual capacity."
    picked="${VM_SKU_CANDIDATES[0]}"
  fi
  printf -v "$result_var" '%s' "$picked"
}

# ---------- poll_until -------------------------------------------------------
# Usage: poll_until LABEL TARGET SLEEP_SEC MAX_ITER COMMAND [args...]
# Polls COMMAND (with args) until stdout exactly equals TARGET, or until
# MAX_ITER iterations are reached.  Logs each tick with a timestamp.
# On timeout, logs a WARNING and breaks (does not exit) so the caller can
# decide whether to continue or abort.
poll_until() {
  local label="$1" target="$2" sleep_sec="$3" max_iter="$4"
  shift 4
  local state="" iter=0
  while true; do
    iter=$((iter + 1))
    if [[ $iter -gt $max_iter ]]; then
      log "  WARNING: poll_until '$label' timed out after $max_iter iterations — continuing."
      break
    fi
    state=$("$@" 2>/dev/null || echo "NotFound")
    log "  ${label}: ${state}"
    [[ "$state" == "$target" ]] && break
    sleep "$sleep_sec"
  done
}

# ---------- preflight_vm_capacity --------------------------------------------
# Usage: preflight_vm_capacity REGION INITIAL_SKU RESULT_VAR
# Verifies that a VM can actually be allocated in REGION by performing a REAL
# synchronous az vm create in a throw-away resource group.
# az vm list-skus restrictions are unreliable for live capacity blocks
# (confirmed eastus 2026-06-15 live deployment — list-skus showed no
# restrictions but allocation failed with SkuNotAvailable/Capacity).
#
# - RESULT_VAR is set (via printf -v) to the first SKU that allocates.
# - Returns 0 on success, 1 when ALL candidates are capacity-blocked.
# - The probe RG is ALWAYS deleted before this function returns (even on error).
preflight_vm_capacity() {
  local region="$1" initial_sku="$2" result_var="$3"
  local rand_suffix cap_rg cap_pass err_out exit_code sku_ok probe_sku
  local capacity_blocked=true

  rand_suffix="$(openssl rand -hex 3)"
  cap_rg="capcheck-nvaspk-${region}-${rand_suffix}"
  # Throw-away password used only for the probe VM; never stored or echoed.
  cap_pass="CapChk$(openssl rand -hex 6)Aa1!"

  log "  [cap-check] Creating temp probe RG: $cap_rg in $region"
  if ! az group create -n "$cap_rg" -l "$region" --output none 2>/dev/null; then
    log "  [cap-check] WARNING: could not create probe RG — skipping capacity check."
    printf -v "$result_var" '%s' "$initial_sku"
    return 0
  fi

  log "  [cap-check] Creating probe VNet + subnet ..."
  if ! az network vnet create \
      -g "$cap_rg" -n "capchk-vnet" \
      --address-prefix "10.250.0.0/24" \
      --subnet-name "capchk-subnet" --subnet-prefix "10.250.0.0/27" \
      --location "$region" --output none 2>/dev/null; then
    log "  [cap-check] WARNING: VNet creation failed in $region — skipping capacity check."
    az group delete -n "$cap_rg" --yes --no-wait --output none 2>/dev/null || true
    printf -v "$result_var" '%s' "$initial_sku"
    return 0
  fi

  # Build probe list: initial_sku first, then remaining candidates in order.
  local -a probe_skus=("$initial_sku")
  for probe_sku in "${VM_SKU_CANDIDATES[@]}"; do
    [[ "$probe_sku" == "$initial_sku" ]] && continue
    probe_skus+=("$probe_sku")
  done

  sku_ok=""
  for probe_sku in "${probe_skus[@]}"; do
    log "  [cap-check] Probing SKU $probe_sku in $region (synchronous az vm create) ..."
    err_out="" ; exit_code=0
    err_out=$(az vm create \
      -g "$cap_rg" -n "capchk-probe" -l "$region" \
      --image Ubuntu2204 \
      --size "$probe_sku" \
      --admin-username capchk \
      --admin-password "$cap_pass" \
      --public-ip-address "" \
      --vnet-name "capchk-vnet" \
      --subnet "capchk-subnet" \
      --nic-delete-option Delete \
      --os-disk-delete-option Delete \
      --only-show-errors \
      --output none 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      sku_ok="$probe_sku"
      capacity_blocked=false
      if [[ "$probe_sku" != "$initial_sku" ]]; then
        log "  [cap-check] NOTE: Original SKU '$initial_sku' unavailable in $region."
        log "  [cap-check]       '$probe_sku' allocated successfully — using it."
      else
        log "  [cap-check] ✔ $probe_sku is allocatable in $region"
      fi
      break
    elif echo "$err_out" | grep -qiE \
        'SkuNotAvailable|AllocationFailed|capacity|not available|OverconstrainedAllocationRequest|ZonalAllocationFailed'; then
      log "  [cap-check] ✗ $probe_sku is capacity-blocked in $region"
      az vm delete -g "$cap_rg" -n "capchk-probe" --yes --no-wait \
        --output none 2>/dev/null || true
    else
      # Unexpected non-capacity error — warn and assume SKU is usable.
      log "  [cap-check] WARNING: unexpected error probing $probe_sku:"
      log "  [cap-check]   $(echo "$err_out" | head -1)"
      log "  [cap-check] Assuming $probe_sku is usable; real deployment will confirm."
      sku_ok="$probe_sku"
      capacity_blocked=false
      break
    fi
  done

  # Always delete the probe RG (--no-wait; failure is non-fatal).
  log "  [cap-check] Deleting probe RG $cap_rg (--no-wait) ..."
  az group delete -n "$cap_rg" --yes --no-wait --output none 2>/dev/null || true

  if [[ "$capacity_blocked" == "true" ]]; then
    log ""
    log "  ╔══════════════════════════════════════════════════════════════╗"
    log "  ║  ✗  VM CAPACITY PRE-FLIGHT FAILED — deployment aborted      ║"
    log "  ╚══════════════════════════════════════════════════════════════╝"
    log "  Region     : $region"
    log "  Tried SKUs : ${probe_skus[*]}"
    log ""
    log "  ➤ Suggested alternate regions to try:"
    log "      eastus2  westus2  westus3  centralus  southcentralus  northcentralus"
    log ""
    log "  ➤ Re-run deploy.sh and choose a different region."
    log "  ➤ No vWAN/vHub resources were deployed — safe to re-run."
    return 1
  fi

  printf -v "$result_var" '%s' "$sku_ok"
  return 0
}
