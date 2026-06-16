# Megaport Cross-Connect — Step-by-Step

This document describes the **manual** steps to connect each GCP Partner Interconnect attachment to an Azure ExpressRoute circuit via Megaport.

> Megaport connectivity is **not automated** by Terraform. Follow these steps after `terraform apply` completes.

---

## Prerequisites

- Megaport account with billing set up
- Azure ExpressRoute circuits provisioned (from the `svh-dynamic-er-ri` lab):
  - `vwanlab-er1` — Los Angeles peering location
  - `vwanlab-er2` — Phoenix peering location
- GCP Partner Interconnect attachments deployed (from this lab)

---

## Step 1 — Get the pairing keys

After `terraform apply`, retrieve the pairing keys:

```bash
cd gcp-onprem/terraform
terraform output -json pairing_keys
```

Example output (values are fictional):
```json
{
  "env1": "a1b2c3d4-e5f6-7890-abcd-ef1234567890/us-west2/1",
  "env2": "b2c3d4e5-f6a7-8901-bcde-f12345678901/us-west4/1"
}
```

Keep these keys available — you will paste them into the Megaport portal.

> **Note**: The pairing key is marked `sensitive` in Terraform; use `terraform output -json pairing_keys` to reveal it. Do not commit `terraform.tfstate` to source control.

---

## Step 2 — Create Megaport VXC for env1 (Los Angeles → vwanlab-er1)

1. Log in to the [Megaport portal](https://portal.megaport.com/).
2. Navigate to your **Megaport** (physical port) in the **Los Angeles** region.
3. Click **+ Add VXC**.
4. **B-End configuration**:
   - Select **Google Cloud Interconnect** as the service type.
   - Paste the **env1 pairing key** from Step 1.
   - Megaport will resolve the attachment location and region (should show `us-west2`).
5. **A-End / B-End speed**: choose bandwidth appropriate for your test (minimum 50 Mbps).
6. Click **Order** and confirm.
7. Wait for the VXC to show **Active** (typically 5–30 minutes).

### Pair to Azure ER circuit vwanlab-er1

8. In the **Azure portal**, navigate to your ExpressRoute circuit `vwanlab-er1`.
9. Confirm the circuit is in **Enabled** state and provider status is **Provisioned**.
10. The circuit should already be connected to the Virtual WAN hub in the `svh-dynamic-er-ri` lab.
11. BGP sessions will form automatically once Megaport activates the VXC.

---

## Step 3 — Create Megaport VXC for env2 (Phoenix → vwanlab-er2)

Repeat the same process for env2:

1. Navigate to your **Megaport** in the **Phoenix** (or nearest) region.
2. Click **+ Add VXC**.
3. **B-End configuration**:
   - Select **Google Cloud Interconnect**.
   - Paste the **env2 pairing key** from Step 1.
   - Verify region resolves to `us-west4`.
4. Set speed and click **Order**.
5. Wait for **Active** status.

### Pair to Azure ER circuit vwanlab-er2

6. In the Azure portal, verify `vwanlab-er2` is **Enabled** and **Provisioned**.
7. The circuit should be connected to the Virtual WAN hub from the sibling lab.

---

## Step 4 — Verify BGP sessions

### GCP side

Check Cloud Router BGP sessions:

```bash
# env1
gcloud compute routers get-status onprem-la-router \
  --project=YOUR_PROJECT \
  --region=us-west2 \
  --format="json(result.bgpPeerStatus)"

# env2
gcloud compute routers get-status onprem-lv-router \
  --project=YOUR_PROJECT \
  --region=us-west4 \
  --format="json(result.bgpPeerStatus)"
```

Look for `"status": "UP"` on each BGP peer.  
Google peer ASN will be **16550** (fixed for all Partner Interconnect).

### Azure side

In the Azure portal (or via CLI):

```bash
az network express-route list-route-tables \
  --resource-group YOUR_RG \
  --name vwanlab-er1 \
  --peering-name AzurePrivatePeering \
  --path Primary
```

You should see `192.168.100.0/24` (env1) routes advertised via an AS path containing `16550`.

---

## Step 5 — Test connectivity

SSH into each GCP VM via IAP and test connectivity to Azure VMs:

```bash
gcloud compute ssh onprem-la-vm \
  --tunnel-through-iap \
  --project=YOUR_PROJECT \
  --zone=us-west2-a

# Inside the VM:
ping 10.x.x.x        # Azure spoke VM IP
traceroute 10.x.x.x
```

---

## BGP / ASN Reference

| Side            | ASN   | Notes                                      |
|-----------------|-------|-------------------------------------------|
| GCP env1 router | 16550 | Cloud Router local ASN — fixed at 16550 for Partner Interconnect |
| GCP env2 router | 16550 | Cloud Router local ASN — fixed at 16550 for Partner Interconnect |
| Google (GCP)    | 16550 | Fixed for all Partner Interconnect, GCP side |
| Azure VWAN hub  | varies| Allocated by Azure for the ER connection   |

---

## Teardown

To deactivate the cross-connects:

1. **Megaport portal**: delete both VXCs first (they are not managed by Terraform).
2. **Then** run `terraform destroy` or use the cleanup scripts.
3. Failing to delete VXCs before or after destroy will result in orphaned Megaport charges.

> See [`cost-control.md`](cost-control.md) for cost details.
