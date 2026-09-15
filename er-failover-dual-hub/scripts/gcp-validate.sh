#!/usr/bin/env bash
# =============================================================================
# gcp-validate.sh — verify the GCP on-premises side of the ER failover lab
#
# Read-only. Checks the VPC, subnet, firewall rules, VM, Cloud Router ASN and
# advertisement configuration, the Partner Interconnect attachment state, and
# the BGP session once Megaport has built the VXC.
#
# Usage:
#   ./gcp-validate.sh
#   ./gcp-validate.sh -p my-project -r us-south1
#
# Options:
#   -p, --project PROJECT     GCP project ID (or set GCP_PROJECT)
#   -r, --region REGION       GCP region          (default: us-south1)
#   -z, --zone ZONE           GCP zone            (default: <region>-a)
#   -n, --name-prefix PREFIX  Resource name prefix (default: erfo-onprem)
#   -a, --advertise-range CIDR  Supernet expected  (default: 10.0.0.0/8)
#   -h, --help                Show this help
#
# Exits 1 if any check fails.
# =============================================================================

set -uo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
REGION="us-south1"
ZONE=""
PREFIX="erfo-onprem"
ADVERTISE_RANGE="10.0.0.0/8"
FAILURES=0

pass() { echo -e "  \033[32m[PASS]\033[0m $*"; }
fail() { echo -e "  \033[31m[FAIL]\033[0m $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  \033[33m[WARN]\033[0m $*"; }
info() { echo -e "  \033[36m[INFO]\033[0m $*"; }

ip_to_int() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

# cidr_contains <outer-cidr> <inner-cidr> -> 0 when inner is fully inside outer
cidr_contains() {
  local outer="$1" inner="$2"
  [[ "$outer" =~ ^[0-9.]+/[0-9]+$ && "$inner" =~ ^[0-9.]+/[0-9]+$ ]] || return 1
  local o_ip="${outer%/*}" o_len="${outer#*/}"
  local i_ip="${inner%/*}" i_len="${inner#*/}"
  (( i_len < o_len )) && return 1
  local mask=$(( o_len == 0 ? 0 : (0xFFFFFFFF << (32 - o_len)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$o_ip") & mask) == ($(ip_to_int "$i_ip") & mask) ))
}

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)          GCP_PROJECT="$2";     shift 2 ;;
    -r|--region)           REGION="$2";          shift 2 ;;
    -z|--zone)             ZONE="$2";            shift 2 ;;
    -n|--name-prefix)      PREFIX="$2";          shift 2 ;;
    -a|--advertise-range)  ADVERTISE_RANGE="$2"; shift 2 ;;
    -h|--help)             usage; exit 0 ;;
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
# The subnet name is resolved from the VPC below rather than assumed, so a lab
# whose subnet was re-created under a different name (e.g. "-subnet-v2" after a
# re-addressing) still validates. This is the preferred name when several exist.
SUBNET="${PREFIX}-subnet"
FW_INTERNAL="${PREFIX}-allow-internal"
FW_IAP="${PREFIX}-allow-iap"
VM="${PREFIX}-vm"
ROUTER="${PREFIX}-router"
ATTACHMENT="${PREFIX}-attach"

G=(gcloud --project="$GCP_PROJECT" --quiet)

echo
echo "================================================================"
echo "  GCP on-prem validation — project ${GCP_PROJECT}, region ${REGION}"
echo "================================================================"

# ---------------------------------------------------------------------------
echo
echo "== Network =="

if "${G[@]}" compute networks describe "$NETWORK" >/dev/null 2>&1; then
  mode="$("${G[@]}" compute networks describe "$NETWORK" --format='value(routingConfig.routingMode)' 2>/dev/null)"
  pass "VPC ${NETWORK} exists (routing mode: ${mode:-unknown})"
  [[ "$mode" == "GLOBAL" ]] || warn "routing mode is '${mode}'; GLOBAL is recommended so all regions see interconnect routes"
else
  fail "VPC ${NETWORK} not found"
fi

subnet_names="$("${G[@]}" compute networks subnets list \
  --filter="network:${NETWORK} AND region:${REGION}" --format='value(name)' 2>/dev/null)"

if [[ -z "$subnet_names" ]]; then
  fail "no subnet found in VPC ${NETWORK} / ${REGION}"
