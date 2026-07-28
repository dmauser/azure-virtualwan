# SKILL: pa-vmseries-bootstrap

**Skill ID:** `pa-vmseries-bootstrap`  
**Domain:** Azure IaC / Palo Alto VM-Series  
**Owner:** Naomi (Infra Dev)  
**First used in:** `nva-spoke-internet-paloalto/`  
**Date:** 2026-07-27

---

## Purpose

Deploy Palo Alto VM-Series firewalls on Azure with automated day-0 bootstrap using
an Azure Files share.  Covers the Bicep module patterns and deploy-script phases
needed to provision fully bootstrapped PA instances with zero manual GUI interaction
at deploy time.

---

## Prerequisites (deploy-time)

1. **Marketplace image terms accepted** (once per subscription):
   ```bash
   az vm image terms accept --urn "paloaltonetworks:vmseries-flex:byol:latest"
   ```
   In deploy scripts, run this as Phase 1b (before resource group creation).

2. **Bootstrap files** (`init-cfg.txt`, `bootstrap.xml`) must exist at
   `bicep/bootstrap/` before the deploy script runs Phase 5b.  These are
   authored separately and reference the Azure Files share name/directory.

3. **VM size** must be from the DS-series or D-series (not B-series):
   `Standard_DS3_v2` (preferred) → `Standard_DS4_v2` → `Standard_D3_v2` → `Standard_D4_v2`.

---

## Bicep Module Pattern (`palo-alto.bicep`)

### 1. Plan block (required for marketplace images)

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(0, 2): {
  name: 'pa-fw-${i}'
  location: location
  plan: {
    name: 'byol'
    publisher: 'paloaltonetworks'
    product: 'vmseries-flex'
  }
  properties: {
    storageProfile: {
      imageReference: {
        publisher: 'paloaltonetworks'
        offer: 'vmseries-flex'
        sku: 'byol'
        version: 'latest'
      }
      ...
    }
    ...
  }
}]
```

### 2. 3-NIC design with `mgmt-interface-swap`

```bicep
// eth0 = mgmt (primary NIC, index 0)
// eth1 = untrust (index 1, IP forwarding, Public LB backend)
// eth2 = trust  (index 2, IP forwarding, ILB backend)
networkProfile: {
  networkInterfaces: [
    { id: nicMgmt[i].id,    properties: { primary: true  } }
    { id: nicUntrust[i].id, properties: { primary: false } }
    { id: nicTrust[i].id,   properties: { primary: false } }
  ]
}
```

PA uses `mgmt-interface-swap` (set in `customData`) to map the Azure primary NIC (eth0)
to the PAN-OS management plane.

### 3. Bootstrap `customData` with `@secure()` key

```bicep
@secure()
param bootstrapStorageKey string

// Use the @secure() param DIRECTLY in base64() — never assign to a plain var.
osProfile: {
  customData: base64('type=dhcp-client\nop-command-modes=mgmt-interface-swap\nstorage-account=${bootstrapStorageAccount}\naccess-key=${bootstrapStorageKey}\nfile-share=${bootstrapFileShare}\nshare-directory=${bootstrapShareDirectory}\n')
}
```

### 4. Conditional management PIP (BCP318 suppression)

```bicep
@batchSize(1)
resource pipMgmt 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for i in range(0, 2) if enableMgmtPublicIp: {
  name: 'pip-pa-fw-${i}-mgmt'
  ...
}]

