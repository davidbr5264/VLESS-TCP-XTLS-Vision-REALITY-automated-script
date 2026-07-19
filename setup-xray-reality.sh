#!/usr/bin/env bash
#
# setup-xray-reality.sh
#
# Automated installer for a hardened Xray VLESS-TCP-XTLS-Vision-REALITY
# instance on a Debian/Ubuntu VPS, for personal use.
#
# What this does:
#   1. Installs latest official Xray-core (XTLS/Xray-install)
#   2. Generates UUID, REALITY x25519 keypair, and a short ID
#   3. Writes a minimal-logging config.json (VLESS + TCP + XTLS-Vision + REALITY)
#   4. Camouflages as: i.ytimg.com   (real TLS1.3 site used as REALITY target)
#   5. Locks the systemd unit down (NoNewPrivileges, ProtectSystem, etc.)
#   6. Configures UFW (only SSH + Xray port open) and fail2ban for sshd
#   7. Enables BBR + fq congestion control, applies basic sysctl hardening
#   8. Prints a ready-to-import vless:// link + QR code
#
# Run as root on a fresh Debian 11/12 or Ubuntu 20.04/22.04/24.04 VPS:
#   chmod +x setup-xray-reality.sh
#   ./setup-xray-reality.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit if needed, or override via environment variables)
# ---------------------------------------------------------------------------
SNI_DOMAIN="${SNI_DOMAIN:-i.ytimg.com}"      # REALITY camouflage target
LISTEN_PORT="${LISTEN_PORT:-443}"            # Xray listen port
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CLIENT_INFO_FILE="/root/xray-client-info.txt"
SERVICE_NAME="xray"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: This script only supports Debian/Ubuntu (apt-based) systems." >&2
  exit 1
fi

echo "=== [1/9] Updating system packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "=== [2/9] Installing dependencies ==="
apt-get install -y curl wget unzip jq openssl qrencode ufw fail2ban ca-certificates

echo "=== [3/9] Installing Xray-core (official installer) ==="
bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install

mkdir -p "$XRAY_CONFIG_DIR"

echo "=== [4/9] Generating credentials (UUID, REALITY keypair, short ID) ==="
UUID=$(xray uuid)
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/Private key:/ {print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/Public key:/ {print $3}')
SHORT_ID=$(openssl rand -hex 8)

if [[ -z "$UUID" || -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
  echo "ERROR: Failed to generate one or more credentials." >&2
  exit 1
fi

echo "=== [5/9] Writing Xray config (privacy-minded: no access logging) ==="
cat > "${XRAY_CONFIG_DIR}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
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
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray 2>/dev/null || true

echo "=== [6/9] Hardening the systemd service ==="
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
cat > /etc/systemd/system/${SERVICE_NAME}.service.d/override.conf <<'EOF'
[Service]
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

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

sleep 1
if ! systemctl is-active --quiet ${SERVICE_NAME}; then
  echo "ERROR: xray service failed to start. Check: journalctl -u xray -e" >&2
  exit 1
fi

echo "=== [7/9] Configuring firewall (UFW) ==="
SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1)
SSH_PORT="${SSH_PORT:-22}"
ufw allow "${SSH_PORT}"/tcp comment 'SSH' || true
ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY' || true
ufw --force enable
ufw reload

echo "=== [8/9] Configuring fail2ban for SSH brute-force protection ==="
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

echo "=== [9/9] Enabling BBR + basic kernel/network hardening ==="
cat > /etc/sysctl.d/99-xray-hardening.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Basic network hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# Output client connection info
# ---------------------------------------------------------------------------
SERVER_IP=$(curl -fsSL -4 https://ifconfig.me || curl -fsSL -4 https://api.ipify.org)

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision&spx=%2F#xray-reality-$(hostname)"

cat > "$CLIENT_INFO_FILE" <<EOF
================= Xray VLESS-TCP-XTLS-Vision-REALITY =================
Server IP     : ${SERVER_IP}
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
${VLESS_LINK}
========================================================================
Keep this file secret. It contains your private key.
EOF
chmod 600 "$CLIENT_INFO_FILE"

echo ""
echo "############################################################"
echo "  Xray REALITY setup complete."
echo "  Service status : $(systemctl is-active ${SERVICE_NAME})"
echo "  Config file     : ${XRAY_CONFIG_DIR}/config.json"
echo "  Client info     : ${CLIENT_INFO_FILE} (chmod 600)"
echo "############################################################"
echo ""
echo "Client link (import into v2rayN / NekoBox / Shadowrocket / etc.):"
echo "${VLESS_LINK}"
echo ""
echo "QR code:"
qrencode -t ansiutf8 "${VLESS_LINK}"
