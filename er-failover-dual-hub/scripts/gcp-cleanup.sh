#!/usr/bin/env bash
# =============================================================================
# gcp-cleanup.sh — delete the GCP on-premises side of the ER failover lab
#
# Deletes in reverse dependency order:
#   VLAN attachment -> Cloud NAT -> Cloud Router -> VM -> firewall -> subnet -> VPC
#
# IMPORTANT: delete the Megaport VXC that pairs with this attachment FIRST.
# Deleting the GCP attachment while the VXC is live leaves the Megaport side
# billing and stranded.
#
# Usage:
#   ./gcp-cleanup.sh
#   ./gcp-cleanup.sh -p my-project -y
#
# Options:
#   -p, --project PROJECT     GCP project ID (or set GCP_PROJECT)
#   -r, --region REGION       GCP region          (default: us-south1)
#   -z, --zone ZONE           GCP zone            (default: <region>-a)
#   -n, --name-prefix PREFIX  Resource name prefix (default: erfo-onprem)
#   -y, --yes                 Skip confirmation prompts
#   -h, --help                Show this help
#
# WARNING — LAB ONLY. This deletes resources. There is no undo.
# =============================================================================

set -uo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
REGION="us-south1"
ZONE=""
PREFIX="erfo-onprem"
NON_INTERACTIVE=0

log()  { echo -e "\033[0m[$(date +%H:%M:%S)] $*"; }
ok()   { echo -e "  \033[32m[OK]\033[0m   $*"; }
warn() { echo -e "  \033[33m[WARN]\033[0m $*"; }
skip() { echo -e "  \033[36m[SKIP]\033[0m $*"; }
info() { echo -e "  $*"; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)     GCP_PROJECT="$2";  shift 2 ;;
    -r|--region)      REGION="$2";       shift 2 ;;
    -z|--zone)        ZONE="$2";         shift 2 ;;
    -n|--name-prefix) PREFIX="$2";       shift 2 ;;
    -y|--yes)         NON_INTERACTIVE=1; shift   ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required." >&2; exit 1; }
[[ -z "$ZONE" ]] && ZONE="${REGION}-a"

if [[ -z "$GCP_PROJECT" ]]; then
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "$GCP_PROJECT" == "(unset)" ]] && GCP_PROJECT=""
fi
[[ -z "$GCP_PROJECT" ]] && { echo "GCP project ID is required (-p / GCP_PROJECT)." >&2; exit 1; }

NETWORK="${PREFIX}"
SUBNET="${PREFIX}-subnet"
FW_INTERNAL="${PREFIX}-allow-internal"
FW_IAP="${PREFIX}-allow-iap"
VM="${PREFIX}-vm"
ROUTER="${PREFIX}-router"
ATTACHMENT="${PREFIX}-attach"
NAT="${PREFIX}-nat"

G=(gcloud --project="$GCP_PROJECT" --quiet)

echo
echo "================================================================"
echo "  DELETE the GCP on-prem simulator — er-failover-dual-hub"
echo "================================================================"
info "Project : ${GCP_PROJECT}"
info "Region  : ${REGION} / ${ZONE}"
info "Prefix  : ${PREFIX}"
echo "----------------------------------------------------------------"
warn "DELETE THE MEGAPORT VXC FIRST."
warn "Removing the GCP attachment while the VXC is live leaves the"
warn "Megaport side stranded and still billing."
echo "----------------------------------------------------------------"
echo "Will delete, in order:"
echo "  1. VLAN attachment  ${ATTACHMENT}"
echo "  2. Cloud NAT        ${NAT}         (if present)"
echo "  3. Cloud Router     ${ROUTER}"
echo "  4. VM               ${VM}"
echo "  5. Firewall rules   ${FW_INTERNAL}, ${FW_IAP}"
echo "  6. Subnet           ${SUBNET}"
echo "  7. VPC network      ${NETWORK}"
echo "================================================================"
echo
confirm "Have you already deleted the Megaport VXC?"
confirm "Permanently delete all of the above from '${GCP_PROJECT}'?"

