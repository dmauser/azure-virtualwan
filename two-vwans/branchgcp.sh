# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# ---------------------------------------------------------------------------
lab_require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  echo "[prereq] Missing required tool(s): ${missing[*]}" >&2
  for t in "${missing[@]}"; do
    case "$t" in
      az)        echo "  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      terraform) echo "  - Terraform:         https://developer.hashicorp.com/terraform/install" >&2 ;;
      gcloud)    echo "  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install" >&2 ;;
      jq)        echo "  - jq:                https://jqlang.github.io/jq/download/" >&2 ;;
      openssl)   echo "  - openssl:           install via your OS package manager" >&2 ;;
      python3)   echo "  - python3:           https://www.python.org/downloads/" >&2 ;;
      *)         echo "  - $t:                install via your OS package manager" >&2 ;;
    esac
  done

  if [ ! -t 0 ]; then
    echo "[prereq] Non-interactive shell — install the tool(s) above and re-run." >&2
    exit 1
  fi
  local ans=""
  read -r -p "[prereq] Attempt to install the missing tool(s) now? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[prereq] Install the tool(s) above and re-run." >&2
    exit 1
  fi

  local pm=""
  if   command -v brew    >/dev/null 2>&1; then pm="brew"
  elif command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v dnf     >/dev/null 2>&1; then pm="dnf"
  elif command -v yum     >/dev/null 2>&1; then pm="yum"
  fi
  if [ -z "$pm" ]; then
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually (see links above)." >&2
    exit 1
  fi
  for t in "${missing[@]}"; do
    echo "[prereq] Installing '$t' via $pm ..."
    case "$pm" in
      brew) brew install "$t" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$t" || true ;;
      dnf)  sudo dnf install -y "$t" || true ;;
      yum)  sudo yum install -y "$t" || true ;;
    esac
  done

  missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} (az/terraform/gcloud need a vendor installer — see links above). Re-run when ready." >&2
    exit 1
  fi
}
lab_require_tools gcloud

# Define your variables
project=angular-expanse-327722 #Set your project Name. Get your PROJECT_ID use command: gcloud projects list 
region=us-central1 #Set your region. Get Regions/Zones Use command: gcloud compute zones list
zone=us-central1-c # Set availability zone: a, b or c.
vpcrange=10.0.0.0/24
envname=onprem-central
vmname=vm1
mypip=$(curl -4 ifconfig.io -s) #Gets your Home Public IP or replace with that information. It will add it to the Firewall Rule.

#Create VPC + Subnet
gcloud config set project $project
gcloud compute networks create $envname-vpc --subnet-mode=custom --mtu=1460 --bgp-routing-mode=regional
gcloud compute networks subnets create $envname-subnet --range=$vpcrange --network=$envname-vpc --region=$region

#Create Firewall Rule
gcloud compute firewall-rules create $envname-allow-traffic-from-azure --network $envname-vpc --allow tcp,udp,icmp --source-ranges 192.168.0.0/16,10.0.0.0/8,172.16.0.0/16,35.235.240.0/20,$mypip/32

#Create Unbutu VM:

gcloud compute instances create $envname-vm1 --zone=$zone --machine-type=f1-micro --network-interface=subnet=$envname-subnet,network-tier=PREMIUM --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud --boot-disk-size=10GB --boot-disk-type=pd-balanced --boot-disk-device-name=$envname-vm1 
#gcloud compute instances create $envname-vm1 --zone=$zone --machine-type=f1-micro --network-interface=subnet=$envname-subnet,network-tier=PREMIUM --image=ubuntu-1804-bionic-v20220126 --image-project=ubuntu-os-cloud --boot-disk-size=10GB --boot-disk-type=pd-balanced --boot-disk-device-name=$envname-vm1 
#gcloud compute instances create $envname-vm1 --zone=$zone --machine-type=f1-micro --network-interface=subnet=$envname-subnet,network-tier=PREMIUM --image-family=ubuntu-1804-lts-arm64 --image-project=ubuntu-os-cloud --boot-disk-size=10GB --boot-disk-type=pd-balanced --boot-disk-device-name=$envname-vm1 

#Cloud Router: #***********Validate************
gcloud compute routers create $envname-router --region=$region --network=$envname-vpc --asn=16550

#DirectConnect via MegaPort:
gcloud compute interconnects attachments partner create $envname-vlan --region $region --edge-availability-domain availability-domain-1 --router $envname-router --admin-enabled

# Get the pair key on the output above to setup connection with Megaport
gcloud compute interconnects attachments describe $envname-vlan --region $region 

# Cleanup
gcloud compute interconnects attachments delete $envname-vlan --region $region --quiet 
gcloud compute routers delete $envname-router --region=$region --quiet
gcloud compute instances delete $envname-vm1 --zone=$zone --quiet
gcloud compute firewall-rules delete $envname-allow-traffic-from-azure --quiet
gcloud compute networks subnets delete $envname-subnet --region=$region --quiet
gcloud compute networks delete $envname-vpc --quiet

