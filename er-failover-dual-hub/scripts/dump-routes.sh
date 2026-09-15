#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dump-routes.sh - dump the routing table from every point in the
#                  ExpressRoute failover lab.
#
# Read-only. Collects, for review in one place:
#
#   1. ExpressRoute  - private peering config, BGP neighbour summary, learned
#                      routes (primary + secondary) and ARP tables.
#   2. Virtual hubs  - effective routes on each hub's defaultRouteTable, plus
#                      per ER connection and per spoke VNet connection.
#   3. Azure VMs     - in-guest kernel route table via `az vm run-command`
#                      because the VMs deliberately have no public IP.
#   4. GCP           - Cloud Router BGP status, advertised/learned routes,
#                      VPC routes, attachment state, on-prem VM routes (IAP).
#
# Output goes to a timestamped folder as individual .json/.txt files plus a
# combined report.txt, so two runs can be diffed across a failover event.
#
# Usage:
#   ./dump-routes.sh -g rg-er-failover-dual-hub [-l before-failover]
#   ./dump-routes.sh -g <rg> --skip-vms --skip-gcp
# ---------------------------------------------------------------------------
set -uo pipefail

RESOURCE_GROUP=""
PREFIX="erfo"
OUTPUT_DIR=""
LABEL=""
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_REGION="us-south1"
GCP_NAME_PREFIX="erfo-onprem"
SKIP_VMS=0
SKIP_GCP=0

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -p|--prefix)         PREFIX="$2";         shift 2 ;;
    -o|--output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    -l|--label)          LABEL="$2";          shift 2 ;;
    --gcp-project)       GCP_PROJECT="$2";    shift 2 ;;
    --gcp-region)        GCP_REGION="$2";     shift 2 ;;
    --gcp-prefix)        GCP_NAME_PREFIX="$2";shift 2 ;;
    --skip-vms)          SKIP_VMS=1;          shift   ;;
    --skip-gcp)          SKIP_GCP=1;          shift   ;;
    -h|--help)           usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$RESOURCE_GROUP" ]] || { echo "error: -g/--resource-group is required" >&2; usage 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Azure CLI preflight
#
# Some machines carry a corrupt Azure CLI extension cache where a *.dist-info
# entry is a directory rather than a wheel file. Every `az` invocation then dies
# with a PermissionError while loading the command table, which looks exactly
# like "resource not found" to this script. Extensions are not needed here, so
# fall back to an empty extension directory.
# ---------------------------------------------------------------------------
if ! az account show -o none >/dev/null 2>&1; then
  FALLBACK_EXT="${TMPDIR:-/tmp}/azext-empty"
  mkdir -p "$FALLBACK_EXT"
  export AZURE_EXTENSION_DIR="$FALLBACK_EXT"
  if ! az account show -o none >/dev/null 2>&1; then
    printf '\033[31mAzure CLI is not usable - run '\''az login'\'' and retry.\033[0m\n' >&2
    exit 1
  fi
  printf '\033[33mnote: azure cli extension cache was unreadable; using %s\033[0m\n' "$FALLBACK_EXT"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  STAMP="$(date -u +%Y%m%d-%H%M%S)"
  LEAF="$STAMP"
  [[ -n "$LABEL" ]] && LEAF="$STAMP-$LABEL"
  OUTPUT_DIR="$SCRIPT_DIR/../route-dumps/$LEAF"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
REPORT="$OUTPUT_DIR/report.txt"

C_CYAN=$'\033[36m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
C_GRN=$'\033[32m';  C_GRY=$'\033[90m'; C_OFF=$'\033[0m'

head_() {
  local line; line="$(printf '=%.0s' {1..74})"
  printf '\n%s%s\n  %s\n%s%s\n' "$C_CYAN" "$line" "$1" "$line" "$C_OFF"
  printf '\n%s\n  %s\n%s\n' "$line" "$1" "$line" >> "$REPORT"
}
sub_()  { printf '\n%s-- %s%s\n' "$C_YEL" "$1" "$C_OFF"; printf '\n-- %s\n' "$1" >> "$REPORT"; }
note_() { printf '%s   %s%s\n' "$C_GRY" "$1" "$C_OFF"; printf '   %s\n' "$1" >> "$REPORT"; }
warn_() { printf '%s   [warn] %s%s\n' "$C_RED" "$1" "$C_OFF"; printf '   [warn] %s\n' "$1" >> "$REPORT"; }

# Echo a block of text to console and report.
emit_() {
  local text="$1"
  if [[ -z "${text//[[:space:]]/}" ]]; then note_ '(none)'; return; fi
  printf '%s\n' "$text"
  printf '%s\n' "$text" >> "$REPORT"
}

# az wrapper: prints JSON on success, nothing on failure.
azj() { az "$@" -o json 2>/dev/null || true; }

{
  echo "ExpressRoute failover lab - route dump"
  echo "generated : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "rg        : $RESOURCE_GROUP"
  echo "prefix    : $PREFIX"
} > "$REPORT"

printf '%sWriting dump to %s%s\n' "$C_GRN" "$OUTPUT_DIR" "$C_OFF"

CIRCUITS=("$PREFIX-er-chicago" "$PREFIX-er-dallas")
HUB_KEYS=("wus2" "scus")
circuit_for() { case "$1" in wus2) echo chicago ;; scus) echo dallas ;; esac; }

