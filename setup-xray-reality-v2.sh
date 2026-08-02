#!/usr/bin/env bash
#
# setup-xray-reality.sh
# One-click installer for VLESS + TCP + XTLS-Vision + REALITY on a fresh Linux VPS.
# Based on the official XTLS docs: https://xtls.github.io/en/ and
# https://github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-XTLS-Vision-REALITY
#
# Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/<you>/<repo>/master/setup-xray-reality.sh)
#
set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
#  Aesthetics: colours, symbols, spinner
# ────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
CHECK="${GREEN}✔${NC}"; CROSS="${RED}✘${NC}"; ARROW="${CYAN}➜${NC}"

banner() {
  echo -e "${CYAN}${BOLD}"
  cat <<'EOF'
__   ___     ___ ___ ___    ____                _ _ _
\ \ / / |   | __/ __/ __|  |  _ \ ___  __ _ _  _(_) |_ _  _
 \ V /| |__ | _|\__ \__ \  | |_) / -_)/ _` | || | |  _| || |
  \_/ |____||___|___/___/  |_.__/\___|\__,_|\_,_|_|\__|\_, |
                                                        |__/
        VLESS · TCP · XTLS-Vision · REALITY  —  one-click setup
EOF
  echo -e "${NC}"
}

log()   { echo -e "${ARROW} $*"; }
ok()    { echo -e "${CHECK} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${CROSS} $*" >&2; }
die()   { err "$*"; exit 1; }

SPINNER_PID=""
spinner_start() {
  local msg="$1"
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  ( while true; do
      for ((i=0; i<${#frames}; i++)); do
        printf "\r${CYAN}%s${NC} %s " "${frames:$i:1}" "$msg"
        sleep 0.08
      done
    done ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}
spinner_stop() {
  local status="${1:-0}" msg="${2:-}"
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf "\r\033[K"
  if [[ "$status" -eq 0 ]]; then ok "$msg"; else err "$msg"; fi
}
run() {
  # run <description> <command...>
  local desc="$1"; shift
  spinner_start "$desc"
  local out
  if out=$("$@" 2>&1); then
    spinner_stop 0 "$desc"
  else
    spinner_stop 1 "$desc"
    echo -e "${DIM}${out}${NC}"
    die "Command failed: $*"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  Pre-flight checks
# ────────────────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo bash ...)."
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect OS (missing /etc/os-release)."
  fi

  if [[ "$OS_ID" =~ ^(debian|ubuntu)$ ]] || [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then
    PKG_MANAGER="apt"
  elif [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux|fedora)$ ]] || [[ "$OS_LIKE" =~ (rhel|fedora) ]]; then
    PKG_MANAGER="dnf"
    command -v dnf >/dev/null 2>&1 || PKG_MANAGER="yum"
  else
    die "Unsupported distro: $OS_ID. This script supports Debian/Ubuntu and RHEL-family only."
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   ARCH="64" ;;
    aarch64|arm64)  ARCH="arm64-v8a" ;;
    armv7l)         ARCH="arm32-v7a" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# ────────────────────────────────────────────────────────────────────────────
#  Dependencies
# ────────────────────────────────────────────────────────────────────────────
install_deps() {
  local pkgs=(curl wget unzip tar jq openssl qrencode)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    run "Updating package index"     apt-get update -y
    run "Installing dependencies"    apt-get install -y "${pkgs[@]}" ufw cron
  else
    run "Installing dependencies"    "$PKG_MANAGER" install -y "${pkgs[@]}" firewalld cronie
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  User input
# ────────────────────────────────────────────────────────────────────────────
DEFAULT_SNI="i.ytimg.com"
DEFAULT_PORT="443"

prompt_inputs() {
  echo
  echo -e "${BOLD}Configuration${NC}"
  echo -e "${DIM}Press Enter to accept the default shown in [brackets].${NC}"
  echo

  read -rp "$(echo -e "${ARROW} SNI / camouflage domain [${DEFAULT_SNI}]: ")" SNI
  SNI="${SNI:-$DEFAULT_SNI}"

  # Basic sanity check on the SNI: must resolve and speak TLS1.3 on 443.
  spinner_start "Validating that ${SNI} supports TLS 1.3"
  if echo | openssl s_client -connect "${SNI}:443" -tls1_3 -servername "${SNI}" 2>/dev/null | grep -q "TLSv1.3"; then
    spinner_stop 0 "${SNI} supports TLS 1.3 — good camouflage candidate"
  else
    spinner_stop 1 "Could not confirm TLS 1.3 support for ${SNI}"
    warn "Continuing anyway — REALITY may still work, but pick a well-known TLS1.3/H2 site if issues occur."
  fi

  read -rp "$(echo -e "${ARROW} Xray listening port [${DEFAULT_PORT}]: ")" XPORT
  XPORT="${XPORT:-$DEFAULT_PORT}"
  [[ "$XPORT" =~ ^[0-9]+$ && "$XPORT" -ge 1 && "$XPORT" -le 65535 ]] || die "Invalid port: $XPORT"

  read -rp "$(echo -e "${ARROW} Client-visible remark/tag [VLESS-REALITY]: ")" REMARK
  REMARK="${REMARK:-VLESS-REALITY}"

  echo
}

# ────────────────────────────────────────────────────────────────────────────
#  Xray-core install (official installer)
# ────────────────────────────────────────────────────────────────────────────
install_xray() {
  spinner_start "Downloading & installing latest Xray-core (official script)"
  if OUT=$(bash -c "$(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install 2>&1); then
    spinner_stop 0 "Xray-core installed"
  else
    spinner_stop 1 "Xray-core installation failed"
    echo -e "${DIM}${OUT}${NC}"
    die "Aborting."
  fi

  command -v xray >/dev/null 2>&1 || die "xray binary not found after installation."
  XRAY_VERSION=$(xray version | head -n1)
  ok "Installed: ${XRAY_VERSION}"
}

# ────────────────────────────────────────────────────────────────────────────
#  Credential generation
# ────────────────────────────────────────────────────────────────────────────
generate_credentials() {
  spinner_start "Generating UUID, x25519 keypair, and short ID"

  UUID=$(xray uuid)

  # xray x25519 output format: "Private key: xxx" / "Public key: xxx"
  # (older builds: "PrivateKey:" / "Password:") — handle both.
  local keys
  keys=$(xray x25519)
  PRIVATE_KEY=$(echo "$keys" | grep -iE "private ?key" | awk -F': ' '{print $2}' | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$keys" | grep -iE "public ?key|password" | awk -F': ' '{print $2}' | tr -d '[:space:]')

  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { spinner_stop 1 "Key generation failed"; die "Could not parse xray x25519 output:\n$keys"; }

  SHORT_ID=$(openssl rand -hex 8)

  spinner_stop 0 "Credentials generated"
}

# ────────────────────────────────────────────────────────────────────────────
#  Server config
# ────────────────────────────────────────────────────────────────────────────
write_config() {
  spinner_start "Writing hardened Xray server configuration"

  mkdir -p /usr/local/etc/xray
  BACKUP_DIR="/usr/local/etc/xray/backup"
  if [[ -f /usr/local/etc/xray/config.json ]]; then
    mkdir -p "$BACKUP_DIR"
    cp /usr/local/etc/xray/config.json "${BACKUP_DIR}/config.json.$(date +%s).bak"
  fi

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XPORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "user1@${SNI}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

  # Validate the config with xray itself before touching the running service.
  if ! xray run -test -config /usr/local/etc/xray/config.json >/tmp/xray-test.log 2>&1; then
    spinner_stop 1 "Config validation failed"
    cat /tmp/xray-test.log
    die "Generated config.json is invalid — aborting before starting the service."
  fi

  spinner_stop 0 "Configuration written and validated"
}

# ────────────────────────────────────────────────────────────────────────────
#  systemd hardening
# ────────────────────────────────────────────────────────────────────────────
harden_systemd() {
  spinner_start "Hardening systemd service"
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
# Allow binding to privileged ports without running fully as root's
# broader capability set.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/etc/xray /var/log/xray
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3
EOF
  mkdir -p /var/log/xray
  systemctl daemon-reload
  spinner_stop 0 "systemd service hardened"
}

enable_start_service() {
  run "Enabling Xray to start on boot"  systemctl enable xray
  run "Starting Xray service"           systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || { journalctl -u xray -n 40 --no-pager; die "Xray failed to start — see log above."; }
  ok "Xray is running"
}

# ────────────────────────────────────────────────────────────────────────────
#  Firewall
# ────────────────────────────────────────────────────────────────────────────
configure_firewall() {
  local ssh_port
  ssh_port=$(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | head -n1 | tr -d ':')
  ssh_port="${ssh_port:-22}"

  if command -v ufw >/dev/null 2>&1; then
    spinner_start "Configuring ufw firewall (default-deny inbound)"
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw limit "${ssh_port}/tcp" comment "SSH (rate-limited)" >/dev/null
    ufw allow "${XPORT}/tcp" comment "Xray REALITY" >/dev/null
    ufw --force enable >/dev/null
    spinner_stop 0 "ufw enabled — only SSH(${ssh_port}) and ${XPORT}/tcp are open"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    spinner_start "Configuring firewalld"
    systemctl enable --now firewalld >/dev/null 2>&1
    firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${XPORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    spinner_stop 0 "firewalld enabled — SSH(${ssh_port}) and ${XPORT}/tcp are open"
  else
    warn "No supported firewall manager found — skipping firewall configuration."
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  Kernel / network tuning (BBR)
# ────────────────────────────────────────────────────────────────────────────
enable_bbr() {
  spinner_start "Enabling TCP BBR congestion control"
  if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null; then
    {
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    } >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    spinner_stop 0 "BBR enabled"
  else
    spinner_stop 0 "BBR requested (kernel may need reboot to confirm)"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  Auto-renew / unattended security updates (server-security priority)
# ────────────────────────────────────────────────────────────────────────────
enable_unattended_upgrades() {
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    spinner_start "Enabling unattended security updates"
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null 2>&1 || true
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    spinner_stop 0 "Unattended security updates enabled"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  Output: client link + QR
# ────────────────────────────────────────────────────────────────────────────
print_summary() {
  local server_ip
  server_ip=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s6 --max-time 5 https://api64.ipify.org || echo "YOUR_SERVER_IP")

  local link="vless://${UUID}@${server_ip}:${XPORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${REMARK// /_}"

  echo
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD} Installation complete${NC}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo
  printf "  %-16s %s\n" "Server IP:"    "${server_ip}"
  printf "  %-16s %s\n" "Port:"         "${XPORT}"
  printf "  %-16s %s\n" "UUID:"         "${UUID}"
  printf "  %-16s %s\n" "Flow:"         "xtls-rprx-vision"
  printf "  %-16s %s\n" "SNI:"          "${SNI}"
  printf "  %-16s %s\n" "Public key:"   "${PUBLIC_KEY}"
  printf "  %-16s %s\n" "Short ID:"     "${SHORT_ID}"
  printf "  %-16s %s\n" "Fingerprint:"  "chrome"
  printf "  %-16s %s\n" "Network:"      "tcp"
  echo
  echo -e "  ${BOLD}Client import link:${NC}"
  echo -e "  ${CYAN}${link}${NC}"
  echo

  if command -v qrencode >/dev/null 2>&1; then
    echo -e "  ${BOLD}Scan to import (v2rayNG / Shadowrocket / NekoBox / etc.):${NC}"
    qrencode -t ANSIUTF8 "${link}"
    echo
  fi

  echo "${link}" > /usr/local/etc/xray/client-link.txt
  cat > /usr/local/etc/xray/client-info.json <<EOF
{
  "server": "${server_ip}",
  "port": ${XPORT},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "sni": "${SNI}",
  "publicKey": "${PUBLIC_KEY}",
  "shortId": "${SHORT_ID}",
  "fingerprint": "chrome",
  "link": "${link}"
}
EOF
  ok "Saved to /usr/local/etc/xray/client-info.json and client-link.txt"

  echo
  echo -e "  ${DIM}Manage the service with: systemctl {status|restart|stop} xray${NC}"
  echo -e "  ${DIM}Config file:              /usr/local/etc/xray/config.json${NC}"
  echo -e "  ${DIM}Logs:                     journalctl -u xray -f${NC}"
  echo
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
}

# ────────────────────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────────────────────
main() {
  banner
  require_root
  detect_os
  detect_arch
  install_deps
  prompt_inputs
  install_xray
  generate_credentials
  write_config
  harden_systemd
  enable_start_service
  configure_firewall
  enable_bbr
  enable_unattended_upgrades
  print_summary
}

main "$@"