else
  if ! printf '%s\n' "$subnet_names" | grep -qx "$SUBNET"; then
    SUBNET="$(printf '%s\n' "$subnet_names" | head -1)"
  fi
  subnet_count="$(printf '%s\n' "$subnet_names" | wc -l | tr -d ' ')"
  if [[ "$subnet_count" -gt 1 ]]; then
    warn "VPC ${NETWORK} has ${subnet_count} subnets in ${REGION} ($(printf '%s' "$subnet_names" | tr '\n' ',' | sed 's/,$//')); validating '${SUBNET}'"
  fi
  range="$("${G[@]}" compute networks subnets describe "$SUBNET" --region="$REGION" --format='value(ipCidrRange)' 2>/dev/null)"
  pga="$("${G[@]}" compute networks subnets describe "$SUBNET" --region="$REGION" --format='value(privateIpGoogleAccess)' 2>/dev/null)"
  pass "subnet ${SUBNET} exists (${range})"
  if cidr_contains "$ADVERTISE_RANGE" "$range"; then
    pass "subnet ${range} is inside the advertised supernet ${ADVERTISE_RANGE}"
  else
    fail "subnet ${range} is OUTSIDE the advertised supernet ${ADVERTISE_RANGE} - the supernet would carry no real on-prem hosts; re-run gcp-deploy.sh with a contained --subnet-cidr"
  fi
  if [[ "$pga" == "True" || "$pga" == "true" ]]; then
    pass "Private Google Access enabled"
  else
    warn "Private Google Access disabled — the VM cannot reach Google APIs without a public IP or Cloud NAT"
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "== Firewall =="

if "${G[@]}" compute firewall-rules describe "$FW_INTERNAL" >/dev/null 2>&1; then
  pass "firewall ${FW_INTERNAL} exists (RFC1918 ingress)"
else
  fail "firewall ${FW_INTERNAL} not found — Azure traffic over ExpressRoute will be dropped"
fi

if "${G[@]}" compute firewall-rules describe "$FW_IAP" >/dev/null 2>&1; then
  src="$("${G[@]}" compute firewall-rules describe "$FW_IAP" --format='value(sourceRanges.list())' 2>/dev/null)"
  if [[ "$src" == *"35.235.240.0/20"* ]]; then
    pass "firewall ${FW_IAP} allows the IAP range 35.235.240.0/20"
  else
    fail "firewall ${FW_IAP} does not include 35.235.240.0/20 — IAP SSH will fail (source: ${src})"
  fi
else
  fail "firewall ${FW_IAP} not found — the VM has no public IP, so IAP SSH is the only way in"
fi

# ---------------------------------------------------------------------------
echo
echo "== VM =="

if "${G[@]}" compute instances describe "$VM" --zone="$ZONE" >/dev/null 2>&1; then
  status="$("${G[@]}" compute instances describe "$VM" --zone="$ZONE" --format='value(status)' 2>/dev/null)"
  mtype="$("${G[@]}" compute instances describe "$VM" --zone="$ZONE" --format='value(machineType.basename())' 2>/dev/null)"
  privip="$("${G[@]}" compute instances describe "$VM" --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)"
  extip="$("${G[@]}" compute instances describe "$VM" --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)"

  if [[ "$status" == "RUNNING" ]]; then
    pass "VM ${VM} is RUNNING (${mtype}, ${privip})"
  else
    warn "VM ${VM} is ${status} — start it with: gcloud compute instances start ${VM} --zone=${ZONE}"
  fi

  if [[ -z "$extip" ]]; then
    pass "VM has no external IP (cost control + no internet exposure)"
  else
    fail "VM has an external IP (${extip}) — expected none"
  fi
else
  fail "VM ${VM} not found in ${ZONE}"
fi

# ---------------------------------------------------------------------------
echo
echo "== Cloud Router =="

if "${G[@]}" compute routers describe "$ROUTER" --region="$REGION" >/dev/null 2>&1; then
  asn="$("${G[@]}" compute routers describe "$ROUTER" --region="$REGION" --format='value(bgp.asn)' 2>/dev/null)"
  adv_mode="$("${G[@]}" compute routers describe "$ROUTER" --region="$REGION" --format='value(bgp.advertiseMode)' 2>/dev/null)"
  adv_groups="$("${G[@]}" compute routers describe "$ROUTER" --region="$REGION" --format='value(bgp.advertisedGroups.list())' 2>/dev/null)"
  adv_ranges="$("${G[@]}" compute routers describe "$ROUTER" --region="$REGION" --format='value(bgp.advertisedIpRanges[].range)' 2>/dev/null)"

  if [[ "$asn" == "16550" ]]; then
    pass "router ${ROUTER} ASN is 16550 (required for Partner Interconnect)"
  else
    fail "router ${ROUTER} ASN is '${asn}' — Partner Interconnect requires 16550"
  fi

  if [[ "$adv_mode" == "CUSTOM" ]]; then
    pass "advertisement mode is CUSTOM"
  else
    fail "advertisement mode is '${adv_mode}' — expected CUSTOM so ${ADVERTISE_RANGE} is advertised"
  fi

  if [[ "$adv_groups" == *"ALL_SUBNETS"* ]]; then
    pass "ALL_SUBNETS is advertised"
  else
    fail "ALL_SUBNETS missing from advertised groups ('${adv_groups}') — the VPC subnet will not reach Azure"
  fi

  if [[ "$adv_ranges" == *"$ADVERTISE_RANGE"* ]]; then
    pass "supernet ${ADVERTISE_RANGE} is advertised (the failover probe prefix)"
  else
    fail "supernet ${ADVERTISE_RANGE} not advertised (found: ${adv_ranges:-none})"
  fi
