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
#  Transcript logging (plain-text, ANSI-stripped) for post-install debugging
# ────────────────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/xray-install.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"  # fall back quietly if unwritable (e.g. not root yet)

log_to_file() {
  local clean
  clean=$(printf '%s' "$*" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' 2>/dev/null || printf '%s' "$*")
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$clean" >> "$LOG_FILE" 2>/dev/null || true
}

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

log()   { echo -e "${ARROW} $*"; log_to_file "-> $*"; }
ok()    { echo -e "${CHECK} $*"; log_to_file "OK   $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; log_to_file "WARN $*"; }
err()   { echo -e "${CROSS} $*" >&2; log_to_file "ERR  $*"; }
die()   { err "$*"; exit 1; }

SPINNER_PID=""
cleanup_on_exit() {
  local ec=$?
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
  exit "$ec"
}
trap cleanup_on_exit EXIT
trap 'die "Interrupted."' INT TERM

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
    log_to_file "CMD  $* -> OK"
  else
    spinner_stop 1 "$desc"
    echo -e "${DIM}${out}${NC}"
    log_to_file "CMD  $* -> FAILED. Output: ${out}"
    die "Command failed: $*"
  fi
}

retry() {
  # retry <max_attempts> <command...>
  local max="$1"; shift
  local n=1 delay=2
  until "$@"; do
    if (( n >= max )); then
      return 1
    fi
    sleep "$delay"
    ((n++)); ((delay*=2))
  done
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
#  Idempotency: detect an existing install and offer a lighter-weight path
# ────────────────────────────────────────────────────────────────────────────
detect_existing_install() {
  EXISTING_INSTALL=0
  if command -v xray >/dev/null 2>&1 && [[ -f /usr/local/etc/xray/config.json ]]; then
    EXISTING_INSTALL=1
  fi
}

offer_mode_selection() {
  if [[ "$EXISTING_INSTALL" -ne 1 ]]; then
    MODE="reprovision"
    return 0
  fi

  warn "An existing Xray installation was found at /usr/local/etc/xray/config.json."

  if [[ -n "${XRAY_MODE:-}" ]]; then
    MODE="$XRAY_MODE"
    log "Using mode from XRAY_MODE: ${MODE}"
  elif [[ -t 0 ]]; then
    echo
    echo -e "  ${BOLD}1)${NC} Rotate credentials only — keep the existing SNI/port/firewall/systemd setup, generate a fresh UUID + x25519 keypair + short ID, restart Xray. Fast, minimal disruption."
    echo -e "  ${BOLD}2)${NC} Full reprovision        — reinstall Xray-core, re-prompt for SNI/port, redo firewall + systemd hardening + BBR. Use after a distro upgrade or if something looks broken."
    echo
    read -rp "$(echo -e "${ARROW} Choose [1/2, default 1]: ")" mode_choice
    case "${mode_choice:-1}" in
      2) MODE="reprovision" ;;
      *) MODE="rotate" ;;
    esac
  else
    MODE="rotate"
    warn "Non-interactive session — defaulting to credential rotation only. Set XRAY_MODE=reprovision to force a full reinstall."
  fi
}

rotate_credentials_only() {
  log "Rotating credentials — existing SNI, port, firewall, and systemd config are left untouched."

  command -v jq >/dev/null 2>&1 || die "jq is required to read the existing config for rotation but isn't installed. Re-run with XRAY_MODE=reprovision."

  SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' /usr/local/etc/xray/config.json 2>/dev/null || true)
  XPORT=$(jq -r '.inbounds[0].port // empty' /usr/local/etc/xray/config.json 2>/dev/null || true)
  [[ -n "$SNI" && -n "$XPORT" ]] || die "Could not read SNI/port from the existing config.json (unexpected format) — re-run with XRAY_MODE=reprovision to rebuild it from scratch."

  REMARK=""
  if [[ -f /usr/local/etc/xray/client-info.json ]]; then
    REMARK=$(jq -r '.link // empty' /usr/local/etc/xray/client-info.json 2>/dev/null | grep -oE '#[^&]*$' | tr -d '#' || true)
  fi
  REMARK="${REMARK:-VLESS-REALITY}"

  generate_credentials
  write_config
  run "Restarting Xray with rotated credentials" systemctl restart xray
  systemctl is-active --quiet xray || { journalctl -u xray -n 40 --no-pager; die "Xray failed to restart after rotation — see log above."; }
  ok "Xray restarted with rotated credentials"
}

