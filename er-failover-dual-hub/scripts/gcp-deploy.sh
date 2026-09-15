#!/usr/bin/env bash
# =============================================================================
# gcp-deploy.sh — deploy the GCP "on-premises" side of the ER failover lab
#
# Builds a single-VM GCP environment plus a Partner Interconnect VLAN
# attachment. The attachment is cross-connected through a Megaport MCR to the
# existing Azure ExpressRoute circuit 'erfo-er-dallas', which lands on the
# Virtual WAN hub 'erfo-hub-scus'.
#
# The Cloud Router advertises ALL_SUBNETS plus a 10.0.0.0/8 supernet. That
# supernet is the failover probe: Azure normally learns it over the Dallas
# circuit, and should relearn it via hub-to-hub transit when that circuit drops.
#
# Usage:
#   ./gcp-deploy.sh                          # interactive
#   ./gcp-deploy.sh -p my-project -y         # non-interactive
#   GCP_PROJECT=my-project ./gcp-deploy.sh -y
#
# Options:
#   -p, --project PROJECT     GCP project ID (or set GCP_PROJECT)
#   -r, --region REGION       GCP region          (default: us-south1 = Dallas)
#   -z, --zone ZONE           GCP zone            (default: <region>-a)
#   -n, --name-prefix PREFIX  Resource name prefix (default: erfo-onprem)
#   -c, --subnet-cidr CIDR    Subnet range        (default: 10.100.0.0/24)
#                             Must be inside --advertise-range.
#   -a, --advertise-range CIDR  Supernet to advertise (default: 10.0.0.0/8)
#       --spot                Use a Spot VM (much cheaper, can be preempted)
#       --with-nat            Also create Cloud NAT (adds hourly cost)
#   -y, --yes                 Skip confirmation prompts
#   -h, --help                Show this help
#
# COST: the VLAN attachment bills hourly from creation, active or not.
#       Run ./gcp-cleanup.sh when you are done. See docs/gcp-onprem.md.
#
# WARNING — LAB ONLY. Not for production use.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
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
      gcloud)  echo "  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install" >&2 ;;
      az)      echo "  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      jq)      echo "  - jq:                https://jqlang.github.io/jq/download/" >&2 ;;
      *)       echo "  - $t:                install via your OS package manager" >&2 ;;
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
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually." >&2
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
    echo "[prereq] Still missing: ${missing[*]} (gcloud needs a vendor installer). Re-run when ready." >&2
    exit 1
  fi
}
lab_require_tools gcloud

# ---------- Defaults ---------------------------------------------------------
GCP_PROJECT="${GCP_PROJECT:-}"
REGION="us-south1"
ZONE=""
PREFIX="erfo-onprem"
SUBNET_CIDR="10.100.0.0/24"
ADVERTISE_RANGE="10.0.0.0/8"
MACHINE_TYPE="e2-micro"
USE_SPOT=0
WITH_NAT=0
NON_INTERACTIVE=0

# ---------- Helpers ----------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { echo "  $*"; }
ok()   { echo -e "  \033[32m[OK]   $*\033[0m"; }
warn() { echo -e "  \033[33m[WARN] $*\033[0m"; }
fail() { echo -e "  \033[31m[FAIL] $*\033[0m"; exit 1; }
skip() { echo -e "  \033[36m[SKIP] $*\033[0m"; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {
  local prompt="$1"
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
  read -r -p "${prompt} [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ---------- Parse arguments --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)          GCP_PROJECT="$2";     shift 2 ;;
    -r|--region)           REGION="$2";          shift 2 ;;
    -z|--zone)             ZONE="$2";            shift 2 ;;
    -n|--name-prefix)      PREFIX="$2";          shift 2 ;;
    -c|--subnet-cidr)      SUBNET_CIDR="$2";     shift 2 ;;
    -a|--advertise-range)  ADVERTISE_RANGE="$2"; shift 2 ;;
    --spot)                USE_SPOT=1;           shift   ;;
    --with-nat)            WITH_NAT=1;           shift   ;;
    -y|--yes)              NON_INTERACTIVE=1;    shift   ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$ZONE" ]] && ZONE="${REGION}-a"

# Derived resource names
NETWORK="${PREFIX}"
SUBNET="${PREFIX}-subnet"
FW_INTERNAL="${PREFIX}-allow-internal"
FW_IAP="${PREFIX}-allow-iap"
VM="${PREFIX}-vm"
ROUTER="${PREFIX}-router"
ATTACHMENT="${PREFIX}-attach"
NAT="${PREFIX}-nat"
TAG="${PREFIX}"

# VM private IP = .10 of the subnet
VM_IP="$(echo "$SUBNET_CIDR" | awk -F'[./]' '{print $1"."$2"."$3".10"}')"

