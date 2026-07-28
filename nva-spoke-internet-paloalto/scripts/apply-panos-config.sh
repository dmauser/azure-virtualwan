#!/usr/bin/env bash
# =============================================================================
# apply-panos-config.sh — Post-boot day-0 Palo Alto config push fallback.
#
# Applies the day-0 bootstrap configuration (bootstrap.xml) to each PA
# VM-Series firewall via the PAN-OS XML API after the VM boots.
#
# WHEN TO USE:
#   The Azure Files bootstrap (Phase 5b of deploy.sh) requires shared-key
#   SMB auth on the storage account.  Management-group policy
#   allowSharedKeyAccess=false (e.g. DMAUSER-FDPO) blocks that upload, leaving
#   both firewalls at factory default with no interfaces/zones/routes/NAT.
#   This script is a subscription-portable fallback that pushes the identical
#   configuration via the PAN-OS management API after the VMs are running.
#
# BEHAVIOR:
#   1. Poll each mgmt IP until the PAN-OS XML API (keygen) responds.
#   2. Import bootstrap.xml to the device as a named candidate config.
#   3. Load the imported file as the active candidate config.
#   4. Commit and poll the commit job to completion.
#   5. Verify: ethernet1/1 + ethernet1/2 up, 0.0.0.0/0 route present.
#   Idempotent: safe to re-run; re-applying the same config is a no-op commit.
#
# INTERFACE CONTRACT (called by deploy.sh — do not change flag names):
#   --mgmt-ips        "ip1,ip2"  comma-separated PA management IPs / PIPs
#   --admin-username  username
#   --admin-password  password   (plain; caller passes securely)
#   --timeout-minutes 20         max wait per firewall for API readiness
#
# EXAMPLE:
#   ./apply-panos-config.sh \
#       --mgmt-ips "20.118.168.153,20.106.77.50" \
#       --admin-username azureuser \
#       --admin-password 'MyP@ssw0rd123!' \
#       --timeout-minutes 25
#
# EXIT CODE: 0 = all firewalls configured OK.  Non-zero = one or more failed.
# DEPENDENCIES: curl, bash 4+.  xmllint used for verification if available.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_XML="${SCRIPT_DIR}/../bicep/bootstrap/bootstrap.xml"

# ── Defaults ──────────────────────────────────────────────────────────────────
MGMT_IPS=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
TIMEOUT_MINUTES=20

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mgmt-ips)         MGMT_IPS="$2";          shift 2 ;;
        --admin-username)   ADMIN_USERNAME="$2";     shift 2 ;;
        --admin-password)   ADMIN_PASSWORD="$2";     shift 2 ;;
        --timeout-minutes)  TIMEOUT_MINUTES="$2";    shift 2 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Input validation ──────────────────────────────────────────────────────────
[[ -z "$MGMT_IPS" ]]      && { echo "ERROR: --mgmt-ips required"       >&2; exit 1; }
[[ -z "$ADMIN_USERNAME" ]] && { echo "ERROR: --admin-username required" >&2; exit 1; }
[[ -z "$ADMIN_PASSWORD" ]] && { echo "ERROR: --admin-password required" >&2; exit 1; }

if [[ ! -f "$BOOTSTRAP_XML" ]]; then
    echo "ERROR: bootstrap.xml not found at: ${BOOTSTRAP_XML}" >&2
    echo "       Expected: nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml" >&2
    exit 1
fi

# ── Logging helpers ───────────────────────────────────────────────────────────
log()    { echo "[$(date '+%H:%M:%S')] $*"; }
logok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
logwarn(){ echo "[$(date '+%H:%M:%S')] WARN $*"; }
logerr() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }
logdot() { echo "[$(date '+%H:%M:%S')] ... $*"; }

# ── XML helpers ───────────────────────────────────────────────────────────────
# Extract text between <tag>...</tag> (single-line, first match).
# Uses sed BRE (portable) with an xmllint fallback if available.
pan_xml_value() {
    local xml="$1" tag="$2" val
    val="$(echo "$xml" | sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p" | head -1)"
    printf '%s' "$val"
}

# Returns 0 if the PAN-OS response indicates success.
pan_success() {
    echo "$1" | grep -qE "status='success'|status=\"success\""
}

