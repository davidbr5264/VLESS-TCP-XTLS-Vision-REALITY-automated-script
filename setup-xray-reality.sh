#!/usr/bin/env bash
#
# setup-xray-reality.sh
#
# Automated installer / manager for a hardened Xray VLESS-TCP-XTLS-Vision-REALITY
# instance on a Debian/Ubuntu VPS, for personal use.
#
# Usage:
#   ./setup-xray-reality.sh                Install (or re-apply) full setup
#   ./setup-xray-reality.sh --rotate-uuid  Replace UUID + short ID only
#                                           (keeps REALITY keypair; use this to
#                                           revoke a leaked client link without
#                                           regenerating your server's identity)
#   ./setup-xray-reality.sh --rotate-all   Replace UUID + short ID + REALITY
#                                           keypair (invalidates ALL client links)
#   ./setup-xray-reality.sh --show         Reprint the current client link/QR
#                                           without changing anything
#   ./setup-xray-reality.sh --list-backups List available backups with timestamps
#   ./setup-xray-reality.sh --restore TS   Restore config/state from a backup
#                                           (backs up current state first)
#   ./setup-xray-reality.sh --help         Show this help
#
# What a full install does:
#   1. Prepares the server: full apt update/upgrade, cleanup, essential tools
#   2. Installs latest official Xray-core (XTLS/Xray-install)
#   3. Generates UUID, REALITY x25519 keypair, and a short ID
#   4. Writes a minimal-logging config.json (VLESS + TCP + XTLS-Vision + REALITY)
#      camouflaged as a real site (default: i.ytimg.com)
#   5. Locks the systemd unit down (NoNewPrivileges, ProtectSystem, etc.)
#   6. Configures UFW (only SSH + Xray port open) and fail2ban for sshd
#   7. Enables BBR + fq congestion control, applies basic sysctl hardening
#   8. Schedules a daily reboot at midnight (server local time)
#   9. Prints a ready-to-import vless:// link + QR code
#
# Re-running (install or any --rotate mode) automatically backs up the
# previous config + client info under /root/xray-backups/<timestamp>/
# before making changes, so nothing is silently lost.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit if needed, or override via environment variables)
# ---------------------------------------------------------------------------
SNI_DOMAIN_DEFAULT="${SNI_DOMAIN:-i.ytimg.com}"   # REALITY camouflage target
LISTEN_PORT_DEFAULT="${LISTEN_PORT:-443}"         # Xray listen port
# Used as a fallback to install the 'reality' shortcut when this script is
# run via a process substitution / pipe (e.g. `bash <(curl -Ls ...)`),
# where $0 doesn't point to an actual file on disk. Override via env var
# if you're running a fork of this script from a different location.
SCRIPT_SOURCE_URL="${SCRIPT_SOURCE_URL:-https://raw.githubusercontent.com/davidbr5264/VLESS-TCP-XTLS-Vision-REALITY-automated-script/master/setup-xray-reality.sh}"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
STATE_FILE="${XRAY_CONFIG_DIR}/.reality-state"    # remembers settings between runs
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
  --restore)
    MODE="restore"
    RESTORE_TS="${2:-}"
    if [[ -z "$RESTORE_TS" ]]; then
      echo "ERROR: --restore requires a timestamp. See --list-backups for available ones." >&2
      exit 1
    fi
    ;;
  --help|-h)
    sed -n '2,38p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "ERROR: Unknown argument '$1'. Use --help for usage." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

if [[ "$MODE" != "install" ]] && ! command -v xray >/dev/null 2>&1; then
  echo "ERROR: Xray is not installed yet. Run the script with no arguments first." >&2
  exit 1
fi

if [[ "$MODE" == "install" ]] && ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: This script only supports Debian/Ubuntu (apt-based) systems." >&2
  exit 1
fi

# Fail with a clear message rather than a confusing mid-script error if
# there's not enough room for apt upgrades, Xray-core, and logs/backups.
if [[ "$MODE" == "install" ]]; then
  AVAILABLE_KB=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  MIN_REQUIRED_KB=1048576  # 1GB
  if [[ -n "$AVAILABLE_KB" ]] && [[ "$AVAILABLE_KB" -lt "$MIN_REQUIRED_KB" ]]; then
    echo "ERROR: Less than 1GB free on / (found $((AVAILABLE_KB / 1024))MB)." >&2
    echo "       apt upgrades, Xray-core, and logs need headroom to install safely." >&2
    echo "       Free up space first (e.g. 'apt autoremove --purge -y'), then re-run." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Load any previously saved state (SNI/port/keys), so rotate/show modes