# ────────────────────────────────────────────────────────────────────────────
#  Dependencies
# ────────────────────────────────────────────────────────────────────────────
install_deps() {
  local pkgs=(curl wget unzip tar jq openssl)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    run "Updating package index"     retry 3 apt-get update -y
    run "Installing dependencies"    apt-get install -y "${pkgs[@]}" ufw cron qrencode
  else
    run "Refreshing package metadata" retry 3 "$PKG_MANAGER" makecache -y
    # qrencode lives in EPEL on RHEL-family distros, not the base repos.
    "$PKG_MANAGER" install -y epel-release >/dev/null 2>&1 || true
    run "Installing dependencies"    "$PKG_MANAGER" install -y "${pkgs[@]}" firewalld cronie
    # QR display is a nice-to-have, not worth aborting the whole install over.
    "$PKG_MANAGER" install -y qrencode >/dev/null 2>&1 \
      || warn "qrencode unavailable (EPEL may not be enabled) — the client link will still be printed as text."
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
  echo -e "${DIM}Press Enter to accept the default shown in [brackets]. Set XRAY_SNI / XRAY_PORT / XRAY_REMARK env vars to run non-interactively.${NC}"
  echo

  if [[ -n "${XRAY_SNI:-}" ]]; then
    SNI="$XRAY_SNI"
    log "Using SNI from XRAY_SNI: ${SNI}"
  else
    read -rp "$(echo -e "${ARROW} SNI / camouflage domain [${DEFAULT_SNI}]: ")" SNI
    SNI="${SNI:-$DEFAULT_SNI}"
  fi

  # Basic sanity check on the SNI: must resolve and speak TLS1.3 on 443.
  # `timeout` guards against s_client hanging forever on a filtered/unreachable host.
  spinner_start "Validating that ${SNI} supports TLS 1.3"
  if echo | timeout 8 openssl s_client -connect "${SNI}:443" -tls1_3 -servername "${SNI}" 2>/dev/null | grep -q "TLSv1.3"; then
    spinner_stop 0 "${SNI} supports TLS 1.3 — good camouflage candidate"
  else
    spinner_stop 1 "Could not confirm TLS 1.3 support for ${SNI}"
    warn "Continuing anyway — REALITY may still work, but pick a well-known TLS1.3/H2 site if issues occur."
  fi

  if [[ -n "${XRAY_PORT:-}" ]]; then
    XPORT="$XRAY_PORT"
    log "Using port from XRAY_PORT: ${XPORT}"
  else
    read -rp "$(echo -e "${ARROW} Xray listening port [${DEFAULT_PORT}]: ")" XPORT
    XPORT="${XPORT:-$DEFAULT_PORT}"
  fi
  [[ "$XPORT" =~ ^[0-9]+$ && "$XPORT" -ge 1 && "$XPORT" -le 65535 ]] || die "Invalid port: $XPORT"

  # Guard against locking yourself out of the box.
  local current_ssh_port
  current_ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); if (n>0) print a[n]; exit}')
  current_ssh_port="${current_ssh_port:-22}"
  if [[ "$XPORT" == "$current_ssh_port" ]]; then
    die "Port ${XPORT} is also your active SSH port (${current_ssh_port}) — choose a different Xray port to avoid locking yourself out."
  fi

  # Warn early if something is already listening on the chosen port, rather
  # than failing late inside systemd with a confusing journalctl dump.
  if ss -tln 2>/dev/null | awk -v p=":${XPORT}\$" '$4 ~ p {found=1} END{exit !found}'; then
    warn "Something is already listening on port ${XPORT}. Xray will fail to start unless that service is stopped first."
  fi

  if [[ -n "${XRAY_REMARK:-}" ]]; then
    REMARK="$XRAY_REMARK"
  else
    read -rp "$(echo -e "${ARROW} Client-visible remark/tag [VLESS-REALITY]: ")" REMARK
    REMARK="${REMARK:-VLESS-REALITY}"
  fi
  # Strip anything that isn't safe unescaped inside a URI fragment, so a
  # stray & # % etc. in the remark can't corrupt the generated vless:// link.
  REMARK=$(printf '%s' "$REMARK" | tr -c 'A-Za-z0-9 _.-' '_')
  REMARK="${REMARK// /_}"

  echo
}