# ---------------------------------------------------------------------------
log "1/7  VLAN attachment '${ATTACHMENT}'..."
if "${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" >/dev/null 2>&1; then
  "${G[@]}" compute interconnects attachments delete "$ATTACHMENT" --region="$REGION" \
    && ok "attachment deleted (hourly billing stops now)" \
    || warn "failed to delete attachment ${ATTACHMENT}"
else
  skip "attachment ${ATTACHMENT} not found"
fi

# ---------------------------------------------------------------------------
log "2/7  Cloud NAT '${NAT}'..."
if "${G[@]}" compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" >/dev/null 2>&1; then
  "${G[@]}" compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" \
    && ok "Cloud NAT deleted" \
    || warn "failed to delete Cloud NAT ${NAT}"
else
  skip "Cloud NAT ${NAT} not found"
fi

# ---------------------------------------------------------------------------
log "3/7  Cloud Router '${ROUTER}'..."
if "${G[@]}" compute routers describe "$ROUTER" --region="$REGION" >/dev/null 2>&1; then
  "${G[@]}" compute routers delete "$ROUTER" --region="$REGION" \
    && ok "router deleted" \
    || warn "failed to delete router ${ROUTER} (is the attachment really gone?)"
else
  skip "router ${ROUTER} not found"
fi

# ---------------------------------------------------------------------------
log "4/7  VM '${VM}'..."
if "${G[@]}" compute instances describe "$VM" --zone="$ZONE" >/dev/null 2>&1; then
  "${G[@]}" compute instances delete "$VM" --zone="$ZONE" \
    && ok "instance deleted (boot disk goes with it)" \
    || warn "failed to delete instance ${VM}"
else
  skip "instance ${VM} not found"
fi

# ---------------------------------------------------------------------------
log "5/7  Firewall rules..."
for rule in "$FW_INTERNAL" "$FW_IAP"; do
  if "${G[@]}" compute firewall-rules describe "$rule" >/dev/null 2>&1; then
    "${G[@]}" compute firewall-rules delete "$rule" \
      && ok "firewall ${rule} deleted" \
      || warn "failed to delete firewall ${rule}"
  else
    skip "firewall ${rule} not found"
  fi
done

# ---------------------------------------------------------------------------
log "6/7  Subnet '${SUBNET}'..."
if "${G[@]}" compute networks subnets describe "$SUBNET" --region="$REGION" >/dev/null 2>&1; then
  "${G[@]}" compute networks subnets delete "$SUBNET" --region="$REGION" \
    && ok "subnet deleted" \
    || warn "failed to delete subnet ${SUBNET}"
else
  skip "subnet ${SUBNET} not found"
fi

# ---------------------------------------------------------------------------
log "7/7  VPC network '${NETWORK}'..."
if "${G[@]}" compute networks describe "$NETWORK" >/dev/null 2>&1; then
  "${G[@]}" compute networks delete "$NETWORK" \
    && ok "network deleted" \
    || warn "failed to delete network ${NETWORK}"
else
  skip "network ${NETWORK} not found"
fi

# ---------------------------------------------------------------------------
echo
echo "== Verification =="
LEFTOVER=0
check_gone() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    warn "${label} still exists"
    LEFTOVER=$((LEFTOVER + 1))
  else
    ok "${label} gone"
  fi
}

check_gone "attachment ${ATTACHMENT}" "${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION"
check_gone "router ${ROUTER}"         "${G[@]}" compute routers describe "$ROUTER" --region="$REGION"
check_gone "instance ${VM}"           "${G[@]}" compute instances describe "$VM" --zone="$ZONE"
check_gone "subnet ${SUBNET}"         "${G[@]}" compute networks subnets describe "$SUBNET" --region="$REGION"
check_gone "network ${NETWORK}"       "${G[@]}" compute networks describe "$NETWORK"

echo
echo "================================================================"
if [[ "$LEFTOVER" -eq 0 ]]; then
  echo -e "  \033[32mCleanup complete. No GCP charges remain for this lab.\033[0m"
else
  echo -e "  \033[33m${LEFTOVER} resource(s) still present — re-run in a minute.\033[0m"
  echo "  GCP deletes are eventually consistent; dependencies can lag."
fi
echo "----------------------------------------------------------------"
echo "  The Azure side is untouched. To remove it too:"
echo "    ./cleanup.sh -g rg-er-failover-dual-hub"
echo "================================================================"
