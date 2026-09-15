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

Resource names follow the `onprem-<N>` convention (`onprem-1`, `onprem-2`, …). The block below is **per-environment** — set the variables for the environment you want to check (the values come from your `terraform.tfvars` / `terraform output environment_details`):

```bash
PROJECT=YOUR_PROJECT

# --- Per-environment variables (example: env1) ---
NET=onprem-1            # network_name
REGION=us-central1      # region
ZONE=us-central1-a      # zone

# VPC network
gcloud compute networks describe "$NET" --project=$PROJECT --format="value(name,routingConfig.routingMode)"

# Subnet
gcloud compute networks subnets describe "${NET}-subnet" \
  --project=$PROJECT --region=$REGION \
  --format="value(name,ipCidrRange)"

# VM status
gcloud compute instances describe "${NET}-vm" \
  --project=$PROJECT --zone=$ZONE \
  --format="value(name,status,networkInterfaces[0].networkIP)"

# Cloud Router
gcloud compute routers describe "${NET}-router" \
  --project=$PROJECT --region=$REGION \
  --format="value(name,bgp.asn)"

# Interconnect attachment + pairing key
gcloud compute interconnects attachments describe "${NET}-partner-attachment" \
  --project=$PROJECT --region=$REGION \
  --format="value(name,state,pairingKey)"

# Firewall rule
gcloud compute firewall-rules describe "${NET}-allow" \
  --project=$PROJECT --format="value(name,network,sourceRanges)"
```

> **Tip**: List every deployed environment and its names/region/zone with:
> ```bash
> cd gcp-onprem/terraform
> terraform output -json environment_details | jq
> ```
> Then repeat the block above for each environment (`onprem-2`, `onprem-3`, …).

---

## BGP session checks (after Megaport activation)

These commands verify that BGP sessions are established on the Cloud Routers.  
Run after completing the Megaport VXC setup described in [`megaport-cross-connect.md`](megaport-cross-connect.md).

```bash
# BGP peer status for an environment (repeat per env, e.g. onprem-2 in its region)
gcloud compute routers get-status onprem-1-router \
  --project=$PROJECT \
  --region=us-central1 \
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

# Expected: the env's CIDR (e.g. 192.168.1.0/24) with AS path containing 16550
```

---

## VM connectivity test (after full end-to-end activation)

```bash
# SSH into an environment VM via IAP (VM name = onprem-<N>-vm)
gcloud compute ssh onprem-1-vm \
  --tunnel-through-iap \
  --project=$PROJECT \
  --zone=us-central1-a

# Test reachability to Azure spoke VM (replace IP with your Azure spoke VM IP)
ping -c 4 10.x.x.x
traceroute 10.x.x.x
curl -s http://10.x.x.x   # if an HTTP server is running
```
