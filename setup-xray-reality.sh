#!/usr/bin/env bash
#
# setup-xray-reality.sh
#
# Fully automated installer & manager for a hardened Xray VLESS-TCP-XTLS-Vision-REALITY
# server instance on Debian/Ubuntu VPS.
#
set -euo pipefail

SCRIPT_START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Terminal Output & Formatting Toolkit
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4); C_MAGENTA=$(tput setaf 5); C_CYAN=$(tput setaf 6); C_WHITE=$(tput setaf 7)
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""
fi

banner() {
  echo ""
  echo "${C_CYAN}  ╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_CYAN}  ║   ${C_BOLD}${C_WHITE}Xray VLESS · TCP · XTLS-Vision · REALITY Hardened Setup${C_RESET}${C_CYAN}   ║${C_RESET}"
  echo "${C_CYAN}  ╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
}

step_icon() {
  case "$1" in
    *"Preparing server"*)     echo "📦" ;;
    *"Xray-core"*)            echo "⬇️ " ;;
    *"credentials"*)          echo "🔑" ;;
    *"Writing Xray config"*)  echo "⚙️ " ;;
    *"systemd service"*)      echo "🛡️ " ;;
    *"firewall"*)             echo "🧱" ;;
    *"fail2ban"*)             echo "🚫" ;;
    *"BBR"*)                  echo "⚡" ;;
    *"reboot"*)               echo "🔄" ;;
    *"Restarting"*)           echo "🔁" ;;
    *"Rotating"*)             echo "🔃" ;;
    *"Restoring"*)            echo "♻️ " ;;
    *"backup"*|*"Scanning"*)  echo "🗂️ " ;;
    *)                        echo "▪" ;;
  esac
}

progress_bar() {
  local label="$1" width=22
  if [[ "$label" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    local current="${BASH_REMATCH[1]}" total="${BASH_REMATCH[2]}"
    local filled=$((width * current / total))
    local empty=$((width - filled))
    local bar="" i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    echo "$bar"
  fi
}

step() {
  local label="$1" desc="$2" icon bar
  icon=$(step_icon "$desc")
  bar=$(progress_bar "$label")
  
  echo ""
  if [[ -n "$bar" ]]; then
    # Store the formatted bar globally for the live spinner line
    CURRENT_PROGRESS_BAR="${C_CYAN}${bar}${C_RESET} "
    echo "${C_BLUE}${C_BOLD}==> [$label]${C_RESET} ${CURRENT_PROGRESS_BAR}${icon} ${C_BOLD}${desc}${C_RESET}"
  else
    # Clear it for steps that don't have a numeric progress label (e.g., "final")
    CURRENT_PROGRESS_BAR=""
    echo "${C_BLUE}${C_BOLD}==> [$label]${C_RESET} ${icon} ${C_BOLD}${desc}${C_RESET}"
  fi
}

ok()   { echo "${C_GREEN}  ✓ $1${C_RESET}"; }
warn() { echo "${C_YELLOW}  ⚠ WARNING:${C_RESET} $1" >&2; }
err()  { echo "${C_RED}  ✗ ERROR:${C_RESET} $1" >&2; }

elapsed_time() {
  local now elapsed mins secs
  now=$(date +%s)
  elapsed=$((now - SCRIPT_START_TIME))
  mins=$((elapsed / 60))
  secs=$((elapsed % 60))
  if [[ "$mins" -gt 0 ]]; then
    echo "${mins}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
# Global variable to hold the current step's progress bar state for the spinner
CURRENT_PROGRESS_BAR=""

run_spinner() {
  local desc="$1"; shift
  local logfile
  logfile=$(mktemp)

  "$@" >"$logfile" 2>&1 &
  local pid=$!

  if [[ -t 1 ]]; then
    tput civis 2>/dev/null || true
    local i=0 frame
    while kill -0 "$pid" 2>/dev/null; do
      frame="${SPINNER_FRAMES[i % ${#SPINNER_FRAMES[@]}]}"
      # Inject the live progress bar into the carriage return (\r) loop
      printf "\r  %s${C_CYAN}%s${C_RESET} %s..." "$CURRENT_PROGRESS_BAR" "$frame" "$desc"
      i=$((i + 1))
      sleep 0.1
    done
    tput cnorm 2>/dev/null || true
  else
    echo "Running: ${desc}..."
  fi

  local rc=0
  wait "$pid" || rc=$?

  if [[ -t 1 ]]; then
    printf "\r\033[K"
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "$desc"
  else
    err "${desc} failed (exit ${rc}). Output snippet:"
    sed 's/^/  /' "$logfile" | tail -n 20 >&2
  fi

  rm -f "$logfile"
  return "$rc"
}

trap '[[ -t 1 ]] && tput cnorm 2>/dev/null; true' EXIT

# ---------------------------------------------------------------------------
# Configuration Defaults & Environmental Variables
# ---------------------------------------------------------------------------
SNI_DOMAIN_DEFAULT="${SNI_DOMAIN:-i.ytimg.com}"
LISTEN_PORT_DEFAULT="${LISTEN_PORT:-443}"
SCRIPT_SOURCE_URL="${SCRIPT_SOURCE_URL:-https://raw.githubusercontent.com/davidbr5264/VLESS-TCP-XTLS-Vision-REALITY-automated-script/master/setup-xray-reality.sh}"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
STATE_FILE="${XRAY_CONFIG_DIR}/.reality-state"
CLIENT_INFO_FILE="/root/xray-client-info.txt"
BACKUP_ROOT="/root/xray-backups"
SERVICE_NAME="xray"

MODE="install"
RESTORE_TS=""
case "${1:-}" in
  --rotate-uuid)   MODE="rotate-uuid" ;;
  --rotate-all)    MODE="rotate-all" ;;
  --show)          MODE="show" ;;
  --list-backups)  MODE="list-backups" ;;
  --dedupe-backups) MODE="dedupe-backups" ;;
  --restore)
    MODE="restore"
    RESTORE_TS="${2:-}"
    if [[ -z "$RESTORE_TS" ]]; then
      err "--restore requires a timestamp parameter. Use --list-backups to view timestamps."
      exit 1
    fi
    ;;
  --help|-h)
    sed -n '2,30p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    err "Unknown argument '$1'. Use --help for usage details."
    exit 1
    ;;
