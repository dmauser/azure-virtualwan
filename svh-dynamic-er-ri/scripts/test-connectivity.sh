#!/usr/bin/env bash
# =============================================================================
# Script : test-connectivity.sh
# Lab    : svh-dynamic-er-ri — Dynamic Secured Virtual WAN (N hubs, ER, AzFW Basic, RI)
# Purpose: Timestamped connectivity test (ping). Prompts for a target IP/host
#          and pings it on a loop, printing one timestamped line per probe:
#
#              [2026-06-16 12:30:01] 10.10.1.4  Reply  time=2 ms
#              [2026-06-16 12:30:02] 10.10.1.4  Timeout / no reply
#
#          Useful for watching connectivity converge while ExpressRoute
#          circuits, Routing Intent or firewall rules come up. Press Ctrl+C to
#          stop; a summary (sent/received/lost + min/avg/max rtt) is printed.
#
#          Read-only: never creates, changes or deletes any resource.
#
# Usage  :
#   ./test-connectivity.sh                                  # prompts for target
#   ./test-connectivity.sh -t 10.10.1.4
#   ./test-connectivity.sh -t 192.168.100.10 -i 2 -l ./la-test.log
#
# Options:
#   -t|--target <ip|host>   Target IP/hostname. Prompted if omitted.
#   -c|--count <n>          Number of probes. 0 = until Ctrl+C (default).
#   -i|--interval <sec>     Seconds between probes. Default: 1.
#   -w|--timeout <sec>      Per-probe timeout in seconds. Default: 2.
#   -l|--log <file>         Also append timestamped output to <file>.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
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
      ping) echo "  - ping (iputils-ping): install via your OS package manager" >&2 ;;
      *)    echo "  - $t: install via your OS package manager" >&2 ;;
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
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually." >&2
    exit 1
  fi
  for t in "${missing[@]}"; do
    local pkg="$t"; [ "$t" = "ping" ] && pkg="iputils-ping"
    echo "[prereq] Installing '$pkg' via $pm ..."
    case "$pm" in
      brew) brew install "$pkg" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$pkg" || true ;;
      dnf)  sudo dnf install -y "$pkg" || true ;;
      yum)  sudo yum install -y "$pkg" || true ;;
    esac
  done

  missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} — re-run when installed." >&2
    exit 1
  fi
}
lab_require_tools ping

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
TARGET=""
COUNT=0
INTERVAL=1
TIMEOUT=2
LOGFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)   TARGET="$2";   shift 2 ;;
    -c|--count)    COUNT="$2";    shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -w|--timeout)  TIMEOUT="$2";  shift 2 ;;
    -l|--log)      LOGFILE="$2";  shift 2 ;;
    -h|--help)     grep -E '^#( |=)' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET" ]; then
  read -r -p "Target IP address or hostname to test: " TARGET
fi
if [ -z "$TARGET" ]; then
  echo "[test-connectivity] No target provided. Exiting." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# State + helpers
# ---------------------------------------------------------------------------
SENT=0
RECEIVED=0
LAT_MIN=""
LAT_MAX=""
LAT_SUM=0

emit() {  # emit <line>
  echo "$1"
  [ -n "$LOGFILE" ] && echo "$1" >> "$LOGFILE"
}

summary() {
  local lost=$(( SENT - RECEIVED ))
  local loss="0"
  if [ "$SENT" -gt 0 ]; then
    loss=$(awk "BEGIN{printf \"%.1f\", ($lost/$SENT)*100}")
  fi
  emit ""
  emit "--- ${TARGET} connectivity summary ---"
  emit "sent=${SENT}  received=${RECEIVED}  lost=${lost} (${loss}% loss)"
  if [ "$RECEIVED" -gt 0 ]; then
    local avg
    avg=$(awk "BEGIN{printf \"%.1f\", $LAT_SUM/$RECEIVED}")
    emit "rtt min/avg/max = ${LAT_MIN}/${avg}/${LAT_MAX} ms"
  fi
  exit 0
}
trap summary INT TERM

# ping option differs slightly across platforms; -W (Linux) is timeout in sec.
emit "[test-connectivity] Pinging ${TARGET}  (interval ${INTERVAL}s, timeout ${TIMEOUT}s). Ctrl+C to stop."

while [ "$COUNT" -le 0 ] || [ "$SENT" -lt "$COUNT" ]; do
  SENT=$(( SENT + 1 ))
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  out="$(ping -c 1 -W "$TIMEOUT" "$TARGET" 2>/dev/null)"
  if [ $? -eq 0 ] && echo "$out" | grep -q 'time='; then
    RECEIVED=$(( RECEIVED + 1 ))
    rtt="$(echo "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n1)"
    rtt_i="$(awk "BEGIN{printf \"%.0f\", $rtt}")"
    LAT_SUM=$(( LAT_SUM + rtt_i ))
    { [ -z "$LAT_MIN" ] || [ "$rtt_i" -lt "$LAT_MIN" ]; } && LAT_MIN="$rtt_i"
    { [ -z "$LAT_MAX" ] || [ "$rtt_i" -gt "$LAT_MAX" ]; } && LAT_MAX="$rtt_i"
    emit "[${ts}] ${TARGET}  Reply  time=${rtt} ms"
  else
    emit "[${ts}] ${TARGET}  Timeout / no reply"
  fi

  if [ "$COUNT" -le 0 ] || [ "$SENT" -lt "$COUNT" ]; then
    sleep "$INTERVAL"
  fi
done

summary