# ────────────────────────────────────────────────────────────────────────────
#  Xray-core install (official installer)
# ────────────────────────────────────────────────────────────────────────────
install_xray() {
  local installer_tmp
  installer_tmp=$(mktemp)
  # Ensure the temp file (and nothing else) is cleaned up even if the script
  # exits before we get to remove it further down.
  trap 'rm -f "$installer_tmp"; cleanup_on_exit' EXIT

  # Two independent CDN paths to the same official script: if GitHub's raw
  # host is down, rate-limited, or blocked by the VPS's network policy, the
  # jsdelivr mirror serves the identical content from a different network.
  # We deliberately still run the *official* upstream script rather than
  # hand-rolling a manual binary/systemd install — that keeps us in lockstep
  # with upstream's own install logic (geoip/geosite assets, service user,
  # directory layout) instead of maintaining a second, divergence-prone copy.
  local primary_url="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
  local mirror_url="https://cdn.jsdelivr.net/gh/XTLS/Xray-install@main/install-release.sh"

  spinner_start "Downloading Xray-install script"
  if retry 3 curl -Ls -o "$installer_tmp" "$primary_url" && [[ -s "$installer_tmp" ]] && grep -q "Xray" "$installer_tmp"; then
    spinner_stop 0 "Xray-install script downloaded"
  else
    spinner_stop 1 "Primary source unreachable — trying mirror"
    warn "raw.githubusercontent.com unreachable or rate-limited — falling back to jsdelivr mirror"
    spinner_start "Downloading Xray-install script (mirror)"
    if retry 3 curl -Ls -o "$installer_tmp" "$mirror_url" && [[ -s "$installer_tmp" ]] && grep -q "Xray" "$installer_tmp"; then
      spinner_stop 0 "Xray-install script downloaded (mirror)"
    else
      spinner_stop 1 "Download failed"
      die "Could not download the official Xray-install script from GitHub or the jsdelivr mirror. Check network/DNS and retry."
    fi
  fi

  spinner_start "Installing latest Xray-core (official script)"
  # NOTE: no "@" placeholder here. That placeholder is only needed with the
  # `bash -c "$(curl ...)" @ install` idiom, where it fills $0 (since -c has
  # no natural $0). Here we're executing a real file, so $0 is already the
  # script path and the installer's first real argument must be "install"
  # directly — passing "@" first would shove it into $1 instead and the
  # installer's parser would reject it as an unrecognized option.
  if OUT=$(bash "$installer_tmp" install 2>&1); then
    spinner_stop 0 "Xray-core installed"
  else
    spinner_stop 1 "Xray-core installation failed"
    echo -e "${DIM}${OUT}${NC}"
    die "Aborting."
  fi
  rm -f "$installer_tmp"
  trap cleanup_on_exit EXIT

  command -v xray >/dev/null 2>&1 || die "xray binary not found after installation."

  # NOTE: deliberately not piping through `head` here. Under `set -o pipefail`,
  # `xray version | head -n1` can make xray receive SIGPIPE when head closes
  # the pipe early, which makes the pipeline report a non-zero exit status
  # even though everything "worked" — and that silently kills the whole
  # script under `set -e` with no error message. Capture full output first,
  # then take the first line with a pure bash string operation instead.
  local ver_full
  ver_full=$(xray version 2>&1 || true)
  XRAY_VERSION="${ver_full%%$'\n'*}"
  ok "Installed: ${XRAY_VERSION}"
}