esac

banner

# ---------------------------------------------------------------------------
# Preflight Verification
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This script requires superuser privileges. Please execute using sudo or as root."
  exit 1
fi

LOCK_FILE="/var/lock/reality-setup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  err "Another operation is currently using lockfile: ${LOCK_FILE}."
  exit 1
fi

if [[ "$MODE" != "install" ]] && ! command -v xray >/dev/null 2>&1; then
  err "Xray installation not found. Run standard installation mode first."
  exit 1
fi

if [[ "$MODE" != "install" ]]; then
  for dep in jq openssl qrencode; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      err "Missing required dependency: '${dep}'."
      echo "       Install it using: apt-get install -y ${dep}" >&2
      exit 1
    fi
  done
fi

if [[ "$MODE" == "install" ]] && ! command -v apt-get >/dev/null 2>&1; then
  err "Unsupported OS. This automated script requires Debian or Ubuntu."
  exit 1
fi

if [[ "$MODE" == "install" ]]; then
  AVAILABLE_KB=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  MIN_REQUIRED_KB=1048576  # 1GB
  if [[ -n "$AVAILABLE_KB" ]] && [[ "$AVAILABLE_KB" -lt "$MIN_REQUIRED_KB" ]]; then
    err "Insufficient disk space on / ($((AVAILABLE_KB / 1024))MB available, 1024MB required)."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Load Existing State
# ---------------------------------------------------------------------------
SNI_DOMAIN="$SNI_DOMAIN_DEFAULT"
LISTEN_PORT="$LISTEN_PORT_DEFAULT"
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SSH_PORT=""

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  if [[ "$SNI_DOMAIN_DEFAULT" != "i.ytimg.com" && "$SNI_DOMAIN_DEFAULT" != "$SNI_DOMAIN" ]]; then
    warn "SNI_DOMAIN override ignored; existing deployment state '${SNI_DOMAIN}' takes precedence."
  fi
  if [[ "$LISTEN_PORT_DEFAULT" != "443" && "$LISTEN_PORT_DEFAULT" != "$LISTEN_PORT" ]]; then
    warn "LISTEN_PORT override ignored; existing state port ${LISTEN_PORT} takes precedence."
  fi
fi

if [[ "$MODE" == "show" ]]; then
  if [[ -z "$UUID" || -z "$PUBLIC_KEY" ]]; then
    err "No previous state file found (${STATE_FILE}). Run full setup first."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Helper Modules
