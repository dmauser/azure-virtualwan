#!/usr/bin/env bash
# =============================================================================
# configure-onprem.sh — Configure on-prem NVA (strongSwan + FRR) via
# az vm run-command invoke.  Called by deploy.sh after VPN site/connection
# are created and hub GW public IPs + BGP peer IPs are known.
#
# Usage:
#   configure-onprem.sh <onprem-nva-name> <rg> \
#       <hub-gw-pip0> <hub-gw-pip1> \
#       <hub-bgp-peer0> <hub-bgp-peer1> \
#       <hub-asn> <onprem-asn> <onprem-private-ip> <psk>
#
# The on-prem VM UDR (spoke ranges → on-prem NVA private IP) is authored by
# Naomi in onprem.bicep.  This script only brings up IPsec + BGP.
#
# Prerequisites on the NVA (installed by cloud-init in onprem.bicep):
#   strongswan, frr, iproute2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/functions.sh"

# ---------- Argument validation ----------------------------------------------
if [[ $# -lt 10 ]]; then
  echo "Usage: $0 <nva-name> <rg> <hub-pip0> <hub-pip1> <hub-bgp0> <hub-bgp1> <hub-asn> <onprem-asn> <onprem-private-ip> <psk>"
  exit 1
fi

ONPREM_NVA_NAME="$1"
RG="$2"
HUB_GW_PIP0="$3"
HUB_GW_PIP1="$4"
HUB_BGP_PEER0="$5"
HUB_BGP_PEER1="$6"
HUB_ASN="$7"
ONPREM_ASN="$8"
ONPREM_PRIVATE_IP="$9"
PSK="${10}"

log "=== Configuring on-prem NVA '${ONPREM_NVA_NAME}' ==="
log "  Hub GW IPs    : ${HUB_GW_PIP0}  ${HUB_GW_PIP1}"
log "  Hub BGP peers : ${HUB_BGP_PEER0}  ${HUB_BGP_PEER1}"
log "  Hub ASN       : ${HUB_ASN}"
log "  On-prem ASN   : ${ONPREM_ASN}  private IP: ${ONPREM_PRIVATE_IP}"

# ---------- Step 1: Enable IP forwarding ------------------------------------
log "[onprem] Enabling IP forwarding ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts \
    "sysctl -w net.ipv4.ip_forward=1" \
    "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf" \
  --output none

# ---------- Step 2: Write /etc/ipsec.conf -----------------------------------
# One conn per hub GW instance (active/active gateway = 2 instances).
# IKEv2, PSK auth, route-based (0.0.0.0/0 selectors on both sides so
# the BGP TCP session over the tunnel is not restricted by TS selectors).
# dpdaction=restart keeps the tunnel up if the hub GW flaps.
log "[onprem] Writing /etc/ipsec.conf ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts "
set -e
cat > /etc/ipsec.conf << 'IPSECEOF'
config setup
    charondebug=\"ike 2, knl 2, cfg 2, net 2, esp 2, dmn 2\"
    uniqueids=no

# Tunnel to vHub VPN Gateway — Instance 0
conn hub-instance0
    keyexchange=ikev2
    left=%any
    leftsubnet=0.0.0.0/0
    right=${HUB_GW_PIP0}
    rightid=${HUB_GW_PIP0}
    rightsubnet=0.0.0.0/0
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    auto=start
    authby=secret
    dpdaction=restart
    dpddelay=10s
    dpdtimeout=60s

# Tunnel to vHub VPN Gateway — Instance 1
conn hub-instance1
    keyexchange=ikev2
    left=%any
    leftsubnet=0.0.0.0/0
    right=${HUB_GW_PIP1}
    rightid=${HUB_GW_PIP1}
    rightsubnet=0.0.0.0/0
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    auto=start
    authby=secret
    dpdaction=restart
    dpddelay=10s
    dpdtimeout=60s
IPSECEOF
echo 'ipsec.conf written.'
" \
  --output none

# ---------- Step 3: Write /etc/ipsec.secrets --------------------------------
log "[onprem] Writing /etc/ipsec.secrets ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts "
set -e
cat > /etc/ipsec.secrets << 'SECREOF'
# PSK shared with Azure vHub VPN Gateway (both instances)
%any ${HUB_GW_PIP0} : PSK \"${PSK}\"
%any ${HUB_GW_PIP1} : PSK \"${PSK}\"
SECREOF
chmod 600 /etc/ipsec.secrets
echo 'ipsec.secrets written.'
" \
  --output none

# ---------- Step 4: Write /etc/frr/frr.conf ---------------------------------
# BGP session to BOTH hub GW BGP peers (active/active GW exposes 2 BGP IPs).
# ebgp-multihop 5: required because the BGP peer is not directly connected
# (traffic traverses the IPsec tunnel → GW internal loopback).
# Advertise: 192.168.100.0/24 (on-prem prefix).
log "[onprem] Writing /etc/frr/frr.conf ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts "
set -e
mkdir -p /etc/frr

cat > /etc/frr/frr.conf << 'FRREOF'
frr version 8.5
frr defaults traditional
hostname onprem-nva
log syslog informational
!
router bgp ${ONPREM_ASN}
 bgp router-id ${ONPREM_PRIVATE_IP}
 !
 neighbor ${HUB_BGP_PEER0} remote-as ${HUB_ASN}
 neighbor ${HUB_BGP_PEER0} description hub-gw-instance0
 neighbor ${HUB_BGP_PEER0} ebgp-multihop 5
 neighbor ${HUB_BGP_PEER0} update-source ${ONPREM_PRIVATE_IP}
 !
 neighbor ${HUB_BGP_PEER1} remote-as ${HUB_ASN}
 neighbor ${HUB_BGP_PEER1} description hub-gw-instance1
 neighbor ${HUB_BGP_PEER1} ebgp-multihop 5
 neighbor ${HUB_BGP_PEER1} update-source ${ONPREM_PRIVATE_IP}
 !
 address-family ipv4 unicast
  network 192.168.100.0/24
  neighbor ${HUB_BGP_PEER0} activate
  neighbor ${HUB_BGP_PEER0} soft-reconfiguration inbound
  neighbor ${HUB_BGP_PEER1} activate
  neighbor ${HUB_BGP_PEER1} soft-reconfiguration inbound
 exit-address-family
!
FRREOF

# Enable bgpd daemon in /etc/frr/daemons (FRR multi-daemon config)
if [ -f /etc/frr/daemons ]; then
    sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
    sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons
fi

# Ensure FRR can read the config
chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
chmod 640 /etc/frr/frr.conf 2>/dev/null || true

echo 'frr.conf written.'
" \
  --output none

# ---------- Step 5: Restart strongSwan and FRR ------------------------------
log "[onprem] Restarting strongSwan and FRR ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts \
    "systemctl enable strongswan-starter 2>/dev/null || systemctl enable strongswan 2>/dev/null || true" \
    "systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true" \
    "systemctl enable frr" \
    "systemctl restart frr" \
    "echo 'Services restarted.'" \
  --output none

# ---------- Step 6: Tunnel status check (best-effort) -----------------------
log "[onprem] Checking IPsec tunnel status (best-effort, may lag 15-30s) ..."
az vm run-command invoke \
  -g "$RG" --name "$ONPREM_NVA_NAME" \
  --command-id RunShellScript \
  --scripts \
    "sleep 10" \
    "ipsec status 2>/dev/null || swanctl --list-sas 2>/dev/null || echo 'strongSwan status unavailable'" \
    "echo '---BGP---'" \
    "vtysh -c 'show bgp summary' 2>/dev/null || echo 'FRR BGP summary unavailable (daemon may still be starting)'" \
  --output json | jq -r '.value[].message // empty' 2>/dev/null || true

log "=== On-prem NVA configuration complete ==="
log "  Allow 30-60s for IPsec tunnels to establish and BGP sessions to come up."
log "  Verify: ipsec status | grep ESTABLISHED"
log "  Verify: vtysh -c 'show bgp summary' | grep -E 'Neighbor|${HUB_BGP_PEER0}|${HUB_BGP_PEER1}'"