# ────────────────────────────────────────────────────────────────────────────
#  Credential generation
# ────────────────────────────────────────────────────────────────────────────
generate_credentials() {
  spinner_start "Generating UUID, x25519 keypair, and short ID"

  UUID=$(xray uuid 2>&1 || true)
  [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { spinner_stop 1 "UUID generation failed"; die "xray uuid returned unexpected output: $UUID"; }

  # xray x25519 output format: "Private key: xxx" / "Public key: xxx"
  # (older builds: "PrivateKey:" / "Password:") — handle both.
  # NOTE: using awk alone (not grep | awk) for extraction — awk exits 0 even
  # when its pattern doesn't match, whereas grep exits 1 on no match. Under
  # `set -o pipefail`, a mid-pipe grep miss becomes the pipeline's reported
  # exit status and silently kills the script via `set -e`. awk sidesteps that.
  local keys
  keys=$(xray x25519 2>&1 || true)
  PRIVATE_KEY=$(awk -F': ' 'tolower($0) ~ /private ?key/ {print $2}' <<<"$keys" | tr -d '[:space:]')
  PUBLIC_KEY=$(awk -F': ' 'tolower($0) ~ /public ?key|password/ {print $2}' <<<"$keys" | tr -d '[:space:]')

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
  if [[ "${XRAY_SKIP_FW_RESET:-0}" == "1" ]]; then
    warn "XRAY_SKIP_FW_RESET=1 — skipping firewall configuration. Make sure port ${XPORT} is reachable through whatever firewall you already have."
    return 0
  fi

  local ssh_port
  # awk-only extraction (see note in generate_credentials) — avoids grep
  # returning non-zero on no match, which under pipefail+set -e would
  # silently kill the script mid-firewall-setup.
  ssh_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); if (n>0) print a[n]; exit}')
  ssh_port="${ssh_port:-22}"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22

  if command -v ufw >/dev/null 2>&1; then
    local existing_rules
    existing_rules=$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)
    if [[ "${existing_rules:-0}" -gt 0 ]]; then
      warn "ufw already has ${existing_rules} existing rule(s). This step RESETS ufw and replaces them with SSH + Xray-only rules."
      if [[ -t 0 ]]; then
        read -rp "$(echo -e "${ARROW} Continue and wipe the existing ufw rules? [y/N]: ")" confirm_reset
        [[ "$confirm_reset" =~ ^[Yy]$ ]] || die "Aborted — existing firewall rules were left untouched. Re-run and confirm, set XRAY_SKIP_FW_RESET=1 to leave firewalling to you, or configure it manually."
      else
        warn "Non-interactive session — proceeding with the reset. Set XRAY_SKIP_FW_RESET=1 beforehand to skip firewall changes entirely instead."
      fi
    fi

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

  # Common on budget/OpenVZ-style VPS hosts: no tcp_bbr module and/or a
  # kernel too old to support it. Detect that instead of claiming success.
  if ! modprobe tcp_bbr 2>/dev/null && ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    spinner_stop 0 "BBR not available on this kernel/VPS host — skipped (not required for REALITY to work)"
    return 0
  fi

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
    spinner_stop 0 "BBR requested but not confirmed active — some VPS kernels apply it only after reboot"
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
  elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    spinner_start "Enabling automatic security updates (dnf-automatic)"
    "$PKG_MANAGER" install -y dnf-automatic >/dev/null 2>&1 || true
    if [[ -f /etc/dnf/automatic.conf ]]; then
      sed -i 's/^upgrade_type\s*=.*/upgrade_type = security/'  /etc/dnf/automatic.conf 2>/dev/null || true
      sed -i 's/^apply_updates\s*=.*/apply_updates = yes/'     /etc/dnf/automatic.conf 2>/dev/null || true
    fi
    systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
      && spinner_stop 0 "Automatic security updates enabled (dnf-automatic)" \
      || spinner_stop 0 "dnf-automatic unavailable — skipped (not fatal)"
  else
    spinner_start "Enabling automatic security updates (yum-cron)"
    "$PKG_MANAGER" install -y yum-cron >/dev/null 2>&1 || true
    if [[ -f /etc/yum/yum-cron.conf ]]; then
      sed -i 's/^apply_updates\s*=.*/apply_updates = yes/' /etc/yum/yum-cron.conf 2>/dev/null || true
    fi
    systemctl enable --now yum-cron >/dev/null 2>&1 \
      && spinner_stop 0 "Automatic security updates enabled (yum-cron)" \
      || spinner_stop 0 "yum-cron unavailable — skipped (not fatal)"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
#  Output: client link + QR
# ────────────────────────────────────────────────────────────────────────────
print_summary() {
  local server_ip
  server_ip=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s6 --max-time 5 https://api64.ipify.org || echo "YOUR_SERVER_IP")

  local link="vless://${UUID}@${server_ip}:${XPORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${REMARK}"

  echo
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
  if [[ "${MODE:-reprovision}" == "rotate" ]]; then
    echo -e "${GREEN}${BOLD} Credentials rotated${NC}  ${DIM}(SNI, port, firewall, and systemd config unchanged)${NC}"
  else
    echo -e "${GREEN}${BOLD} Installation complete${NC}"
  fi
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
  echo -e "  ${DIM}Install transcript:       ${LOG_FILE}${NC}"
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
  detect_existing_install
  offer_mode_selection

  if [[ "$MODE" == "rotate" ]]; then
    rotate_credentials_only
  else
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
  fi

  print_summary
}

main "$@"