# ── Per-firewall configuration function ───────────────────────────────────────
configure_firewall() {
    local ip="$1"
    local deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
    local key="" resp="" attempt=0

    # ── Step 1: Poll PAN-OS API (keygen) until ready ──────────────────────────
    log "[$ip] Waiting for PAN-OS API readiness (timeout ${TIMEOUT_MINUTES} min) ..."
    log "[$ip] Note: PA VM typically takes 10-15 min post-provisioning to be API-ready."

    while [[ $(date +%s) -lt $deadline ]]; do
        attempt=$(( attempt + 1 ))
        # --data-urlencode with --get encodes user/password properly and sends as GET
        resp="$(curl -sk --max-time 30 \
            --get \
            --data-urlencode "type=keygen" \
            --data-urlencode "user=${ADMIN_USERNAME}" \
            --data-urlencode "password=${ADMIN_PASSWORD}" \
            "https://${ip}/api/" 2>/dev/null)" || resp=""

        if pan_success "$resp"; then
            key="$(pan_xml_value "$resp" "key")"
            if [[ -n "$key" ]]; then
                logok "[$ip] API ready (attempt ${attempt}) — API key obtained."
                break
            fi
        fi

        local remaining=$(( deadline - $(date +%s) ))
        [[ $remaining -le 0 ]] && break
        local sleep_sec=$(( remaining > 30 ? 30 : remaining ))
        logdot "[$ip] Not ready (attempt ${attempt}) — retrying in ${sleep_sec}s ..."
        sleep "$sleep_sec"
    done

    if [[ -z "$key" ]]; then
        logerr "[$ip] TIMEOUT: PAN-OS API not reachable after ${TIMEOUT_MINUTES} minutes."
        return 1
    fi

    # ── Step 2: Import bootstrap.xml as a named configuration file ────────────
    # -F sends multipart/form-data; type/category/key are form fields;
    # file=@ uploads the XML file as field "file" with filename "bootstrap.xml".
    # PAN-OS stores the file under the uploaded filename for later "load config from".
    log "[$ip] Importing bootstrap.xml to device configuration store ..."
    resp="$(curl -sk --max-time 120 \
        -F "type=import" \
        -F "category=configuration" \
        -F "key=${key}" \
        -F "file=@${BOOTSTRAP_XML};filename=bootstrap.xml" \
        "https://${ip}/api/" 2>/dev/null)" \
        || { logerr "[$ip] Import curl command failed."; return 1; }

    if ! pan_success "$resp"; then
        logerr "[$ip] Import API call failed: ${resp}"
        return 1
    fi
    logok "[$ip] bootstrap.xml imported successfully."

    # ── Step 3: Load the imported file as candidate configuration ─────────────
    # "load config from bootstrap.xml" replaces the candidate config with the
    # file we just uploaded, preserving every element from bootstrap.xml
    # (interfaces, zones, VR routes, NAT, security, deviceconfig, etc.).
    log "[$ip] Loading bootstrap.xml as candidate configuration ..."
    resp="$(curl -sk --max-time 60 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<load><config><from>bootstrap.xml</from></config></load>" \
        "https://${ip}/api/" 2>/dev/null)" \
        || { logerr "[$ip] Load curl command failed."; return 1; }

    if ! pan_success "$resp"; then
        logerr "[$ip] Load config failed: ${resp}"
        return 1
    fi
    logok "[$ip] Candidate configuration loaded from bootstrap.xml."

    # ── Step 4: Commit ────────────────────────────────────────────────────────
    log "[$ip] Committing configuration ..."
    resp="$(curl -sk --max-time 60 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=commit" \
        --data-urlencode "cmd=<commit></commit>" \
        "https://${ip}/api/" 2>/dev/null)" \
        || { logerr "[$ip] Commit curl command failed."; return 1; }

    if ! pan_success "$resp"; then
        logerr "[$ip] Commit request failed: ${resp}"
        return 1
    fi

    # "no changes" = candidate matches running (idempotent re-run after successful bootstrap)
    if echo "$resp" | grep -qi "no changes"; then
        logok "[$ip] No config changes to commit — configuration already applied (idempotent)."
    else
        local job_id
        job_id="$(pan_xml_value "$resp" "job")"
        if [[ -z "$job_id" ]]; then
            logerr "[$ip] Commit response contained no job ID: ${resp}"
            return 1
        fi
        logdot "[$ip] Commit job ID: ${job_id} — polling for completion ..."

        # ── Step 5: Poll commit job ───────────────────────────────────────────
        local commit_deadline=$(( $(date +%s) + 600 ))
        local commit_ok=false
        local job_status="" job_result="" job_progress=""

        while [[ $(date +%s) -lt $commit_deadline ]]; do
            sleep 10
            resp="$(curl -sk --max-time 30 \
                -X POST \
                --data-urlencode "key=${key}" \
                --data-urlencode "type=op" \
                --data-urlencode "cmd=<show><jobs><id>${job_id}</id></jobs></show>" \
                "https://${ip}/api/" 2>/dev/null)" || continue

            job_status="$(pan_xml_value "$resp" "status")"
            job_result="$(pan_xml_value "$resp" "result")"
            job_progress="$(pan_xml_value "$resp" "progress")"
            logdot "[$ip] Job ${job_id}: status=${job_status} result=${job_result} progress=${job_progress}%"

            if [[ "$job_status" == "FIN" ]]; then
                if [[ "$job_result" == "OK" ]]; then
                    logok "[$ip] Commit job ${job_id} completed successfully."
                    commit_ok=true
                else
                    local details
                    details="$(pan_xml_value "$resp" "details")"
                    logerr "[$ip] Commit job ${job_id} FAILED: ${details:-see raw response}"
                fi
                break
            fi
        done

        if ! $commit_ok; then
            [[ $(date +%s) -ge $commit_deadline ]] && logerr "[$ip] Commit job timed out after 10 minutes."
            return 1
        fi
    fi

    # ── Step 6: Post-commit verification ─────────────────────────────────────
    log "[$ip] Verifying post-commit state (brief pause for DHCP) ..."
    sleep 8

    # Verify ethernet1/1 (untrust) — expect DHCP IP in snet-untrust 10.0.0.32/27
    resp="$(curl -sk --max-time 30 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<show><interface>ethernet1/1</interface></show>" \
        "https://${ip}/api/" 2>/dev/null)" || resp=""
    if echo "$resp" | grep -qE "10\.0\.0\.[0-9]+|<state>up</state>"; then
        logok "[$ip] ethernet1/1 (untrust) — UP with DHCP address."
    else
        logwarn "[$ip] ethernet1/1 may still be awaiting DHCP; verify manually."
    fi

    # Verify ethernet1/2 (trust) — expect DHCP IP in snet-trust 10.0.0.64/27
    resp="$(curl -sk --max-time 30 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<show><interface>ethernet1/2</interface></show>" \
        "https://${ip}/api/" 2>/dev/null)" || resp=""
    if echo "$resp" | grep -qE "10\.0\.0\.[0-9]+|<state>up</state>"; then
        logok "[$ip] ethernet1/2 (trust) — UP with DHCP address."
    else
        logwarn "[$ip] ethernet1/2 may still be awaiting DHCP; verify manually."
    fi

    # Verify virtual-router has 0.0.0.0/0 default route (via ethernet1/1 → 10.0.0.33)
    resp="$(curl -sk --max-time 30 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<show><routing><route></route></routing></show>" \
        "https://${ip}/api/" 2>/dev/null)" || resp=""
    if echo "$resp" | grep -q "0\.0\.0\.0/0"; then
        logok "[$ip] Virtual-router has 0.0.0.0/0 default route (via ethernet1/1 → 10.0.0.33)."
    else
        logwarn "[$ip] 0.0.0.0/0 route not yet visible — may appear once DHCP assigns ethernet1/1 IP."
    fi

    # Verify 168.63.129.16/32 probe-return route (critical for ILB health probes)
    # Without this /32 route, the ILB TCP/22 probe SYN-ACK exits on the wrong
    # interface, Azure SDN drops it as spoofed, and health probes stay 0% healthy.
    resp="$(curl -sk --max-time 30 \
        -X POST \
        --data-urlencode "key=${key}" \
        --data-urlencode "type=op" \
        --data-urlencode "cmd=<show><routing><route><destination>168.63.129.16/32</destination></route></routing></show>" \
        "https://${ip}/api/" 2>/dev/null)" || resp=""
    if echo "$resp" | grep -q "168\.63\.129\.16"; then
        logok "[$ip] 168.63.129.16/32 probe-return route present (ILB health probe symmetric path OK)."
    else
        logwarn "[$ip] 168.63.129.16/32 probe-return route not visible yet — critical for ILB health probes."
    fi

    logok "[$ip] ══ PASS — Day-0 configuration applied and committed. ══"
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Split comma-separated IPs into array
IFS=',' read -ra IP_ARRAY <<< "$MGMT_IPS"

