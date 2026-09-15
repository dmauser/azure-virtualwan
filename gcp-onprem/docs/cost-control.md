# Cost Control — gcp-onprem Lab

> **⚠️ LAB ONLY** — Always destroy resources when not in use. Partner Interconnect attachments bill hourly even when idle.

---

## Cost components

### 1. VLAN Attachment (Partner Interconnect)

- Billed **per hour** from the moment the attachment is created, regardless of whether it is active or passing traffic.
- Rate: approximately **$0.05–$0.10 USD/hour per attachment** (varies by region and capacity).
- This lab creates **one attachment per environment** (`N` total — you choose `N` at deploy time).
- **~$1.20–$2.40 USD/day per attachment** if left running (multiply by `N`).

> **Action**: Run `terraform destroy` (or the cleanup scripts) when you finish the lab.

### 2. Megaport VXC

- Billed by Megaport at a per-Mbps-per-month or port rate.
- Minimum circuit bandwidth typically 50 Mbps.
- Estimated: **$2–$10 USD/day per VXC** depending on bandwidth tier and region.
- VXCs are **not managed by Terraform** — you must delete them manually in the Megaport portal.

### 3. GCP VM — `e2-micro`

- Approximately **$0.0084 USD/hour** on-demand (varies by region).
- This lab creates **one VM per environment** → **~$0.20 USD/day each**.
- `e2-micro` qualifies for the GCP free tier in `us-central1`, but **not in most other regions** under this lab config.

### 4. Cloud Router

- Cloud Routers are **free** (no charge for the router resource itself).
- Data processed through the router is charged at standard egress rates.

### 5. Egress / Data Transfer

- Traffic over Partner Interconnect is charged at the **dedicated interconnect egress rate** (lower than internet egress).
- For a lab with light test traffic, this cost is negligible.

---

## Cost summary (approximate, per day)

Costs scale **linearly with the number of environments (`N`)** you deploy. Example for `N = 2`:

| Resource                          | Est. cost/day   |
|-----------------------------------|----------------|
| VLAN attachments × N (here 2)     | $2.40 – $4.80  |
| Megaport VXC × N (50 Mbps each)   | $4 – $20       |
| VM e2-micro × N (here 2)          | $0.40          |
| Data transfer (light lab traffic) | < $1           |
| **Total (rough estimate, N=2)**   | **$7 – $26/day** |

> For a single-environment deployment (`N = 1`), roughly halve these figures.

---

## Tips to reduce cost

1. **Destroy daily**: run `cleanup.sh` or `cleanup.ps1` after each lab session.
2. **Delete Megaport VXCs first** to stop Megaport billing before running terraform destroy.
3. **Stop VMs** when not actively testing (does not stop attachment billing):
   ```bash
   # Stop each environment's VM (onprem-<N>-vm) in its zone
   gcloud compute instances stop onprem-1-vm --zone=us-central1-a --project=YOUR_PROJECT
   gcloud compute instances stop onprem-2-vm --zone=us-west2-a --project=YOUR_PROJECT
   ```
4. **Use budget alerts** in GCP Billing to get notified if costs exceed a threshold.
5. **Shorter sessions**: the lab can be redeployed from scratch in under 10 minutes with `deploy.sh -y`.

---

## Cleanup checklist

- [ ] Delete the Megaport VXC for **each** environment (`env1`, `env2`, …) in the Megaport portal
- [ ] Run `./cleanup.sh` or `.\cleanup.ps1` to terraform destroy all GCP resources
- [ ] Verify no remaining VLAN attachments: `gcloud compute interconnects attachments list --project=YOUR_PROJECT`
- [ ] Verify no remaining VMs: `gcloud compute instances list --project=YOUR_PROJECT`

---

## Disclaimer

> This is a **lab environment** for educational and testing purposes only.  
> Cost estimates are approximate and subject to change. Always check the [GCP Pricing Calculator](https://cloud.google.com/products/calculator) and [Megaport pricing](https://www.megaport.com/pricing/) for current rates.  
> The maintainers of this repository are not responsible for unexpected cloud charges.