# ---------------------------------------------------------------------------
backup_current_state() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local ts backup_dir
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="${BACKUP_ROOT}/${ts}"
    mkdir -p "$backup_dir"
    cp -a "$CONFIG_FILE" "$backup_dir/config.json" 2>/dev/null || true
    [[ -f "$CLIENT_INFO_FILE" ]] && cp -a "$CLIENT_INFO_FILE" "$backup_dir/client-info.txt" 2>/dev/null || true
    [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$backup_dir/state" 2>/dev/null || true
    chmod -R 600 "$backup_dir"/* 2>/dev/null || true

    if [[ -d "$BACKUP_ROOT" ]]; then
      local backup_count
      backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
      if [[ "$backup_count" -gt 15 ]]; then
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((backup_count - 15))" | xargs -r rm -rf
      fi
    fi
  fi
}

generate_uuid_and_shortid() {
  UUID=$(xray uuid) || { err "Failed executing 'xray uuid'."; exit 1; }
  SHORT_ID=$(openssl rand -hex 8)
  if [[ -z "$UUID" || -z "$SHORT_ID" ]]; then
    err "Generation of cryptographic tokens failed."
    exit 1
  fi
}

generate_reality_keypair() {
  local key_output
  key_output=$(xray x25519) || { err "Failed executing 'xray x25519'."; exit 1; }

  PRIVATE_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Private ?[Kk]ey)[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  PUBLIC_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Public ?[Kk]ey|Password)([[:space:]]*\(.*\))?[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Failed parsing REALITY keypairs."
    exit 1
  fi
}

write_config() {
  mkdir -p "$XRAY_CONFIG_DIR"
  local tmp_config
  tmp_config=$(mktemp "${XRAY_CONFIG_DIR}/.config.json.XXXXXX")
  cat > "$tmp_config" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://9.9.9.9/dns-query"
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "client1"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI_DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${SNI_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": {
        "response": {
          "type": "none"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "169.254.169.254/32",
          "169.254.0.0/16",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "fd00::/8",
          "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

  if ! jq empty "$tmp_config" >/dev/null 2>&1; then
    err "Draft JSON schema validation failed. Configuration aborted."
    exit 1
  fi

  mkdir -p /var/log/xray
  chown -R xray:xray /var/log/xray 2>/dev/null || true

  if command -v xray >/dev/null 2>&1; then
    if ! XRAY_TEST_OUTPUT=$(xray run -test -format json -config "$tmp_config" 2>&1); then
      err "Xray core engine rejected the generated configuration:"
      echo "$XRAY_TEST_OUTPUT" | sed 's/^/  /' >&2
      exit 1
    fi
  fi

  if [[ -f "$CONFIG_FILE" ]] && cmp -s "$tmp_config" "$CONFIG_FILE"; then
    CONFIG_CHANGED=0
  else
    CONFIG_CHANGED=1
    backup_current_state
  fi

  mv -f "$tmp_config" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
}

save_state() {
  local tmp_state
  tmp_state=$(mktemp "${XRAY_CONFIG_DIR}/.reality-state.XXXXXX")
  cat > "$tmp_state" <<EOF
SNI_DOMAIN="${SNI_DOMAIN}"
LISTEN_PORT="${LISTEN_PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
SSH_PORT="${SSH_PORT}"
EOF
  chmod 600 "$tmp_state"
  mv -f "$tmp_state" "$STATE_FILE"
}

restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    err "Xray service failed to enter active state. Debug logs: journalctl -u xray -e"
    exit 1
  fi
  ok "Xray systemd service is active and running."
  verify_handshake
}

verify_handshake() {
  local port="${LISTEN_PORT:-443}"
  local sni="${SNI_DOMAIN:-}"

  if ! ss -tln 2>/dev/null | grep -q ":${port} "; then
    warn "No process actively listening on target port ${port}."
    return 0
  fi

  if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    warn "Local TCP loopback connection attempt failed on port ${port}."
    return 0
  fi

  if [[ -n "$sni" ]] && command -v openssl >/dev/null 2>&1; then
    if ! timeout 5 bash -c "echo | openssl s_client -connect 127.0.0.1:${port} -servername '${sni}' 2>/dev/null" | grep -q "CONNECTED"; then
      warn "TLS handshake check returned non-zero response (Check journalctl if clients fail)."
      return 0
    fi
  fi

  ok "Active verification successful: Port open, TCP connection verified, TLS handshake completed."
}

output_client_info() {
  local server_ip
  server_ip=$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://icanhazip.com 2>/dev/null || \
              true)
  server_ip=$(echo "$server_ip" | tr -d '[:space:]')

  if [[ -z "$server_ip" ]]; then
    warn "Unable to detect public IP address automatically."
    server_ip="YOUR_SERVER_IP"
  fi

  local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision&spx=%2F#xray-reality-$(hostname)"

  cat > "$CLIENT_INFO_FILE" <<EOF
================= Xray VLESS-TCP-XTLS-Vision-REALITY =================
Server IP     : ${server_ip}
Port          : ${LISTEN_PORT}
UUID          : ${UUID}
Flow          : xtls-rprx-vision
Security      : reality
SNI (dest)    : ${SNI_DOMAIN}
Public Key    : ${PUBLIC_KEY}
Private Key   : ${PRIVATE_KEY}   (server-side confidential)
Short ID      : ${SHORT_ID}
Fingerprint   : chrome

Client Import Link:
${vless_link}
========================================================================
EOF
  chmod 600 "$CLIENT_INFO_FILE"

  local status_now status_color
  status_now=$(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo unknown)
  if [[ "$status_now" == "active" ]]; then status_color="$C_GREEN"; else status_color="$C_YELLOW"; fi

  echo ""
  echo "${C_CYAN}┌──────────────────────────────────────────────────────────────┐${C_RESET}"
  echo "${C_CYAN}│${C_RESET} ${C_BOLD}Deployment Summary${C_RESET}"
  echo "${C_CYAN}├──────────────────────────────────────────────────────────────┤${C_RESET}"
  echo "${C_CYAN}│${C_RESET}  Service Status : ${status_color}${status_now}${C_RESET}"
  echo "${C_CYAN}│${C_RESET}  Configuration  : ${C_WHITE}${CONFIG_FILE}${C_RESET}"
  echo "${C_CYAN}│${C_RESET}  Credentials    : ${C_WHITE}${CLIENT_INFO_FILE}${C_RESET}"
  echo "${C_CYAN}└──────────────────────────────────────────────────────────────┘${C_RESET}"
  echo ""
  echo "${C_BOLD}Client Import Connection Link:${C_RESET}"
  echo "${C_GREEN}${vless_link}${C_RESET}"
  echo ""
  echo "${C_BOLD}QR Code:${C_RESET}"
  qrencode -t ansiutf8 "${vless_link}"
}

# ---------------------------------------------------------------------------
# Auxiliary Modes
# ---------------------------------------------------------------------------
if [[ "$MODE" == "show" ]]; then
  output_client_info
  exit 0
fi

if [[ "$MODE" == "list-backups" ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups located in ${BACKUP_ROOT}."
    exit 0
  fi
  echo "Available configurations for restore (--restore <timestamp>):"
  for dir in "$BACKUP_ROOT"/*/; do
    ts=$(basename "$dir")
    contents=$(ls "$dir" 2>/dev/null | tr '\n' ' ')
    echo "  ${ts}   (${contents})"
  done
  exit 0
fi

if [[ "$MODE" == "dedupe-backups" ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No state backups located."
    exit 0
  fi

  step "dedupe" "Pruning redundant identical consecutive backups"
  mapfile -t ALL_BACKUPS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

  PREV_HASH=""
  PREV_DIR=""
  REMOVED_COUNT=0
  KEPT_COUNT=0

  for dir in "${ALL_BACKUPS[@]}"; do
    if [[ ! -f "${dir}/config.json" ]]; then
      PREV_HASH=""
      PREV_DIR=""
      continue
    fi
    CURRENT_HASH=$(sha256sum "${dir}/config.json" 2>/dev/null | awk '{print $1}')

    if [[ -n "$PREV_HASH" && "$CURRENT_HASH" == "$PREV_HASH" ]]; then
      rm -rf "$PREV_DIR"
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    else
      KEPT_COUNT=$((KEPT_COUNT + 1))
    fi
    PREV_HASH="$CURRENT_HASH"
    PREV_DIR="$dir"
  done

  ok "Pruning complete. Removed: ${REMOVED_COUNT}, Retained: ${KEPT_COUNT}."
  exit 0
fi

if [[ "$MODE" == "restore" ]]; then
  RESTORE_DIR="${BACKUP_ROOT}/${RESTORE_TS}"
  if [[ ! -d "$RESTORE_DIR" ]]; then
    err "Specified backup non-existent: ${RESTORE_DIR}."
    exit 1
  fi
  if [[ ! -f "${RESTORE_DIR}/config.json" ]]; then
    err "Missing config.json in backup target."
    exit 1
  fi

  step "restore" "Restoring deployment state from: ${RESTORE_TS}"
  backup_current_state

  if ! jq empty "${RESTORE_DIR}/config.json" >/dev/null 2>&1; then
    err "Target configuration invalid JSON. Restoration aborted."
    exit 1
  fi

  if command -v xray >/dev/null 2>&1; then
    if ! RESTORE_TEST_OUTPUT=$(xray run -test -format json -config "${RESTORE_DIR}/config.json" 2>&1); then
      err "Target configuration failed core schema checks:"
      echo "$RESTORE_TEST_OUTPUT" | sed 's/^/  /' >&2
      exit 1
    fi
  fi

  cp -a "${RESTORE_DIR}/config.json" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  [[ -f "${RESTORE_DIR}/state" ]] && cp -a "${RESTORE_DIR}/state" "$STATE_FILE" && chmod 600 "$STATE_FILE"
  [[ -f "${RESTORE_DIR}/client-info.txt" ]] && cp -a "${RESTORE_DIR}/client-info.txt" "$CLIENT_INFO_FILE" && chmod 600 "$CLIENT_INFO_FILE"

  restart_and_verify
  echo ""
  echo "Successfully restored system state from ${RESTORE_TS}."
  exit 0
fi

if [[ "$MODE" == "rotate-uuid" ]]; then
  step "rotate-uuid" "Rotating client UUID & short ID (Keypair preserved)"
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Missing REALITY keypair. Complete baseline installation first."
    exit 1
  fi
  backup_current_state
  generate_uuid_and_shortid
  write_config
  save_state
  output_client_info
  restart_and_verify
  exit 0
fi

if [[ "$MODE" == "rotate-all" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    warn "This action invalidates ALL active client links permanently."
    read -r -p "Type 'yes' to proceed: " CONFIRM_ROTATE_ALL
    if [[ "$CONFIRM_ROTATE_ALL" != "yes" ]]; then
      echo "Rotation process canceled."
      exit 0
    fi
  fi
  step "rotate-all" "Rotating all operational credentials"
  backup_current_state
  generate_uuid_and_shortid
  generate_reality_keypair
  write_config
  save_state
  output_client_info
  restart_and_verify
  exit 0
fi

# ---------------------------------------------------------------------------
# Main Installation Pipeline
# ---------------------------------------------------------------------------
SELF_UPDATE_CHECK_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
SELF_UPDATE_RESULT_FILE=$(mktemp)
SELF_UPDATE_BG_PID=""
if [[ -f "$SELF_UPDATE_CHECK_PATH" ]]; then
  (
    REMOTE_SCRIPT_TMP=$(mktemp)
    if curl -fsSL --connect-timeout 5 --max-time 10 "$SCRIPT_SOURCE_URL" -o "$REMOTE_SCRIPT_TMP" 2>/dev/null \
       && bash -n "$REMOTE_SCRIPT_TMP" 2>/dev/null; then
      LOCAL_HASH=$(sha256sum "$SELF_UPDATE_CHECK_PATH" 2>/dev/null | awk '{print $1}')
      REMOTE_HASH=$(sha256sum "$REMOTE_SCRIPT_TMP" 2>/dev/null | awk '{print $1}')
      if [[ -n "$LOCAL_HASH" && -n "$REMOTE_HASH" && "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
        echo "outdated" > "$SELF_UPDATE_RESULT_FILE"
      fi
    fi
    rm -f "$REMOTE_SCRIPT_TMP"
  ) &
  SELF_UPDATE_BG_PID=$!
fi

if [[ -z "$UUID" ]] && [[ -t 0 ]]; then
  while true; do
    echo ""
    echo "${C_BOLD}REALITY Camouflage Target Domain (SNI)${C_RESET}"
    echo "Enter a TLS 1.3 enabled target site (e.g., dl.google.com, swdist.apple.com)."
    read -r -p "Target domain [${SNI_DOMAIN}]: " SNI_INPUT
    if [[ -n "$SNI_INPUT" ]]; then
      SNI_INPUT="${SNI_INPUT#http://}"
      SNI_INPUT="${SNI_INPUT#https://}"
      SNI_INPUT="${SNI_INPUT%%/*}"
      SNI_INPUT="${SNI_INPUT%%:*}"
      if [[ -n "$SNI_INPUT" ]]; then
        SNI_DOMAIN="$SNI_INPUT"
      fi
    fi

    if command -v openssl >/dev/null 2>&1; then
      if timeout 6 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 </dev/null >/dev/null 2>&1; then
        ok "Verified: ${SNI_DOMAIN} responds on port 443 with TLS 1.3 support."
        break
      else
        warn "Could not verify TLS 1.3 support on ${SNI_DOMAIN}:443."
        read -r -p "Use this domain regardless? (y/N): " SNI_FORCE
        if [[ "$SNI_FORCE" =~ ^[Yy]$ ]]; then
          break
        fi
      fi
    else
      break
    fi
  done
  echo "Target SNI set to: ${C_CYAN}${SNI_DOMAIN}${C_RESET}"
fi

step "1/9" "Preparing server (updates, packages & hardening)"
export DEBIAN_FRONTEND=noninteractive
run_spinner "Updating apt repositories" apt-get update -y
run_spinner "Upgrading package dependencies" apt-get upgrade -y
run_spinner "Removing unneeded packages" apt-get autoremove -y --purge
run_spinner "Cleaning apt local cache" apt-get autoclean -y

run_spinner "Installing core system utilities" apt-get install -y --no-install-recommends \
  curl wget unzip jq openssl qrencode ufw fail2ban ca-certificates

if ! run_spinner "Installing supplemental libraries" apt-get install -y --no-install-recommends gnupg lsb-release apt-transport-https logrotate; then
  echo "Notice: Non-critical supplemental packages skipped."
fi

if [[ -n "$SELF_UPDATE_BG_PID" ]]; then
  wait "$SELF_UPDATE_BG_PID" 2>/dev/null || true
  if [[ -s "$SELF_UPDATE_RESULT_FILE" ]]; then
    warn "A newer revision of this script is available online."
    echo "         Update using: bash <(curl -Ls ${SCRIPT_SOURCE_URL})" >&2
  fi
fi
rm -f "$SELF_UPDATE_RESULT_FILE"

step "2/9" "Installing Xray-core engine & GeoData"
mkdir -p "$XRAY_CONFIG_DIR"
BEFORE_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")

XRAY_UPDATE_CHECK_CACHE="${XRAY_CONFIG_DIR}/.last-xray-checkupdate"
SKIP_INSTALLER_CHECK=0
if command -v xray >/dev/null 2>&1 && [[ -f "$XRAY_UPDATE_CHECK_CACHE" ]]; then
  LAST_CHECK=$(cat "$XRAY_UPDATE_CHECK_CACHE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ "$LAST_CHECK" =~ ^[0-9]+$ ]] && [[ $((NOW - LAST_CHECK)) -lt 86400 ]]; then
    SKIP_INSTALLER_CHECK=1
  fi
fi

if [[ "$SKIP_INSTALLER_CHECK" -eq 1 ]]; then
  ok "Xray-core check skipped (last checked within 24 hours)."
else
  XRAY_INSTALL_ATTEMPTS=3
  for attempt in $(seq 1 "$XRAY_INSTALL_ATTEMPTS"); do
    if run_spinner "Fetching latest Xray binary (attempt ${attempt}/${XRAY_INSTALL_ATTEMPTS})" \
         bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install; then
      break
    fi
    if [[ "$attempt" -eq "$XRAY_INSTALL_ATTEMPTS" ]]; then
      err "Xray-core installation failed after ${XRAY_INSTALL_ATTEMPTS} attempts."
      exit 1
    fi
    sleep 5
  done
  date +%s > "$XRAY_UPDATE_CHECK_CACHE"
fi

AFTER_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")

step "3/9" "Generating cryptographic parameters"
if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
  echo "Reusing saved operational keys from ${STATE_FILE}."
else
  echo "Generating fresh cryptographic tokens."
  generate_uuid_and_shortid
  generate_reality_keypair
fi

if ! id -u xray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin xray
fi

PORT_HOLDER=$(ss -tlnp 2>/dev/null | awk -v p=":${LISTEN_PORT}\$" '$4 ~ p {print}')
if [[ -n "$PORT_HOLDER" ]] && ! echo "$PORT_HOLDER" | grep -qi "xray"; then
  err "Port ${LISTEN_PORT} is currently occupied by an external application:"
  echo "$PORT_HOLDER" | sed 's/^/  /' >&2
  exit 1
fi

step "4/9" "Generating hardened Xray configuration"
write_config

step "5/9" "Hardening systemd unit and service execution profile"
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<'EOF'
[Unit]
OnFailure=xray-alert.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=xray
Group=xray
Restart=on-failure
RestartSec=5
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xray
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF

cat > /etc/systemd/system/xray-alert.service <<'EOF'
[Unit]
Description=Alert dispatcher for Xray service failures

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'logger -p daemon.crit "xray.service failed exhaustively."; wall "WARNING: xray.service failure." || true'
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true

if command -v timedatectl >/dev/null 2>&1; then
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
  fi
fi

step "6/9" "Configuring firewall (UFW)"
# Optimization: Fall back to active SSH connection socket details if parsing listener fails
SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1)
if [[ -z "$SSH_PORT" && -n "${SSH_CLIENT:-}" ]]; then
  SSH_PORT=$(echo "$SSH_CLIENT" | awk '{print $3}')
fi
SSH_PORT="${SSH_PORT:-22}"

if [[ -f /etc/default/ufw ]] && grep -qE '^IPV6=no' /etc/default/ufw; then
  sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
fi

ufw default deny incoming
ufw default allow outgoing

if ! ufw allow "${SSH_PORT}"/tcp comment 'SSH'; then
  err "Failed allowing SSH port ${SSH_PORT} in UFW."
  exit 1
fi
if ! ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY'; then
  err "Failed allowing Xray port ${LISTEN_PORT} in UFW."
  exit 1
fi

ufw --force enable
ufw reload

step "7/9" "Configuring Fail2ban protection for SSH"
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable fail2ban
systemctl restart fail2ban || warn "Fail2ban failed to restart."

step "8/9" "Applying BBR congestion control & kernel parameters"
# Optimization: Explicitly load tcp_bbr module and make persistent
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat > /etc/sysctl.d/99-xray-hardening.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Security Hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_source_route = 0

# Security: Ptrace restriction
kernel.yama.ptrace_scope = 1

# Performance optimization
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF
sysctl --system >/dev/null 2>&1 || true

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-xray-hardening.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald

cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/error.log {
  weekly
  rotate 4
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF

step "9/9" "Configuring scheduled system reboots"
cat > /etc/systemd/system/daily-reboot.service <<'EOF'
[Unit]
Description=Daily Maintenance Reboot

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r now "Daily reboot"
EOF

cat > /etc/systemd/system/daily-reboot.timer <<'EOF'
[Unit]
Description=Daily Maintenance Reboot Timer

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now daily-reboot.timer

REALITY_SHORTCUT="/usr/local/bin/reality"
SELF_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
REALITY_SHORTCUT_RESOLVED=$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")

if [[ "$SELF_PATH" != "$REALITY_SHORTCUT_RESOLVED" ]]; then
  if [[ -f "$SELF_PATH" ]]; then
    cp -f "$SELF_PATH" "$REALITY_SHORTCUT"
    chmod +x "$REALITY_SHORTCUT"
  fi
fi

save_state
output_client_info

echo ""
echo "${C_GREEN}${C_BOLD}✓ Deployment completed successfully.${C_RESET}"
echo ""
echo "${C_BOLD}Operational Commands:${C_RESET}"
echo "  ${C_CYAN}reality${C_RESET}                 -> Run setup again (creates state backup)"
echo "  ${C_CYAN}reality --rotate-uuid${C_RESET}   -> Revoke active client link"
echo "  ${C_CYAN}reality --rotate-all${C_RESET}    -> Complete credentials reset"
echo "  ${C_CYAN}reality --show${C_RESET}          -> Display client connection details"

step "final" "Activating Xray service"
SERVICE_CURRENTLY_ACTIVE=$(systemctl is-active --quiet "${SERVICE_NAME}" && echo 1 || echo 0)
if [[ "$CONFIG_CHANGED" == "0" ]] && [[ "$BEFORE_XRAY_VERSION" == "$AFTER_XRAY_VERSION" ]] && [[ "$SERVICE_CURRENTLY_ACTIVE" == "1" ]]; then
  ok "No setup alterations detected. Service actively running."
  verify_handshake
else
  restart_and_verify
fi

echo ""
echo "${C_CYAN}Execution completed in $(elapsed_time).${C_RESET}"