# reuse the same settings instead of falling back to defaults.
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
fi

if [[ "$MODE" == "show" ]]; then
  if [[ -z "$UUID" || -z "$PUBLIC_KEY" ]]; then
    echo "ERROR: No saved state found (${STATE_FILE}). Run a full install first." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Helper: back up current config + client info before any change
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
    echo "Backed up previous config to: $backup_dir"

    # Keep only the most recent 15 backups so this directory doesn't grow
    # forever across years of periodic rotates/reinstalls.
    if [[ -d "$BACKUP_ROOT" ]]; then
      local backup_count
      backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
      if [[ "$backup_count" -gt 15 ]]; then
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((backup_count - 15))" | xargs -r rm -rf
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helper: generate UUID + short ID (used by install and --rotate-uuid)
# ---------------------------------------------------------------------------
generate_uuid_and_shortid() {
  UUID=$(xray uuid) || { echo "ERROR: 'xray uuid' command failed to run." >&2; exit 1; }
  SHORT_ID=$(openssl rand -hex 8)
  if [[ -z "$UUID" || -z "$SHORT_ID" ]]; then
    echo "ERROR: Failed to generate UUID or short ID." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: generate REALITY x25519 keypair (used by install and --rotate-all)
# Handles both old and new `xray x25519` CLI output formats:
#   Old: "Private key: xxx" / "Public key: xxx"
#   New: "PrivateKey: xxx"  / "Password (PublicKey): xxx" / "Hash32: xxx"
# ---------------------------------------------------------------------------
generate_reality_keypair() {
  local key_output
  key_output=$(xray x25519) || { echo "ERROR: 'xray x25519' command failed to run." >&2; exit 1; }

  PRIVATE_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Private ?[Kk]ey)[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  PUBLIC_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Public ?[Kk]ey|Password)([[:space:]]*\(.*\))?[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "ERROR: Failed to parse REALITY keypair." >&2
    echo "  PRIVATE_KEY=${PRIVATE_KEY:-<empty>}" >&2
    echo "  PUBLIC_KEY=${PUBLIC_KEY:-<empty>}" >&2
    echo "  Raw 'xray x25519' output was:" >&2
    echo "$key_output" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: write config.json from current UUID/keys/short ID
# ---------------------------------------------------------------------------
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
      "listen": "0.0.0.0",
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
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI_DOMAIN}:443",
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
      "tag": "block"
    }
  ],
  "routing": {
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
  # Fail fast with a clear message if the config we just wrote is malformed,
  # rather than letting it surface later as an opaque "service failed to
  # start" from systemd.
  if ! jq empty "$tmp_config" >/dev/null 2>&1; then
    echo "ERROR: Generated config.json is not valid JSON. Not restarting xray." >&2
    echo "  Broken draft left at ${tmp_config} for inspection." >&2
    echo "  Existing config (if any) at ${CONFIG_FILE} was left untouched." >&2
    exit 1
  fi

  # Atomic swap: rename is a single filesystem operation, so a crash here
  # never leaves a half-written config.json -- you get the old one or the
  # fully-written new one, never something in between.
  mv -f "$tmp_config" "$CONFIG_FILE"

  mkdir -p /var/log/xray
  chown -R xray:xray /var/log/xray 2>/dev/null || true

  # Config contains the REALITY private key -- restrict to root + the xray
  # service user rather than leaving it world-readable.
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: save state so future rotate/show runs remember settings
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: restart xray and confirm it came up healthy
# ---------------------------------------------------------------------------
restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "ERROR: xray service failed to start. Check: journalctl -u xray -e" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: build vless:// link, write client info file, print summary + QR
# ---------------------------------------------------------------------------
output_client_info() {
  local server_ip
  server_ip=$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://icanhazip.com 2>/dev/null || \
              true)
  server_ip=$(echo "$server_ip" | tr -d '[:space:]')

  if [[ -z "$server_ip" ]]; then
    echo "WARNING: Could not determine the server's public IP (all lookup services unreachable)." >&2
    echo "         Everything else succeeded -- find your IP manually (e.g. 'curl ifconfig.me' or" >&2
    echo "         your VPS provider's dashboard) and substitute it into the link below." >&2
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
Private Key   : ${PRIVATE_KEY}   (server-side only, keep secret)
Short ID      : ${SHORT_ID}
Fingerprint   : chrome

Client import link:
${vless_link}
========================================================================
Keep this file secret. It contains your private key.
EOF
  chmod 600 "$CLIENT_INFO_FILE"

  echo ""
  echo "############################################################"
  echo "  Service status : $(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo unknown)"
  echo "  Config file    : ${CONFIG_FILE}"
  echo "  Client info    : ${CLIENT_INFO_FILE} (chmod 600)"
  echo "############################################################"
  echo ""
  echo "Client link (import into v2rayN / NekoBox / Shadowrocket / etc.):"
  echo "${vless_link}"
  echo ""
  echo "QR code:"
  qrencode -t ansiutf8 "${vless_link}"
}