# ---------------------------------------------------------------------------
# Guard: the on-prem subnet MUST sit inside the advertised supernet.
#
# The Cloud Router advertises $ADVERTISE_RANGE to the MCR, and that is the
# prefix the failover test watches swinging between circuits. If the subnet
# lives outside it, the supernet advertises address space nobody owns while
# the real host prefix rides along separately — exactly the bug this lab hit
# with the original 192.168.100.0/24 subnet.
# ---------------------------------------------------------------------------
ip_to_int() {
  local IFS=.; read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

cidr_contains() {   # cidr_contains <outer> <inner> -> 0 when outer contains inner
  local o_ip="${1%/*}" o_len="${1#*/}"
  local i_ip="${2%/*}" i_len="${2#*/}"
  (( i_len < o_len )) && return 1
  local mask=$(( o_len == 0 ? 0 : (0xFFFFFFFF << (32 - o_len)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$o_ip") & mask) == ($(ip_to_int "$i_ip") & mask) ))
}

if ! cidr_contains "$ADVERTISE_RANGE" "$SUBNET_CIDR"; then
  fail "--subnet-cidr $SUBNET_CIDR is not inside --advertise-range $ADVERTISE_RANGE. The advertised supernet must contain the on-prem subnet."
fi

# ---------- Auth -------------------------------------------------------------
log "Checking gcloud authentication..."
active_account="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "$active_account" || "$active_account" == "(unset)" ]]; then
  warn "No active gcloud account. Running: gcloud auth login"
  gcloud auth login
  active_account="$(gcloud config get-value account 2>/dev/null || true)"
fi
ok "Active account: ${active_account}"

# ---------- Project ----------------------------------------------------------
if [[ -z "$GCP_PROJECT" ]]; then
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "$GCP_PROJECT" == "(unset)" ]] && GCP_PROJECT=""
fi
if [[ -z "$GCP_PROJECT" && "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "Enter your GCP Project ID: " GCP_PROJECT
fi
[[ -z "$GCP_PROJECT" ]] && fail "GCP project ID is required (-p / GCP_PROJECT)."

G=(gcloud --project="$GCP_PROJECT" --quiet)

echo
echo "================================================================"
echo "  GCP on-premises simulator — er-failover-dual-hub"
echo "================================================================"
info "Project           : ${GCP_PROJECT}"
info "Region / zone     : ${REGION} / ${ZONE}"
info "VPC / subnet      : ${NETWORK} / ${SUBNET_CIDR}"
info "VM                : ${VM} @ ${VM_IP} (${MACHINE_TYPE}, no public IP)"
info "Cloud Router ASN  : 16550 (forced by GCP for Partner Interconnect)"
info "Advertising       : ALL_SUBNETS + ${ADVERTISE_RANGE}"
info "Attachment        : ${ATTACHMENT} (PARTNER, availability-domain-1)"
info "Spot VM           : $([[ $USE_SPOT -eq 1 ]] && echo 'yes' || echo 'no')"
info "Cloud NAT         : $([[ $WITH_NAT -eq 1 ]] && echo 'yes (adds hourly cost)' || echo 'no')"
echo "----------------------------------------------------------------"
warn "The VLAN attachment bills hourly from creation, active or not."
warn "Run ./gcp-cleanup.sh when finished. See docs/gcp-onprem.md."
echo "================================================================"
echo
confirm "Deploy to GCP project '${GCP_PROJECT}'?"

# ---------- Enable APIs ------------------------------------------------------
log "Enabling compute.googleapis.com (no-op if already enabled)..."
"${G[@]}" services enable compute.googleapis.com
ok "compute API enabled"

# ---------- VPC --------------------------------------------------------------
log "VPC network '${NETWORK}'..."
if "${G[@]}" compute networks describe "$NETWORK" >/dev/null 2>&1; then
  skip "network ${NETWORK} already exists"
else
  "${G[@]}" compute networks create "$NETWORK" \
    --subnet-mode=custom \
    --bgp-routing-mode=global \
    --mtu=1460 \
    --description="on-prem simulator for er-failover-dual-hub"
  ok "network ${NETWORK} created (global routing)"
fi

# ---------- Subnet -----------------------------------------------------------
# Reuse whatever subnet already exists in the VPC rather than keying off the
# derived name, so a lab re-addressed into "-subnet-v2" is not given a second,
# conflicting subnet on re-run.
existing_subnets="$("${G[@]}" compute networks subnets list \
  --filter="network:${NETWORK} AND region:${REGION}" --format='value(name)' 2>/dev/null)"
log "Subnet '${SUBNET}' (${SUBNET_CIDR})..."
if [[ -n "$existing_subnets" ]]; then
  if ! printf '%s\n' "$existing_subnets" | grep -qx "$SUBNET"; then
    SUBNET="$(printf '%s\n' "$existing_subnets" | head -1)"
  fi
  existing_cidr="$("${G[@]}" compute networks subnets describe "$SUBNET" --region="$REGION" --format='value(ipCidrRange)' 2>/dev/null)"
  skip "subnet ${SUBNET} already exists (${existing_cidr})"
  if [[ -n "$existing_cidr" && "$existing_cidr" != "$SUBNET_CIDR" ]]; then
    warn "existing subnet is ${existing_cidr}, not the requested ${SUBNET_CIDR}. A subnet's primary range cannot be renumbered in place — create a new subnet in the same VPC, move the VM, then delete the old one."
    VM_IP="$(echo "$existing_cidr" | awk -F'[./]' '{print $1"."$2"."$3".10"}')"
    info "VM IP adjusted to ${VM_IP} to match the existing subnet"
  fi
else
  # Private Google Access is free and lets the VM reach Google APIs without a
  # public IP or Cloud NAT.
  "${G[@]}" compute networks subnets create "$SUBNET" \
    --network="$NETWORK" \
    --region="$REGION" \
    --range="$SUBNET_CIDR" \
    --enable-private-ip-google-access
  ok "subnet ${SUBNET} created"
fi

# ---------- Firewall ---------------------------------------------------------
log "Firewall rule '${FW_INTERNAL}' (RFC1918 ingress)..."
if "${G[@]}" compute firewall-rules describe "$FW_INTERNAL" >/dev/null 2>&1; then
  skip "firewall ${FW_INTERNAL} already exists"
else
  "${G[@]}" compute firewall-rules create "$FW_INTERNAL" \
    --network="$NETWORK" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp,udp,icmp \
    --source-ranges=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
    --target-tags="$TAG" \
    --description="allow RFC1918 (Azure spokes/hubs arrive over ExpressRoute)"
  ok "firewall ${FW_INTERNAL} created"
fi

log "Firewall rule '${FW_IAP}' (IAP SSH)..."
if "${G[@]}" compute firewall-rules describe "$FW_IAP" >/dev/null 2>&1; then
  skip "firewall ${FW_IAP} already exists"
else
  # 35.235.240.0/20 is the fixed IAP TCP-forwarding range — required because
  # the VM has no public IP.
  "${G[@]}" compute firewall-rules create "$FW_IAP" \
    --network="$NETWORK" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags="$TAG" \
    --description="allow SSH from Identity-Aware Proxy"
  ok "firewall ${FW_IAP} created"
fi

# ---------- Cloud NAT (optional) --------------------------------------------
if [[ "$WITH_NAT" -eq 1 ]]; then
  log "Cloud NAT '${NAT}' (optional, billed hourly)..."
  if "${G[@]}" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" >/dev/null 2>&1; then
    skip "Cloud NAT ${NAT} already exists"
  else
    warn "Cloud NAT adds an hourly charge. Deferred until the router exists."
  fi
fi

# ---------- VM ---------------------------------------------------------------
log "VM '${VM}' (${MACHINE_TYPE}, no public IP)..."
if "${G[@]}" compute instances describe "$VM" --zone="$ZONE" >/dev/null 2>&1; then
  skip "instance ${VM} already exists"
else
  STARTUP='#!/bin/bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-onprem.conf
# Best-effort tooling. Without Cloud NAT this VM has no internet egress, so
# these installs are expected to fail — that is intentional (cost control).
# Ubuntu 22.04 already ships ping, ip, ss and nc, which cover the lab tests.
DEBIAN_FRONTEND=noninteractive apt-get update -y || true
DEBIAN_FRONTEND=noninteractive apt-get install -y traceroute tcpdump mtr-tiny dnsutils || true
echo "erfo on-prem simulator ready" > /etc/motd'

  SPOT_ARGS=()
  if [[ "$USE_SPOT" -eq 1 ]]; then
    SPOT_ARGS=(--provisioning-model=SPOT --instance-termination-action=STOP)
  fi

  "${G[@]}" compute instances create "$VM" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --subnet="$SUBNET" \
    --private-network-ip="$VM_IP" \
    --no-address \
    --tags="$TAG" \
    --metadata="startup-script=${STARTUP}" \
    --labels=lab=er-failover-dual-hub \
    "${SPOT_ARGS[@]}"
  ok "instance ${VM} created at ${VM_IP}"
fi

# ---------- Cloud Router -----------------------------------------------------
log "Cloud Router '${ROUTER}' (ASN 16550)..."
if "${G[@]}" compute routers describe "$ROUTER" --region="$REGION" >/dev/null 2>&1; then
  skip "router ${ROUTER} already exists"
else
  # Partner Interconnect requires ASN 16550. Any other value is rejected.
  "${G[@]}" compute routers create "$ROUTER" \
    --network="$NETWORK" \
    --region="$REGION" \
    --asn=16550 \
    --description="on-prem simulator router for er-failover-dual-hub"
  ok "router ${ROUTER} created"
fi

# ---------- Route advertisement ---------------------------------------------
# Set at ROUTER scope, not per-BGP-peer: the peer is auto-created only after
# Megaport activates the VXC, so a peer-scoped setting would have nothing to
# attach to at deploy time.
log "Advertising ALL_SUBNETS + ${ADVERTISE_RANGE} ..."
"${G[@]}" compute routers update "$ROUTER" \
  --region="$REGION" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-groups=ALL_SUBNETS \
  --set-advertisement-ranges="$ADVERTISE_RANGE"
ok "custom advertisement configured"

# ---------- Cloud NAT (deferred create) --------------------------------------
if [[ "$WITH_NAT" -eq 1 ]]; then
  log "Cloud NAT '${NAT}'..."
  if "${G[@]}" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" >/dev/null 2>&1; then
    skip "Cloud NAT ${NAT} already exists"
  else
    "${G[@]}" compute routers nats create "$NAT" \
      --router="$ROUTER" \
      --region="$REGION" \
      --auto-allocate-nat-external-ips \
      --nat-all-subnet-ip-ranges
    ok "Cloud NAT ${NAT} created (billed hourly — delete when done)"
  fi
fi

# ---------- VLAN attachment --------------------------------------------------
log "Partner VLAN attachment '${ATTACHMENT}'..."
if "${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" >/dev/null 2>&1; then
  skip "attachment ${ATTACHMENT} already exists"
else
  "${G[@]}" compute interconnects attachments partner create "$ATTACHMENT" \
    --region="$REGION" \
    --router="$ROUTER" \
    --edge-availability-domain=availability-domain-1 \
    --description="er-failover-dual-hub on-prem -> Megaport MCR -> erfo-er-dallas"
  ok "attachment ${ATTACHMENT} created"
fi

# ---------- Wait for the pairing key ----------------------------------------
log "Waiting for the pairing key to be issued..."
PAIRING_KEY=""
for i in $(seq 1 30); do
  PAIRING_KEY="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" \
    --region="$REGION" --format="value(pairingKey)" 2>/dev/null || true)"
  [[ -n "$PAIRING_KEY" ]] && break
  info "  (attempt ${i}/30) not yet available, retrying in 10s..."
  sleep 10
done

STATE="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" \
  --region="$REGION" --format="value(state)" 2>/dev/null || echo "UNKNOWN")"

echo
echo "================================================================"
echo "  PARTNER INTERCONNECT — PAIRING KEY"
echo "================================================================"
if [[ -n "$PAIRING_KEY" ]]; then
  echo "  ${PAIRING_KEY}"
else
  warn "Pairing key not issued yet. Re-run ./gcp-validate.sh in a few minutes."
fi
echo "----------------------------------------------------------------"
echo "  Attachment state : ${STATE}"
echo "================================================================"
echo
echo "Next steps (Megaport portal):"
echo "  1. Create / reuse an MCR in the Dallas metro."
echo "  2. VXC #1: MCR -> Google Cloud Partner Interconnect."
echo "       Paste the pairing key above. Pick region ${REGION}."
echo "       MCR peers BGP with GCP using ASN 16550."
echo "  3. VXC #2: MCR -> Azure ExpressRoute, service key"
echo "       36186b16-fbf2-43f7-8fc3-76e1c7873e9b  (erfo-er-dallas)"
echo "       MCR peers BGP with Azure using ASN 65001. Megaport assigns"
echo "       the VLAN and both /30s and creates AzurePrivatePeering on"
echo "       the circuit. Do NOT set the peering from Azure."
echo "  4. When Megaport finishes, the attachment moves to PENDING_CUSTOMER."
echo "     Activate it:"
echo "       gcloud compute interconnects attachments partner update ${ATTACHMENT} \\"
echo "         --region=${REGION} --project=${GCP_PROJECT} --admin-enabled"
echo "  5. Verify with: ./gcp-validate.sh -p ${GCP_PROJECT} -r ${REGION}"
echo
echo "SSH to the VM (no public IP — uses Identity-Aware Proxy):"
echo "  gcloud compute ssh ${VM} --zone=${ZONE} --project=${GCP_PROJECT} --tunnel-through-iap"
echo
echo "Cost: the VM is ${MACHINE_TYPE} on a 10 GB pd-standard disk (~\$0.20/day)."
echo "  Stop it between test runs:"
echo "    gcloud compute instances stop ${VM} --zone=${ZONE} --project=${GCP_PROJECT}"
echo "  Stopping the VM does NOT stop the VLAN attachment's hourly charge."
echo "  Only ./gcp-cleanup.sh does."
echo
echo "Megaport is Layer 2 — it cannot bridge GCP to Azure with a single VXC."
echo "An MCR (or physical port) must terminate BGP on both sides."
echo "See docs/gcp-onprem.md."