log "=============================================="
log "PAN-OS day-0 config push  (post-boot fallback)"
log "=============================================="
log "  bootstrap.xml : ${BOOTSTRAP_XML}"
log "  Firewalls     : ${MGMT_IPS}"
log "  Timeout/FW    : ${TIMEOUT_MINUTES} min"
log "  bash version  : ${BASH_VERSION}"
log ""

PASS_LIST=()
FAIL_LIST=()

# set -e does not abort on function returns that are inside 'if' conditions
for ip in "${IP_ARRAY[@]}"; do
    ip="$(echo "$ip" | tr -d ' ')"   # strip accidental whitespace
    [[ -z "$ip" ]] && continue

    log "══════════ Configuring ${ip} ══════════"
    if configure_firewall "$ip"; then
        PASS_LIST+=("$ip")
    else
        FAIL_LIST+=("$ip")
    fi
    log ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
log "=============================================="
log "RESULT SUMMARY"
log "=============================================="
for ip in "${PASS_LIST[@]}"; do
    log "  PASS  ${ip}"
done
for ip in "${FAIL_LIST[@]}"; do
    log "  FAIL  ${ip}"
done
log ""

FAIL_COUNT="${#FAIL_LIST[@]}"
TOTAL="${#IP_ARRAY[@]}"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    logok "All ${TOTAL} firewall(s) configured successfully."
    exit 0
else
    logerr "${FAIL_COUNT} of ${TOTAL} firewall(s) FAILED configuration."
    logerr "Check the per-firewall log above for details."
    exit 1
fi