else
  fail "Cloud Router ${ROUTER} not found in ${REGION}"
fi

# ---------------------------------------------------------------------------
echo
echo "== Partner Interconnect attachment =="

if "${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" >/dev/null 2>&1; then
  state="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" --format='value(state)' 2>/dev/null)"
  pkey="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" --format='value(pairingKey)' 2>/dev/null)"
  vlan="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" --format='value(vlanTag8021q)' 2>/dev/null)"
  cloudrtr="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" --format='value(cloudRouterIpAddress)' 2>/dev/null)"
  peerip="$("${G[@]}" compute interconnects attachments describe "$ATTACHMENT" --region="$REGION" --format='value(customerRouterIpAddress)' 2>/dev/null)"

  case "$state" in
    ACTIVE)
      pass "attachment ${ATTACHMENT} is ACTIVE (VLAN ${vlan})"
      info "GCP side ${cloudrtr}  <->  MCR side ${peerip}"
      ;;
    PENDING_CUSTOMER)
      warn "attachment is PENDING_CUSTOMER — Megaport has built the VXC, activate it:"
      info "gcloud compute interconnects attachments partner update ${ATTACHMENT} \\"
      info "  --region=${REGION} --project=${GCP_PROJECT} --admin-enabled"
      ;;
    PENDING_PARTNER)
      warn "attachment is PENDING_PARTNER — waiting for Megaport to build the VXC"
      [[ -n "$pkey" ]] && info "pairing key: ${pkey}"
      ;;
    DEFUNCT)
      fail "attachment is DEFUNCT — Megaport deleted its side. Recreate with gcp-deploy.sh"
      ;;
    *)
      warn "attachment state: ${state:-unknown}"
      ;;
  esac
else
  fail "attachment ${ATTACHMENT} not found in ${REGION}"
fi

# ---------------------------------------------------------------------------
echo
echo "== BGP session =="

if "${G[@]}" compute routers describe "$ROUTER" --region="$REGION" >/dev/null 2>&1; then
  bgp_status="$("${G[@]}" compute routers get-status "$ROUTER" --region="$REGION" \
    --format='value(result.bgpPeerStatus[].state)' 2>/dev/null)"
  learned="$("${G[@]}" compute routers get-status "$ROUTER" --region="$REGION" \
    --format='value(result.bgpPeerStatus[].numLearnedRoutes)' 2>/dev/null)"

  if [[ -z "$bgp_status" ]]; then
    warn "no BGP peer yet — the peer is auto-created only after the attachment is ACTIVE"
  elif [[ "$bgp_status" == *"Established"* || "$bgp_status" == *"UP"* ]]; then
    pass "BGP session established (learned routes: ${learned:-0})"
    if [[ -n "$learned" && "$learned" != "0" ]]; then
      pass "routes are being learned from the MCR / Azure side"
    else
      warn "BGP is up but no routes learned — check the MCR's advertisement toward GCP"
    fi
  else
    fail "BGP peer state: ${bgp_status}"
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "== Next steps =="
info "SSH:  gcloud compute ssh ${VM} --zone=${ZONE} --project=${GCP_PROJECT} --tunnel-through-iap"
info "Ping Azure spokes from the VM:  ping 10.10.0.4   # erfo-vm-wus2"
info "                                ping 10.20.0.4   # erfo-vm-scus"
info "Failover procedure: docs/failover-tests.md"

echo
echo "================================================================"
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "  \033[32mAll checks passed.\033[0m"
  echo "================================================================"
  exit 0
else
  echo -e "  \033[31m${FAILURES} check(s) failed.\033[0m"
  echo "================================================================"
  exit 1
fi