// In NIC properties — use ! (non-null assertion) to suppress BCP318:
publicIPAddress: enableMgmtPublicIp ? { id: pipMgmt[i]!.id } : null
```

### 5. Managed boot diagnostics

```bicep
diagnosticsProfile: {
  bootDiagnostics: {
    enabled: true
    // No storageUri = managed boot diagnostics → enables Azure Serial Console
  }
}
```

---

## DMZ Subnet Layout for PA

| Subnet | CIDR | UDR | Purpose |
|--------|------|-----|---------|
| snet-mgmt | 10.0.0.0/27 | 0/0→Internet | PA eth0 mgmt, optional PIP |
| snet-untrust | 10.0.0.32/27 | 0/0→Internet | PA eth1, Public LB backend |
| snet-trust | 10.0.0.64/27 | **NONE** | PA eth2, ILB backend |

**snet-trust MUST NOT have a 0/0 UDR.**  Return traffic from the trust NIC
uses vWAN-learned routes; a 0/0→Internet UDR would black-hole asymmetric returns.

The ILB static frontend (e.g., 10.0.0.68) must fall within snet-trust's CIDR.
This is the hub's `0.0.0.0/0` next-hop address for spoke internet breakout.

---

## Deploy Script Pattern (Bootstrap Phase)

Run this BEFORE `az deployment group create`:

```bash
# Phase 5b — Bootstrap storage
BOOTSTRAP_SA="pabstrap$(openssl rand -hex 4)"
BOOTSTRAP_SHARE="bootstrap"
BOOTSTRAP_DIR=""   # PA reads init-cfg.txt from config/ within the share

az storage account create -g "$RG" -n "$BOOTSTRAP_SA" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --output none

BOOTSTRAP_SA_KEY=$(az storage account keys list -g "$RG" -n "$BOOTSTRAP_SA" \
  --query "[0].value" -o tsv)

az storage share create --account-name "$BOOTSTRAP_SA" \
  --account-key "$BOOTSTRAP_SA_KEY" -n "$BOOTSTRAP_SHARE" --output none

for dir in config content license software; do
  az storage directory create --account-name "$BOOTSTRAP_SA" \
    --account-key "$BOOTSTRAP_SA_KEY" --share-name "$BOOTSTRAP_SHARE" \
    -n "$dir" --output none
done

for f in init-cfg.txt bootstrap.xml; do
  SRC="${BICEP_DIR}/bootstrap/${f}"
  [[ ! -f "$SRC" ]] && { echo "WARNING: $SRC not found — skipping"; continue; }
  az storage file upload --account-name "$BOOTSTRAP_SA" \
    --account-key "$BOOTSTRAP_SA_KEY" --share-name "$BOOTSTRAP_SHARE" \
    --path "config/${f}" --source "$SRC" --output none
done

# Then pass to az deployment group create:
az deployment group create ... --parameters \
  bootstrapStorageAccount="$BOOTSTRAP_SA" \
  bootstrapStorageKey="$BOOTSTRAP_SA_KEY" \
  bootstrapFileShare="$BOOTSTRAP_SHARE" \
  bootstrapShareDirectory="$BOOTSTRAP_DIR"
```

---

## Bootstrap File Format (`init-cfg.txt`)

Minimal `init-cfg.txt` for Azure Files bootstrap:

```ini
type=dhcp-client
op-command-modes=mgmt-interface-swap
vm-auth-key=<PA auth key from CSP>
panorama-server=<panorama-ip-or-hostname>   # optional
tplname=<template-stack-name>               # optional
dgname=<device-group-name>                  # optional
```

For lab use without Panorama, omit the optional fields.  The VM boots, applies DHCP
on all interfaces, and activates `mgmt-interface-swap`.

---

## Licensing Note (BYOL)

PA VM-Series BYOL boots in unlicensed (eval) mode.  The dataplane is functional for
lab traffic in eval mode.  To apply a license:

1. Open `https://<mgmt-pip>` (admin / password from deploy)
2. Device → Licenses → Activate feature using Auth-Code
3. Enter auth-code from Palo Alto Networks CSP portal

For lab validation, licensing is optional — eval mode forwards traffic.

---

## Reuse Checklist

- [ ] Run `az vm image terms accept --urn paloaltonetworks:vmseries-flex:byol:latest`
- [ ] Provision bootstrap SA + Files share + 4 directories before VM deploy
- [ ] Upload `init-cfg.txt` and `bootstrap.xml` into `config/` directory
- [ ] Include `plan` block in every PA VM resource
- [ ] Use `@secure()` storage key directly in `base64()` (no intermediate `var`)
- [ ] Set eth0 as primary NIC (mgmt-interface-swap maps it to PAN-OS mgmt)
- [ ] Enable IP forwarding on untrust and trust NICs only
- [ ] Use managed boot diagnostics (no storageUri) for Serial Console access
- [ ] snet-trust MUST NOT have 0/0 UDR
- [ ] ILB static frontend must be within snet-trust CIDR
