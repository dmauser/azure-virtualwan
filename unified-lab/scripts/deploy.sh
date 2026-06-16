#!/bin/bash
# Azure Virtual WAN Unified Lab Builder — Deploy Script
# Usage: ./deploy.sh <preset-name> [resource-group] [location]

set -e

# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# ---------------------------------------------------------------------------
lab_require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  echo "[prereq] Missing required tool(s): ${missing[*]}" >&2
  for t in "${missing[@]}"; do
    case "$t" in
      az)        echo "  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      terraform) echo "  - Terraform:         https://developer.hashicorp.com/terraform/install" >&2 ;;
      gcloud)    echo "  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install" >&2 ;;
      jq)        echo "  - jq:                https://jqlang.github.io/jq/download/" >&2 ;;
      openssl)   echo "  - openssl:           install via your OS package manager" >&2 ;;
      python3)   echo "  - python3:           https://www.python.org/downloads/" >&2 ;;
      *)         echo "  - $t:                install via your OS package manager" >&2 ;;
    esac
  done

  if [ ! -t 0 ]; then
    echo "[prereq] Non-interactive shell — install the tool(s) above and re-run." >&2
    exit 1
  fi
  local ans=""
  read -r -p "[prereq] Attempt to install the missing tool(s) now? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[prereq] Install the tool(s) above and re-run." >&2
    exit 1
  fi

  local pm=""
  if   command -v brew    >/dev/null 2>&1; then pm="brew"
  elif command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v dnf     >/dev/null 2>&1; then pm="dnf"
  elif command -v yum     >/dev/null 2>&1; then pm="yum"
  fi
  if [ -z "$pm" ]; then
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually (see links above)." >&2
    exit 1
  fi
  for t in "${missing[@]}"; do
    echo "[prereq] Installing '$t' via $pm ..."
    case "$pm" in
      brew) brew install "$t" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$t" || true ;;
      dnf)  sudo dnf install -y "$t" || true ;;
      yum)  sudo yum install -y "$t" || true ;;
    esac
  done

  missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} (az/terraform/gcloud need a vendor installer — see links above). Re-run when ready." >&2
    exit 1
  fi
}
lab_require_tools az openssl

PRESET="${1:-single-hub-vpn}"
RG="${2:-rg-vwan-lab}"
LOCATION="${3:-eastus2}"

# ─────────────────────────────────────────────────────────────
# Pre-requisite checks
# ─────────────────────────────────────────────────────────────

# 1. Check Azure CLI is installed
if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI not found. Install from https://aka.ms/installazurecli"
    exit 1
fi

# 2. Check user is logged in
if ! az account show &>/dev/null; then
    echo "ERROR: Not logged in. Run 'az login' first."
    exit 1
fi

# 3. Check virtual-wan extension is installed; auto-install if missing
if ! az extension show --name virtual-wan &>/dev/null 2>&1; then
    echo "⚙️  Installing required extension: virtual-wan..."
    az extension add --name virtual-wan --yes --output none
fi

# 4. Check Bicep CLI is available; install if missing
if ! az bicep version &>/dev/null 2>&1; then
    echo "⚙️  Installing Bicep CLI..."
    az bicep install
fi

# 5. Validate preset file exists
PRESET_FILE="presets/${PRESET}.bicepparam"
if [ ! -f "$PRESET_FILE" ]; then
    echo "❌ Preset not found: $PRESET_FILE"
    echo ""
    echo "Available presets:"
    ls presets/*.bicepparam 2>/dev/null | sed 's|presets/||;s|.bicepparam||' | sed 's/^/  • /'
    exit 1
fi

# 6. Print summary
SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv)

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Azure Virtual WAN — Unified Lab Builder                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Preset:       $PRESET"
echo "📦 RG:           $RG"
echo "📍 Location:     $LOCATION"
echo "🔑 Subscription: $SUBSCRIPTION_NAME"
echo ""

# Create resource group
echo "🔧 Creating resource group..."
az group create --name "$RG" --location "$LOCATION" --output none

# Deploy
echo "🚀 Deploying (this may take 30-60 minutes for VPN gateways)..."
az deployment group create \
    --resource-group "$RG" \
    --template-file main.bicep \
    --parameters "$PRESET_FILE" \
    --parameters adminPassword="$(openssl rand -base64 16)!" \
    --name "vwan-lab-$(date +%Y%m%d-%H%M%S)" \
    --output table

echo ""
echo "✅ Lab deployed successfully!"
echo ""
echo "🧹 To clean up: az group delete --name $RG --yes --no-wait"
