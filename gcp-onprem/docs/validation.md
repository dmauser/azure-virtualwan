# Validation — gcp-onprem Lab

This document describes the manual `gcloud` commands used by the validation scripts, plus additional BGP session checks.

---

## Automated validation

Run the validation scripts to check all resources:

```bash
# Bash
cd gcp-onprem/scripts
./validate.sh -p YOUR_PROJECT

# PowerShell
cd gcp-onprem\scripts
.\validate.ps1 -Project YOUR_PROJECT
```

The scripts check each environment for:
- VPC network exists
- Subnet exists in the correct region
- VM instance is `RUNNING`
- Cloud Router exists
- Interconnect attachment exists and has a pairing key (state `PENDING_PARTNER` is acceptable)
- Firewall rule exists

---

## Manual gcloud checks

### env1 (us-west2)

```bash
PROJECT=YOUR_PROJECT

# VPC network
gcloud compute networks describe onprem-la --project=$PROJECT --format="value(name,routingConfig.routingMode)"

# Subnet
gcloud compute networks subnets describe onprem-la-subnet \
  --project=$PROJECT --region=us-west2 \
  --format="value(name,ipCidrRange)"

# VM status
gcloud compute instances describe onprem-la-vm \
  --project=$PROJECT --zone=us-west2-a \
  --format="value(name,status,networkInterfaces[0].networkIP)"

# Cloud Router
gcloud compute routers describe onprem-la-router \
  --project=$PROJECT --region=us-west2 \
  --format="value(name,bgp.asn)"

# Interconnect attachment + pairing key
gcloud compute interconnects attachments describe onprem-la-partner-attachment \
  --project=$PROJECT --region=us-west2 \
  --format="value(name,state,pairingKey)"

# Firewall rule
gcloud compute firewall-rules describe onprem-la-allow \
  --project=$PROJECT --format="value(name,network,sourceRanges)"
```

### env2 (us-west4)

```bash
# VPC network
gcloud compute networks describe onprem-lv --project=$PROJECT --format="value(name,routingConfig.routingMode)"

# Subnet
gcloud compute networks subnets describe onprem-lv-subnet \
  --project=$PROJECT --region=us-west4 \
  --format="value(name,ipCidrRange)"

# VM status
gcloud compute instances describe onprem-lv-vm \
  --project=$PROJECT --zone=us-west4-a \
  --format="value(name,status,networkInterfaces[0].networkIP)"

# Cloud Router
gcloud compute routers describe onprem-lv-router \
  --project=$PROJECT --region=us-west4 \
  --format="value(name,bgp.asn)"

# Interconnect attachment + pairing key
gcloud compute interconnects attachments describe onprem-lv-partner-attachment \
  --project=$PROJECT --region=us-west4 \
  --format="value(name,state,pairingKey)"

# Firewall rule
gcloud compute firewall-rules describe onprem-lv-allow \
  --project=$PROJECT --format="value(name,network,sourceRanges)"
```

---

## BGP session checks (after Megaport activation)

These commands verify that BGP sessions are established on the Cloud Routers.  
Run after completing the Megaport VXC setup described in [`megaport-cross-connect.md`](megaport-cross-connect.md).

```bash
# env1 BGP peer status
gcloud compute routers get-status onprem-la-router \
  --project=$PROJECT \
  --region=us-west2 \
  --format="json(result.bgpPeerStatus)"

# env2 BGP peer status
gcloud compute routers get-status onprem-lv-router \
  --project=$PROJECT \
  --region=us-west4 \
  --format="json(result.bgpPeerStatus)"
```

**Expected output fields:**

| Field            | Expected value                    |
|------------------|----------------------------------|
| `status`         | `UP`                              |
| `peerIpAddress`  | IP assigned by Google (169.254.x.x / RFC-5549) |
| `linkedVpnTunnel` | empty (this is Interconnect, not VPN) |
| `bgpPeerAsn`     | `16550` (Google fixed peer ASN)   |

---

## Interconnect attachment states

| State             | Meaning                                                   |
|-------------------|------------------------------------------------------------|
| `PENDING_PARTNER` | Attachment created; waiting for Megaport to provision VXC |
| `PENDING_CUSTOMER`| Megaport activated; waiting for customer config           |
| `ACTIVE`          | BGP session up, traffic flowing                            |
| `DEFUNCT`         | Error state; contact Megaport or GCP support               |

---

## Route advertisement checks (Azure side)

```bash
# Verify Azure ER circuit sees GCP routes
az network express-route list-route-tables \
  --resource-group YOUR_RG \
  --name vwanlab-er1 \
  --peering-name AzurePrivatePeering \
  --path Primary \
  --output table

# Expected: 192.168.100.0/24 with AS path containing 65100 16550
```

---

## VM connectivity test (after full end-to-end activation)

```bash
# SSH into env1 VM via IAP
gcloud compute ssh onprem-la-vm \
  --tunnel-through-iap \
  --project=$PROJECT \
  --zone=us-west2-a

# Test reachability to Azure spoke VM (replace IP with your Azure spoke VM IP)
ping -c 4 10.x.x.x
traceroute 10.x.x.x
curl -s http://10.x.x.x   # if an HTTP server is running
```