# ---------------------------------------------------------------------------
# MODE: --show  (read-only, no changes)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "show" ]]; then
  output_client_info
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --list-backups  (read-only, no changes)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list-backups" ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    exit 0
  fi
  echo "Available backups (use with --restore <timestamp>):"
  for dir in "$BACKUP_ROOT"/*/; do
    ts=$(basename "$dir")
    contents=$(ls "$dir" 2>/dev/null | tr '\n' ' ')
    echo "  ${ts}   (${contents})"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --restore <timestamp>  (restore config + state from a prior backup)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "restore" ]]; then
  RESTORE_DIR="${BACKUP_ROOT}/${RESTORE_TS}"
  if [[ ! -d "$RESTORE_DIR" ]]; then
    echo "ERROR: No backup found at ${RESTORE_DIR}." >&2
    echo "       Run --list-backups to see available timestamps." >&2
    exit 1
  fi
  if [[ ! -f "${RESTORE_DIR}/config.json" ]]; then
    echo "ERROR: ${RESTORE_DIR} doesn't contain a config.json -- can't restore from it." >&2
    exit 1
  fi

  echo "=== Restoring from backup: ${RESTORE_TS} ==="
  # Back up the current (about-to-be-overwritten) state too, so restoring
  # is itself undoable.
  backup_current_state

  if ! jq empty "${RESTORE_DIR}/config.json" >/dev/null 2>&1; then
    echo "ERROR: Backed-up config.json at ${RESTORE_DIR} is not valid JSON. Not restoring." >&2
    exit 1
  fi

  cp -a "${RESTORE_DIR}/config.json" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  [[ -f "${RESTORE_DIR}/state" ]] && cp -a "${RESTORE_DIR}/state" "$STATE_FILE" && chmod 600 "$STATE_FILE"
  [[ -f "${RESTORE_DIR}/client-info.txt" ]] && cp -a "${RESTORE_DIR}/client-info.txt" "$CLIENT_INFO_FILE" && chmod 600 "$CLIENT_INFO_FILE"

  restart_and_verify
  echo ""
  echo "Restored from ${RESTORE_TS}. Run --show to reprint the restored client link."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --rotate-uuid  (new UUID + short ID; keeps REALITY keypair)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "rotate-uuid" ]]; then
  echo "=== Rotating UUID + short ID (REALITY keypair unchanged) ==="
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "ERROR: No existing REALITY keypair found in state. Run a full install first." >&2
    exit 1
  fi
  backup_current_state
  generate_uuid_and_shortid
  write_config
  save_state
  output_client_info
  restart_and_verify
  echo ""
  echo "Old client link is now invalid. Any device using it must import the new link above."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --rotate-all  (new UUID + short ID + REALITY keypair)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "rotate-all" ]]; then
  echo "=== Rotating ALL credentials (UUID, short ID, REALITY keypair) ==="
  backup_current_state
  generate_uuid_and_shortid
  generate_reality_keypair
  write_config
  save_state
  output_client_info
  restart_and_verify
  echo ""
  echo "All previous client links are now permanently invalid."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: install (default) — full setup, safe to re-run
# ---------------------------------------------------------------------------
backup_current_state

echo "=== [1/9] Preparing server (updates, cleanup, essential tools) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y --purge
apt-get autoclean -y

# Packages this script actually depends on -- install must succeed.
apt-get install -y \
  curl wget unzip jq openssl qrencode ufw fail2ban ca-certificates

# "Nice to have" base tools some environments are missing by default.
# Not required by anything below, so a missing package here (package
# names/availability vary across Debian/Ubuntu versions and minimal
# cloud images) should warn, not abort the whole install.
apt-get install -y gnupg lsb-release apt-transport-https logrotate || \
  echo "NOTE: one or more optional packages (gnupg/lsb-release/apt-transport-https/logrotate) were unavailable; continuing anyway, they aren't required."

if [[ -f /var/run/reboot-required ]]; then
  echo "NOTE: A previous update marked this system as needing a reboot."
  echo "      The daily reboot timer set up later in this script will handle it,"
  echo "      or reboot manually now with: reboot"
fi

echo "=== [2/9] Installing Xray-core (official installer) ==="
XRAY_INSTALL_ATTEMPTS=3
for attempt in $(seq 1 "$XRAY_INSTALL_ATTEMPTS"); do
  if bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install; then
    break
  fi
  if [[ "$attempt" -eq "$XRAY_INSTALL_ATTEMPTS" ]]; then
    echo "ERROR: Failed to install Xray-core after ${XRAY_INSTALL_ATTEMPTS} attempts (likely a network issue reaching GitHub)." >&2
    exit 1
  fi
  echo "Xray-core install attempt ${attempt} failed, retrying in 5s..."
  sleep 5
done

mkdir -p "$XRAY_CONFIG_DIR"

echo "=== [3/9] Setting up credentials (UUID, REALITY keypair, short ID) ==="
if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
  echo "Existing credentials found in ${STATE_FILE} -- reusing them (client links stay valid)."
  echo "Need fresh credentials instead? Use --rotate-uuid or --rotate-all, not a plain re-run."
else
  echo "No existing credentials found -- generating new ones (first-time install)."
  generate_uuid_and_shortid
  generate_reality_keypair
fi

# Dedicated unprivileged system account for the xray service to run as
# (see step 5 below). Created here, before write_config, so the config
# file's ownership can be set correctly on first install.
if ! id -u xray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin xray
fi

echo "=== [4/9] Writing Xray config (privacy-minded: no access logging) ==="
write_config

echo "=== [5/9] Hardening the systemd service ==="
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<'EOF'
[Service]
User=xray
Group=xray
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5
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

# Reload the unit + drop-in now so the change is registered, but hold off
# on actually restarting until every other step below has succeeded --
# see the single restart_and_verify call at the very end of install mode.
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true

echo "=== [6/9] Configuring firewall (UFW) ==="
SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1)
SSH_PORT="${SSH_PORT:-22}"

# Make sure UFW actually enforces IPv6 too -- if IPV6=no here, the rules
# below only apply to IPv4 and a public IPv6 address (common on many VPS
# providers by default) would be left completely unfiltered.
if [[ -f /etc/default/ufw ]] && grep -qE '^IPV6=no' /etc/default/ufw; then
  sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
  echo "Enabled IPv6 support in UFW (was disabled; would have left IPv6 unfiltered)."
fi

# Pin the default policy explicitly rather than relying on whatever the
# base image shipped with.
ufw default deny incoming
ufw default allow outgoing

# These two rules are load-bearing (lose either one and you either can't
# SSH in or the proxy stops working), so a failure here should stop the
# script rather than be silently swallowed.
if ! ufw allow "${SSH_PORT}"/tcp comment 'SSH'; then
  echo "ERROR: Failed to add UFW rule for SSH port ${SSH_PORT}. Not enabling the firewall." >&2
  echo "       Fix manually, then re-run: ufw allow ${SSH_PORT}/tcp && ufw --force enable" >&2
  exit 1
fi
if ! ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY'; then
  echo "ERROR: Failed to add UFW rule for Xray port ${LISTEN_PORT}. Not enabling the firewall." >&2
  exit 1
fi

ufw --force enable
ufw reload

echo "=== [7/9] Configuring fail2ban for SSH brute-force protection ==="
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo "=== [8/9] Enabling BBR + basic kernel/network hardening ==="
cat > /etc/sysctl.d/99-xray-hardening.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Basic network hardening (.all applies to existing interfaces, .default
# applies to interfaces that come up after this is set)
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

# Restrict ptrace to direct child processes only -- blunts a class of
# local privilege escalation via one process attaching a debugger to another
kernel.yama.ptrace_scope = 1
EOF
sysctl --system >/dev/null

# Cap the systemd journal's disk usage explicitly rather than trusting
# whatever default the base image shipped with.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-xray-hardening.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald

# Prevent /var/log/xray/error.log from growing unbounded on a long-lived box.
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

echo "=== [9/9] Setting up daily reboot at midnight ==="
cat > /etc/systemd/system/daily-reboot.service <<'EOF'
[Unit]
Description=Daily scheduled reboot

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r now "Scheduled daily reboot"
EOF

cat > /etc/systemd/system/daily-reboot.timer <<'EOF'
[Unit]
Description=Daily reboot at midnight

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now daily-reboot.timer

# Install a short-name copy so this script can be run as 'reality' from
# anywhere, instead of needing to remember/find the original file path.
# Copies the content (not a symlink), so it keeps working even if the
# original downloaded copy is moved or deleted.
#
# Install a short-name copy so this script can be run as 'reality' from
# anywhere, instead of needing to remember/find the original file path.
# Copies the content (not a symlink), so it keeps working even if the
# original downloaded copy is moved or deleted.
#
# If $0 isn't a real file (e.g. run via `bash <(curl -Ls ...)`, where $0
# points to a process-substitution pipe, not a regular file), fall back
# to re-downloading the script fresh from SCRIPT_SOURCE_URL instead.
REALITY_SHORTCUT="/usr/local/bin/reality"
SELF_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
REALITY_SHORTCUT_RESOLVED=$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")

if [[ "$SELF_PATH" == "$REALITY_SHORTCUT_RESOLVED" ]]; then
  # Already running as the installed shortcut -- nothing to copy onto itself.
  chmod +x "$REALITY_SHORTCUT" 2>/dev/null || true
elif [[ -f "$SELF_PATH" ]]; then
  cp -f "$SELF_PATH" "$REALITY_SHORTCUT"
  chmod +x "$REALITY_SHORTCUT"
else
  REALITY_SHORTCUT_TMP=$(mktemp)
  if curl -fsSL --connect-timeout 10 --max-time 30 "$SCRIPT_SOURCE_URL" -o "$REALITY_SHORTCUT_TMP" 2>/dev/null \
     && bash -n "$REALITY_SHORTCUT_TMP" 2>/dev/null; then
    # Only install it once we've confirmed the download is complete and
    # syntactically valid -- a truncated/partial download would otherwise
    # silently replace a working shortcut with a broken one.
    mv -f "$REALITY_SHORTCUT_TMP" "$REALITY_SHORTCUT"
    chmod +x "$REALITY_SHORTCUT"
  else
    rm -f "$REALITY_SHORTCUT_TMP"
    echo "WARNING: Could not install the 'reality' shortcut (this run wasn't from a" >&2
    echo "         real file on disk, e.g. 'bash <(curl ...)', and re-downloading" >&2
    echo "         from ${SCRIPT_SOURCE_URL} also failed or returned an incomplete file)." >&2
    echo "         Everything else succeeded -- to add the shortcut manually:" >&2
    echo "           curl -fsSL ${SCRIPT_SOURCE_URL} -o ${REALITY_SHORTCUT} && chmod +x ${REALITY_SHORTCUT}" >&2
  fi
fi

# Everything above (config, firewall, fail2ban, sysctl, reboot timer) is
# now in place. Print the client link/QR and all summary info first, and
# restart xray as the literal last action of the whole script.
save_state
output_client_info

echo ""
echo "Setup complete. Server will reboot daily at 00:00 (server local time)."
echo "Check timezone with: timedatectl   (change with: timedatectl set-timezone <Region/City>)"
echo "Cancel the daily reboot with: systemctl disable --now daily-reboot.timer"
echo ""
echo "Re-run any time (works via either name, from any directory):"
echo "  reality                 -> re-apply full setup (backs up old config first)"
echo "  reality --rotate-uuid   -> revoke current client link, keep server identity"
echo "  reality --rotate-all    -> full credential reset (invalidates everything)"
echo "  reality --show          -> reprint current client link + QR"

echo ""
echo "=== Restarting Xray with final configuration ==="
restart_and_verify
