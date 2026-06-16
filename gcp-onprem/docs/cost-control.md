# Cost Control — gcp-onprem Lab

> **⚠️ LAB ONLY** — Always destroy resources when not in use. Partner Interconnect attachments bill hourly even when idle.

---

## Cost components

### 1. VLAN Attachment (Partner Interconnect)

- Billed **per hour** from the moment the attachment is created, regardless of whether it is active or passing traffic.
- Rate: approximately **$0.05–$0.10 USD/hour per attachment** (varies by region and capacity).
- This lab creates **2 attachments** (one per environment).
- **~$2.40–$4.80 USD/day** just for attachments if left running.

> **Action**: Run `terraform destroy` (or the cleanup scripts) when you finish the lab.

### 2. Megaport VXC

- Billed by Megaport at a per-Mbps-per-month or port rate.
- Minimum circuit bandwidth typically 50 Mbps.
- Estimated: **$2–$10 USD/day** depending on bandwidth tier and region.
- VXCs are **not managed by Terraform** — you must delete them manually in the Megaport portal.

### 3. GCP VM — `e2-micro`

- Approximately **$0.0084 USD/hour** on-demand in us-west2.
- This lab creates 2 VMs → **~$0.40 USD/day**.
- `e2-micro` qualifies for the GCP free tier in `us-central1`, but **not in us-west2 or us-west4** under this lab config.

### 4. Cloud Router

- Cloud Routers are **free** (no charge for the router resource itself).
- Data processed through the router is charged at standard egress rates.

### 5. Egress / Data Transfer

- Traffic over Partner Interconnect is charged at the **dedicated interconnect egress rate** (lower than internet egress).
- For a lab with light test traffic, this cost is negligible.

---

## Cost summary (approximate, per day)

| Resource                          | Est. cost/day   |
|-----------------------------------|----------------|
| VLAN attachments × 2              | $2.40 – $4.80  |
| Megaport VXC × 2 (50 Mbps each)   | $4 – $20       |
| VM e2-micro × 2                   | $0.40          |
| Data transfer (light lab traffic) | < $1           |
| **Total (rough estimate)**        | **$7 – $26/day** |

---

## Tips to reduce cost

1. **Destroy daily**: run `cleanup.sh` or `cleanup.ps1` after each lab session.
2. **Delete Megaport VXCs first** to stop Megaport billing before running terraform destroy.
3. **Stop VMs** when not actively testing (does not stop attachment billing):
   ```bash
   gcloud compute instances stop onprem-la-vm --zone=us-west2-a --project=YOUR_PROJECT
   gcloud compute instances stop onprem-lv-vm --zone=us-west4-a --project=YOUR_PROJECT
   ```
4. **Use budget alerts** in GCP Billing to get notified if costs exceed a threshold.
5. **Shorter sessions**: the lab can be redeployed from scratch in under 10 minutes with `deploy.sh -y`.

---

## Cleanup checklist

- [ ] Delete Megaport VXC for env1 (LA) in the Megaport portal
- [ ] Delete Megaport VXC for env2 (Phoenix) in the Megaport portal
- [ ] Run `./cleanup.sh` or `.\cleanup.ps1` to terraform destroy all GCP resources
- [ ] Verify no remaining VLAN attachments: `gcloud compute interconnects attachments list --project=YOUR_PROJECT`
- [ ] Verify no remaining VMs: `gcloud compute instances list --project=YOUR_PROJECT`

---

## Disclaimer

> This is a **lab environment** for educational and testing purposes only.  
> Cost estimates are approximate and subject to change. Always check the [GCP Pricing Calculator](https://cloud.google.com/products/calculator) and [Megaport pricing](https://www.megaport.com/pricing/) for current rates.  
> The maintainers of this repository are not responsible for unexpected cloud charges.