# ===========================================================================
# 1. ExpressRoute
# ===========================================================================
head_ 'EXPRESSROUTE CIRCUITS'

for CKT in "${CIRCUITS[@]}"; do
  sub_ "$CKT - circuit state"
  CJ="$(azj network express-route show -g "$RESOURCE_GROUP" -n "$CKT")"
  if [[ -z "$CJ" ]]; then warn_ "circuit $CKT not found"; continue; fi
  printf '%s' "$CJ" > "$OUTPUT_DIR/er-$CKT-circuit.json"
  emit_ "$(printf '%s' "$CJ" | jq -r '
    "name          : \(.name)",
    "location      : \(.location)",
    "provisioning  : \(.provisioningState)",
    "provider      : \(.serviceProviderProperties.serviceProviderName)",
    "peeringLoc    : \(.serviceProviderProperties.peeringLocation)",
    "bandwidthMbps : \(.serviceProviderProperties.bandwidthInMbps)",
    "providerState : \(.serviceProviderProvisioningState)",
    "sku           : \(.sku.name)"')"

  sub_ "$CKT - private peering configuration"
  PJ="$(azj network express-route peering show -g "$RESOURCE_GROUP" --circuit-name "$CKT" -n AzurePrivatePeering)"
  if [[ -z "$PJ" ]]; then
    warn_ 'AzurePrivatePeering not present - the provider has not built it yet'
    continue
  fi
  printf '%s' "$PJ" > "$OUTPUT_DIR/er-$CKT-peering.json"
  emit_ "$(printf '%s' "$PJ" | jq -r '
    "peerASN   : \(.peerASN)",
    "vlanId    : \(.vlanId)",
    "primary   : \(.primaryPeerAddressPrefix)",
    "secondary : \(.secondaryPeerAddressPrefix)",
    "azureASN  : \(.azureASN)",
    "state     : \(.provisioningState)"')"

  for PATH_ in primary secondary; do
    sub_ "$CKT - BGP neighbours ($PATH_)"
    SJ="$(azj network express-route list-route-tables-summary -g "$RESOURCE_GROUP" -n "$CKT" \
          --peering-name AzurePrivatePeering --path "$PATH_")"
    printf '%s' "$SJ" > "$OUTPUT_DIR/er-$CKT-bgp-$PATH_.json"
    emit_ "$(printf '%s' "$SJ" | jq -r '
      ["NEIGHBOR","AS","UPDOWN","PFXRCD"],
      (.value[]? | [.neighbor, (.as|tostring), .upDown, .statePfxRcd])
      | @tsv' 2>/dev/null | column -t)"

    sub_ "$CKT - learned routes ($PATH_)"
    RJ="$(azj network express-route list-route-tables -g "$RESOURCE_GROUP" -n "$CKT" \
          --peering-name AzurePrivatePeering --path "$PATH_")"
    printf '%s' "$RJ" > "$OUTPUT_DIR/er-$CKT-routes-$PATH_.json"
    emit_ "$(printf '%s' "$RJ" | jq -r '
      ["NETWORK","NEXTHOP","PATH"],
      (.value[]? | [.network, .nextHop, (.path // "")])
      | @tsv' 2>/dev/null | column -t)"

    sub_ "$CKT - ARP ($PATH_)"
    AJ="$(azj network express-route list-arp-tables -g "$RESOURCE_GROUP" -n "$CKT" \
          --peering-name AzurePrivatePeering --path "$PATH_")"
    printf '%s' "$AJ" > "$OUTPUT_DIR/er-$CKT-arp-$PATH_.json"
    emit_ "$(printf '%s' "$AJ" | jq -r '
      ["IP","MAC","INTERFACE","AGE"],
      (.value[]? | [.ipAddress, .macAddress, (.interface // ""), (.age|tostring)])
      | @tsv' 2>/dev/null | column -t)"
  done
done

# ===========================================================================
# 2. Virtual hubs
# ===========================================================================
head_ 'VIRTUAL HUB EFFECTIVE ROUTES'

# jq filter reused for every get-effective-routes response
EFF_FILTER='["PREFIX","NEXTHOPTYPE","NEXTHOP","ASPATH","ORIGIN"],
  (.value[]? | [(.addressPrefixes|join(",")), .nextHopType,
                (.nextHops|join(",")), (.asPath // ""), (.routeOrigin // "")])
  | @tsv'

for KEY in "${HUB_KEYS[@]}"; do
  HUB="$PREFIX-hub-$KEY"
  HJ="$(azj network vhub show -g "$RESOURCE_GROUP" -n "$HUB")"
  if [[ -z "$HJ" ]]; then warn_ "hub $HUB not found"; continue; fi

  sub_ "$HUB - hub properties"
  printf '%s' "$HJ" > "$OUTPUT_DIR/hub-$KEY-properties.json"
  emit_ "$(printf '%s' "$HJ" | jq -r '
    "name         : \(.name)",
    "location     : \(.location)",
    "addressSpace : \(.addressPrefix)",
    "routingPref  : \(.hubRoutingPreference)",
    "state        : \(.provisioningState)",
    "routerAsn    : \(.virtualRouterAsn)",
    "routerIps    : \(.virtualRouterIps | join(", "))"')"

  HUB_ID="$(printf '%s' "$HJ" | jq -r '.id')"

  sub_ "$HUB - defaultRouteTable effective routes"
  EJ="$(azj network vhub get-effective-routes -g "$RESOURCE_GROUP" -n "$HUB" \
        --resource-type RouteTable --resource-id "$HUB_ID/hubRouteTables/defaultRouteTable")"
  printf '%s' "$EJ" > "$OUTPUT_DIR/hub-$KEY-routetable.json"
  emit_ "$(printf '%s' "$EJ" | jq -r "$EFF_FILTER" 2>/dev/null | column -t)"

  GW="$PREFIX-hub-$KEY-ergw"
  ERCONN="$PREFIX-erconn-$(circuit_for "$KEY")"
  ECJ="$(azj network express-route gateway connection show --gateway-name "$GW" \
         -g "$RESOURCE_GROUP" -n "$ERCONN")"
  if [[ -n "$ECJ" ]]; then
    sub_ "$HUB - effective routes on ER connection $ERCONN"
    EC_ID="$(printf '%s' "$ECJ" | jq -r '.id')"
    E2="$(azj network vhub get-effective-routes -g "$RESOURCE_GROUP" -n "$HUB" \
          --resource-type ExpressRouteConnection --resource-id "$EC_ID")"
    printf '%s' "$E2" > "$OUTPUT_DIR/hub-$KEY-erconn-routes.json"
    emit_ "$(printf '%s' "$E2" | jq -r "$EFF_FILTER" 2>/dev/null | column -t)"
  else
    warn_ "ER connection $ERCONN not found"
  fi

  VCONN="$PREFIX-spoke-$KEY-conn"
  VCJ="$(azj network vhub connection show --vhub-name "$HUB" -g "$RESOURCE_GROUP" -n "$VCONN")"
  if [[ -n "$VCJ" ]]; then
    sub_ "$HUB - effective routes on VNet connection $VCONN"
    VC_ID="$(printf '%s' "$VCJ" | jq -r '.id')"
    E3="$(azj network vhub get-effective-routes -g "$RESOURCE_GROUP" -n "$HUB" \
          --resource-type HubVirtualNetworkConnection --resource-id "$VC_ID")"
    printf '%s' "$E3" > "$OUTPUT_DIR/hub-$KEY-vnetconn-routes.json"
    emit_ "$(printf '%s' "$E3" | jq -r "$EFF_FILTER" 2>/dev/null | column -t)"
  else
    warn_ "VNet connection $VCONN not found"
  fi
done

# ===========================================================================
# 3. Azure VMs
# ===========================================================================
head_ 'AZURE VM ROUTES'

# Probe script handed to `az vm run-command` as a file (see the --scripts call
# below for why an inline string does not survive the CLI's argument parsing).
GUEST_PROBE="$(mktemp "${TMPDIR:-/tmp}/erfo-guest-probe.XXXXXX.sh")"
trap 'rm -f "$GUEST_PROBE"' EXIT
cat > "$GUEST_PROBE" <<'PROBE'
echo "### ip -4 route show"
ip -4 route show
echo
echo "### default route"
ip -4 route get 8.8.8.8 2>/dev/null
echo
echo "### addresses"
ip -4 -br addr
echo
echo "### neighbours"
ip -4 neigh
PROBE

for KEY in "${HUB_KEYS[@]}"; do
  VM="$PREFIX-vm-$KEY"
  NIC="nic-$VM"

  sub_ "$VM - NIC effective routes (platform view)"
  NJ="$(azj network nic show-effective-route-table -g "$RESOURCE_GROUP" -n "$NIC")"
  if [[ -n "$NJ" ]]; then
    printf '%s' "$NJ" > "$OUTPUT_DIR/vm-$KEY-nic-routes.json"
    emit_ "$(printf '%s' "$NJ" | jq -r '
      ["SOURCE","STATE","PREFIX","NEXTHOPTYPE","NEXTHOP"],
      (.value[]? | [.source, .state, (.addressPrefix|join(",")), .nextHopType,
                    ((.nextHopIpAddress // []) | join(","))])
      | @tsv' 2>/dev/null | column -t)"
  else
    warn_ "could not read effective routes for $NIC (VM may be deallocated)"
  fi

  [[ $SKIP_VMS -eq 1 ]] && continue

  sub_ "$VM - in-guest kernel route table"
  POWER="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" \
    -o tsv 2>/dev/null || true)"
  if [[ "$POWER" != "VM running" ]]; then
    warn_ "$VM is '${POWER:-unknown}' - start it to capture in-guest routes"
    continue
  fi

  note_ 'running az vm run-command (this takes 30-60s)...'
  # --scripts is a space-separated list argument, so an inline one-liner gets
  # shredded into one token per line. Hand the CLI a file with @<path> instead.
  OUT="$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM" \
        --command-id RunShellScript --scripts "@$GUEST_PROBE" -o json 2>/dev/null || true)"
  if [[ -n "$OUT" ]]; then
    MSG="$(printf '%s' "$OUT" | jq -r '.value[0].message // ""')"
    printf '%s\n' "$MSG" > "$OUTPUT_DIR/vm-$KEY-guest-routes.txt"
    emit_ "$MSG"
  else
    warn_ "run-command failed on $VM"
  fi
done

# ===========================================================================
# 4. GCP
# ===========================================================================
if [[ $SKIP_GCP -eq 1 ]]; then
  head_ 'GCP (skipped)'
else
  head_ 'GCP ON-PREMISES'

  if [[ -z "$GCP_PROJECT" ]]; then
    GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if [[ -z "$GCP_PROJECT" || "$GCP_PROJECT" == "(unset)" ]]; then
    warn_ 'no GCP project resolved - pass --gcp-project or set $GCP_PROJECT'
  else
    note_ "project $GCP_PROJECT / region $GCP_REGION"
    ROUTER="$GCP_NAME_PREFIX-router"
    ATTACH="$GCP_NAME_PREFIX-attach"
    VPC="$GCP_NAME_PREFIX"
    GVM="$GCP_NAME_PREFIX-vm"

    sub_ "$ATTACH - Partner Interconnect attachment"
    AJ="$(gcloud compute interconnects attachments describe "$ATTACH" \
          --region="$GCP_REGION" --project="$GCP_PROJECT" --format=json 2>/dev/null || true)"
    if [[ -n "$AJ" ]]; then
      printf '%s' "$AJ" > "$OUTPUT_DIR/gcp-attachment.json"
      emit_ "$(printf '%s' "$AJ" | jq -r '
        "state         : \(.state)",
        "adminEnabled  : \(.adminEnabled)",
        "vlan          : \(.vlanTag8021q)",
        "cloudRouterIp : \(.cloudRouterIpAddress)",
        "peerIp        : \(.customerRouterIpAddress)",
        "partner       : \(.partnerMetadata.partnerName // "")",
        "interconnect  : \(.partnerMetadata.interconnectName // "")"')"
    else
      warn_ "attachment $ATTACH not found"
    fi

    sub_ "$ROUTER - BGP session status"
    RJ="$(gcloud compute routers get-status "$ROUTER" \
          --region="$GCP_REGION" --project="$GCP_PROJECT" --format=json 2>/dev/null || true)"
    if [[ -n "$RJ" ]]; then
      printf '%s' "$RJ" | jq '.result' > "$OUTPUT_DIR/gcp-router-status.json"
      emit_ "$(printf '%s' "$RJ" | jq -r '
        ["NAME","STATE","STATUS","LOCALIP","PEERIP","LEARNED","UPTIME"],
        (.result.bgpPeerStatus[]? | [.name, .state, .status, .ipAddress,
                                     .peerIpAddress, (.numLearnedRoutes|tostring), .uptime])
        | @tsv' 2>/dev/null | column -t)"

      sub_ "$ROUTER - routes advertised TO the MCR"
      emit_ "$(printf '%s' "$RJ" | jq -r '
        ["PREFIX","NEXTHOP","PRIORITY"],
        (.result.bgpPeerStatus[]?.advertisedRoutes[]?
         | [.destRange, .nextHopIp, (.priority|tostring)])
        | @tsv' 2>/dev/null | column -t)"
      printf '%s' "$RJ" | jq '[.result.bgpPeerStatus[]?.advertisedRoutes[]?]' \
        > "$OUTPUT_DIR/gcp-advertised.json"

      sub_ "$ROUTER - routes learned FROM the MCR"
      emit_ "$(printf '%s' "$RJ" | jq -r '
        ["PREFIX","NEXTHOP","ASPATH","STATUS"],
        (.result.bestRoutesForRouter[]?
         | [.destRange, (.nextHopIp // ""),
            ([.asPaths[]?.asLists[]?] | map(tostring) | join(" ")),
            (.routeStatus // "")])
        | @tsv' 2>/dev/null | column -t)"
      printf '%s' "$RJ" | jq '[.result.bestRoutesForRouter[]?]' \
        > "$OUTPUT_DIR/gcp-learned.json"
    else
      warn_ "router $ROUTER status unavailable"
    fi

    sub_ "$VPC - VPC route table"
    VJ="$(gcloud compute routes list --project="$GCP_PROJECT" \
          --filter="network:$VPC" --format=json 2>/dev/null || true)"
    if [[ -n "$VJ" ]]; then
      printf '%s' "$VJ" > "$OUTPUT_DIR/gcp-vpc-routes.json"
      emit_ "$(printf '%s' "$VJ" | jq -r '
        ["NAME","PREFIX","PRIORITY","NEXTHOP"],
        (.[]? | [.name, .destRange, (.priority|tostring),
                 ((.nextHopIp // .nextHopGateway // .nextHopIlb // "") | split("/") | last)])
        | @tsv' 2>/dev/null | column -t)"
    else
      warn_ 'could not list VPC routes'
    fi

    sub_ "$GVM - in-guest kernel route table (via IAP)"
    if [[ $SKIP_VMS -eq 1 ]]; then
      note_ 'skipped (--skip-vms)'
    else
      note_ 'running gcloud compute ssh --tunnel-through-iap ...'
      GUEST="$(gcloud compute ssh "$GVM" --zone="$GCP_REGION-a" --project="$GCP_PROJECT" \
               --tunnel-through-iap --quiet \
               --command="echo '### ip -4 route show'; ip -4 route show; echo; echo '### addresses'; ip -4 -br addr" 2>&1 || true)"
      if printf '%s' "$GUEST" | grep -q 'ip -4 route show'; then
        printf '%s\n' "$GUEST" > "$OUTPUT_DIR/gcp-vm-guest-routes.txt"
        emit_ "$GUEST"
      else
        warn_ 'IAP SSH failed - needs an allow rule for 35.235.240.0/20 on tcp:22 and roles/iap.tunnelResourceAccessor'
        printf '%s\n' "$GUEST" >> "$REPORT"
      fi
    fi
  fi
fi

head_ 'DONE'
printf '%sDump written to: %s%s\n' "$C_GRN" "$OUTPUT_DIR" "$C_OFF"
printf '%sCombined report: %s%s\n' "$C_GRN" "$REPORT" "$C_OFF"
cat <<EOF

${C_GRY}To compare a steady-state run against a failover run:
  ./dump-routes.sh -g <rg> -l before
  # ...break the Dallas circuit...
  ./dump-routes.sh -g <rg> -l after
  diff -u route-dumps/<before>/report.txt route-dumps/<after>/report.txt${C_OFF}
EOF
