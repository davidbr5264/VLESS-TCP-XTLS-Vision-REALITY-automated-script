#!/usr/bin/env bash
#
# setup-xray-reality-v2.sh
#
# Automated installer / manager for a hardened Xray VLESS-TCP-XTLS-Vision-REALITY
# instance on a Debian/Ubuntu VPS, for personal use.
#
# RESTRUCTURED (v2): same behavior as setup-xray-reality.sh, reorganized into
# named functions grouped by responsibility (UI, state, credentials/config,
# service, install steps, modes) instead of one long linear script. See the
# section banners below for the map. Built and tested as a parallel project
# alongside the original -- every safety-critical detail (subshell variable
# scoping, the -format json fix, atomic writes, CONFIG_CHANGED semantics,
# the port-conflict check, etc.) is preserved exactly, not re-derived.
#
# Usage:
#   ./setup-xray-reality-v2.sh                Install (or re-apply) full setup
#   ./setup-xray-reality-v2.sh --rotate-uuid   Replace UUID + short ID only
#                                           (keeps REALITY keypair; use this to
#                                           revoke a leaked client link without
#                                           regenerating your server's identity)
#   ./setup-xray-reality-v2.sh --rotate-all    Replace UUID + short ID + REALITY
#                                           keypair (invalidates ALL client links)
#   ./setup-xray-reality-v2.sh --show          Reprint the current client link/QR
#                                           without changing anything
#   ./setup-xray-reality-v2.sh --list-backups  List available backups with timestamps
#   ./setup-xray-reality-v2.sh --dedupe-backups  Remove redundant backups where a
#                                           consecutive run has identical config
#                                           (keeps the most recent of each run)
#   ./setup-xray-reality-v2.sh --restore TS    Restore config/state from a backup
#                                           (backs up current state first)
#   ./setup-xray-reality-v2.sh --help          Show this help
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

SCRIPT_START_TIME=$(date +%s)

# =============================================================================
# SECTION 1: UI LIBRARY
# Colors, banner, step headers, spinner, ok/warn/err. No dependency on
# anything below this section.
# =============================================================================

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4); C_CYAN=$(tput setaf 6); C_MAGENTA=$(tput setaf 5)
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

banner() {
  echo ""
  echo "${C_CYAN}${C_BOLD}  ╔══════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  ║    Xray VLESS · TCP · XTLS-Vision · REALITY Setup    ║${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  ╚══════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
}

# Small icon per step, matched by keyword in the description -- purely
# cosmetic, falls through to a generic bullet for anything unmatched.
step_icon() {
  case "$1" in
    *"Preparing server"*)     echo "📦" ;;
    *"Xray-core"*)            echo "⬇️ " ;;
    *"credentials"*)          echo "🔑" ;;
    *"Writing Xray config"*)  echo "⚙️ " ;;
    *"systemd service"*)      echo "🛠️ " ;;
    *"firewall"*)             echo "🛡️ " ;;
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

step() {
  local label="$1" desc="$2" icon
  icon=$(step_icon "$desc")
  echo ""
  echo "${C_BLUE}${C_BOLD}==> [$label]${C_RESET} ${icon} ${C_BOLD}${desc}${C_RESET}"
}

ok()   { echo "${C_GREEN}  ✓ $1${C_RESET}"; }
warn() { echo "${C_YELLOW}  ⚠ WARNING:${C_RESET} $1" >&2; }
err()  { echo "${C_RED}  ✗ ERROR:${C_RESET} $1" >&2; }

# Human-readable elapsed time since SCRIPT_START_TIME, used in the final
# completion summary.
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

# Array, not a single multi-byte string indexed by offset -- `tr` corrupts
# multi-byte UTF-8 in a non-UTF-8 (C/POSIX) locale, which many minimal
# Debian/Ubuntu cloud images default to. Array elements are always safe
# since each is treated as an opaque whole string.
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_COLORS=("$C_CYAN" "$C_BLUE" "$C_MAGENTA")

# Runs a command in the background under an animated spinner, hiding its
# normal (noisy) output. ALWAYS captures full output to a temp file and
# ALWAYS prints it in full on failure -- nothing is ever silently
# swallowed, only hidden when the command actually succeeds. Falls back
# to a plain "running..." message with no animation when not a real
# terminal (piped/logged output), but still hides-on-success there too.
#
# SAFETY CONTRACT (do not violate when adding new call sites): only ever
# wrap external commands or shell functions that do NOT set variables the
# rest of the script needs afterward. Backgrounding via `&` forks a
# subshell; any variable assignment inside it is lost the moment that
# subshell exits. Confirmed by direct test during development. This is
# why generate_uuid_and_shortid, generate_reality_keypair, and
# write_config are never passed to this function.
run_spinner() {
  local desc="$1"; shift
  local logfile
  logfile=$(mktemp)

  "$@" >"$logfile" 2>&1 &
  local pid=$!

  if [[ -t 1 ]]; then
    tput civis 2>/dev/null || true
    local i=0 frame color start_time now elapsed
    start_time=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
      frame="${SPINNER_FRAMES[i % ${#SPINNER_FRAMES[@]}]}"
      color="${SPINNER_COLORS[i % ${#SPINNER_COLORS[@]}]}"
      now=$(date +%s)
      elapsed=$((now - start_time))
      printf "\r${color}%s${C_RESET} %s... ${C_BOLD}(%ss)${C_RESET}" "$frame" "$desc" "$elapsed"
      i=$((i + 1))
      sleep 0.1
    done
    tput cnorm 2>/dev/null || true
  else
    echo "Running: ${desc}..."
  fi

  # Never let set -e trip on `wait` itself -- we need to reach our own
  # success/failure handling below regardless of the wrapped command's
  # exit code, not have the script abort mid-function.
  local rc=0
  wait "$pid" || rc=$?

  if [[ -t 1 ]]; then
    printf "\r\033[K"
  fi

  if [[ "$rc" -eq 0 ]]; then
    ok "$desc"
  else
    err "${desc} failed (exit ${rc}). Full output:"
    sed 's/^/  /' "$logfile" >&2
  fi

  rm -f "$logfile"
  return "$rc"
}

# Restore the cursor if the script is interrupted mid-spinner (Ctrl+C etc)
# -- otherwise a hidden cursor can persist in the terminal after exit.
# Guarded by -t 1 so this never leaks a stray escape sequence into piped
# or redirected output (e.g. --help | less) on runs that never actually
# touched the spinner.
trap '[[ -t 1 ]] && tput cnorm 2>/dev/null; true' EXIT


# =============================================================================
# SECTION 2: CONSTANTS
# Pure data. No logic. Everything below depends on these.
# =============================================================================

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
LOCK_FILE="/var/lock/reality-setup.lock"
REALITY_SHORTCUT="/usr/local/bin/reality"

# Runtime state, populated by parse_arguments()/load_state()/the install
# steps. Declared here (empty) so every function operates on the same
# global names regardless of call order.
MODE="install"
RESTORE_TS=""
SNI_DOMAIN=""
LISTEN_PORT=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SSH_PORT=""
CONFIG_CHANGED=0
BEFORE_XRAY_VERSION=""
AFTER_XRAY_VERSION=""


# =============================================================================
# SECTION 3: ARGUMENT PARSING & PREFLIGHT
# =============================================================================

parse_arguments() {
  case "${1:-}" in
    --rotate-uuid)    MODE="rotate-uuid" ;;
    --rotate-all)     MODE="rotate-all" ;;
    --show)           MODE="show" ;;
    --list-backups)   MODE="list-backups" ;;
    --dedupe-backups) MODE="dedupe-backups" ;;
    --restore)
      MODE="restore"
      RESTORE_TS="${2:-}"
      if [[ -z "$RESTORE_TS" ]]; then
        err "--restore requires a timestamp. See --list-backups for available ones."
        exit 1
      fi
      ;;
    --help|-h)
      sed -n '2,49p' "$0"
      exit 0
      ;;
    "") ;;
    *)
      err "Unknown argument '$1'. Use --help for usage."
      exit 1
      ;;
  esac
}

run_preflight_checks() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
  fi

  # Prevent two concurrent runs (e.g. accidentally launched in two
  # terminals) from racing on the same config/backup/state files. Held
  # for the life of this process; released automatically on exit,
  # including on error.
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    err "Another run of this script appears to be in progress (lock: ${LOCK_FILE})."
    echo "       Wait for it to finish, or remove the lock file if you're sure nothing" >&2
    echo "       is actually running: rm -f ${LOCK_FILE}" >&2
    exit 1
  fi

  if [[ "$MODE" != "install" ]] && ! command -v xray >/dev/null 2>&1; then
    err "Xray is not installed yet. Run the script with no arguments first."
    exit 1
  fi

  # Non-install modes (rotate/show/restore) rely on jq, openssl, and
  # qrencode, but only ever checked that xray itself exists. If any of
  # these went missing after the initial install, the failure should be
  # a clear message here, not a bare "command not found" partway through.
  if [[ "$MODE" != "install" ]]; then
    local dep
    for dep in jq openssl qrencode; do
      if ! command -v "$dep" >/dev/null 2>&1; then
        err "Required tool '${dep}' is missing (it should have been installed already)."
        echo "       Reinstall it with: apt-get install -y ${dep}" >&2
        exit 1
      fi
    done
  fi

  if [[ "$MODE" == "install" ]] && ! command -v apt-get >/dev/null 2>&1; then
    err "This script only supports Debian/Ubuntu (apt-based) systems."
    exit 1
  fi

  # Fail with a clear message rather than a confusing mid-script error if
  # there's not enough room for apt upgrades, Xray-core, and logs/backups.
  if [[ "$MODE" == "install" ]]; then
    local available_kb min_required_kb=1048576  # 1GB
    available_kb=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
    if [[ -n "$available_kb" ]] && [[ "$available_kb" -lt "$min_required_kb" ]]; then
      err "Less than 1GB free on / (found $((available_kb / 1024))MB)."
      echo "       apt upgrades, Xray-core, and logs need headroom to install safely." >&2
      echo "       Free up space first (e.g. 'apt autoremove --purge -y'), then re-run." >&2
      exit 1
    fi
  fi
}


# =============================================================================
# SECTION 4: STATE LIBRARY
# Loading, saving, and backing up the persisted SNI/port/credentials.
# =============================================================================

# Loads any previously saved state (SNI/port/keys) so rotate/show modes
# reuse the same settings instead of falling back to defaults. Existing
# state always wins over env var defaults, on purpose -- this is what
# makes plain re-runs preserve credentials instead of regenerating them.
load_state() {
  SNI_DOMAIN="$SNI_DOMAIN_DEFAULT"
  LISTEN_PORT="$LISTEN_PORT_DEFAULT"

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    # SNI_DOMAIN=/LISTEN_PORT=... env vars silently do nothing on an
    # existing install (state always wins) -- that's confusing without a
    # message, so flag it explicitly. There's no supported way to change
    # just the SNI or port without a full --rotate-all (which also
    # regenerates the keypair).
    if [[ "$SNI_DOMAIN_DEFAULT" != "i.ytimg.com" && "$SNI_DOMAIN_DEFAULT" != "$SNI_DOMAIN" ]]; then
      warn "SNI_DOMAIN env var ('${SNI_DOMAIN_DEFAULT}') was set, but an existing install already"
      echo "         uses '${SNI_DOMAIN}' -- existing state always wins, so the env var was ignored." >&2
      echo "         There's no way to change just the SNI without --rotate-all (full reset)." >&2
    fi
    if [[ "$LISTEN_PORT_DEFAULT" != "443" && "$LISTEN_PORT_DEFAULT" != "$LISTEN_PORT" ]]; then
      warn "LISTEN_PORT env var ('${LISTEN_PORT_DEFAULT}') was set, but an existing install already"
      echo "         uses port ${LISTEN_PORT} -- existing state always wins, so the env var was ignored." >&2
    fi
  fi
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

# Backs up current config + client info + state before any change. Only
# called when there's actually something to back up (an existing
# config.json) -- write_config() decides WHETHER to call this based on
# whether anything actually changed; other callers (rotate/restore modes)
# call it unconditionally since those always change something by definition.
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


# =============================================================================
# SECTION 5: CREDENTIALS & CONFIG LIBRARY
# =============================================================================

# Sets UUID, SHORT_ID globals. NEVER pass to run_spinner -- see the safety
# contract on run_spinner above.
generate_uuid_and_shortid() {
  UUID=$(xray uuid) || { err "'xray uuid' command failed to run."; exit 1; }
  SHORT_ID=$(openssl rand -hex 8)
  if [[ -z "$UUID" || -z "$SHORT_ID" ]]; then
    err "Failed to generate UUID or short ID."
    exit 1
  fi
}

# Sets PRIVATE_KEY, PUBLIC_KEY globals. NEVER pass to run_spinner.
# Handles both old and new `xray x25519` CLI output formats:
#   Old: "Private key: xxx" / "Public key: xxx"
#   New: "PrivateKey: xxx"  / "Password (PublicKey): xxx" / "Hash32: xxx"
generate_reality_keypair() {
  local key_output
  key_output=$(xray x25519) || { err "'xray x25519' command failed to run."; exit 1; }

  PRIVATE_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Private ?[Kk]ey)[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  PUBLIC_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Public ?[Kk]ey|Password)([[:space:]]*\(.*\))?[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Failed to parse REALITY keypair."
    echo "  PRIVATE_KEY=${PRIVATE_KEY:-<empty>}" >&2
    echo "  PUBLIC_KEY=${PUBLIC_KEY:-<empty>}" >&2
    echo "  Raw 'xray x25519' output was:" >&2
    echo "$key_output" >&2
    exit 1
  fi
}

# Writes config.json from current UUID/keys/short ID. Sets CONFIG_CHANGED
# global (read by finish_and_restart() to decide whether a restart is
# actually needed). NEVER pass to run_spinner -- see safety contract above.
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
  # Fail fast with a clear message if the config we just wrote is
  # malformed, rather than letting it surface later as an opaque
  # "service failed to start" from systemd.
  if ! jq empty "$tmp_config" >/dev/null 2>&1; then
    err "Generated config.json is not valid JSON. Not restarting xray."
    echo "  Broken draft left at ${tmp_config} for inspection." >&2
    echo "  Existing config (if any) at ${CONFIG_FILE} was left untouched." >&2
    exit 1
  fi

  # jq only confirms valid JSON syntax -- it says nothing about whether
  # Xray's own schema actually accepts the field names/structure. Xray-core
  # has a real config-test mode built for exactly this; use it so a typo'd
  # field surfaces here with a clear message, not as a cryptic runtime
  # failure from systemd later.
  #
  # NOTE: the log directory must exist before this runs -- the config
  # references /var/log/xray/error.log, and xray -test fails to even load
  # the config if that path's parent directory doesn't exist yet (confirmed
  # by testing against a real xray-core binary: this order bug would have
  # broken every fresh install otherwise). NOTE 2: -format json must be
  # explicit -- this temp file's name doesn't end in .json (mktemp's random
  # suffix comes after it), and Xray's format auto-detection is
  # extension-based, so it fails to even load the file without this flag
  # (also confirmed against a real binary).
  mkdir -p /var/log/xray
  chown -R xray:xray /var/log/xray 2>/dev/null || true

  if command -v xray >/dev/null 2>&1; then
    if ! XRAY_TEST_OUTPUT=$(xray run -test -format json -config "$tmp_config" 2>&1); then
      err "Xray rejected the generated config (schema/field error, not a JSON syntax error):"
      echo "$XRAY_TEST_OUTPUT" | sed 's/^/  /' >&2
      echo "  Broken draft left at ${tmp_config} for inspection." >&2
      echo "  Existing config (if any) at ${CONFIG_FILE} was left untouched." >&2
      exit 1
    fi
  fi

  # Only back up if this is actually going to change something. Any real
  # credential/SNI/port difference necessarily shows up in config.json, so
  # comparing content here reliably detects "did anything meaningful
  # change" -- without this, a completely no-op re-run (e.g. plain
  # 'reality' with nothing to update) was creating a new backup every
  # single time, burning through the 15-backup retention window fast.
  if [[ -f "$CONFIG_FILE" ]] && cmp -s "$tmp_config" "$CONFIG_FILE"; then
    CONFIG_CHANGED=0
  else
    CONFIG_CHANGED=1
    backup_current_state
  fi

  # Atomic swap: rename is a single filesystem operation, so a crash here
  # never leaves a half-written config.json -- you get the old one or the
  # fully-written new one, never something in between.
  mv -f "$tmp_config" "$CONFIG_FILE"

  # Config contains the REALITY private key -- restrict to root + the xray
  # service user rather than leaving it world-readable.
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
}


# =============================================================================
# SECTION 6: SERVICE LIBRARY
# =============================================================================

restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    err "xray service failed to start. Check: journalctl -u xray -e"
    exit 1
  fi
  ok "xray service is active"
  verify_handshake
}

# Best-effort network-level check that Xray is actually serving REALITY
# correctly, not just that the process is running. "Active" in systemd
# only means the process didn't crash -- it says nothing about whether
# the port is reachable or the TLS handshake actually works. Non-fatal:
# prints warnings rather than aborting, since this check can have
# environmental false negatives (e.g. loopback quirks) that a real
# remote client wouldn't hit.
verify_handshake() {
  local port="${LISTEN_PORT:-443}"
  local sni="${SNI_DOMAIN:-}"

  if ! ss -tln 2>/dev/null | grep -q ":${port} "; then
    warn "Xray is active, but nothing appears to be listening on port ${port}."
    echo "         Check: ss -tlnp | grep ${port}" >&2
    return 0
  fi

  if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    warn "Port ${port} is listed as listening, but a local TCP connect failed."
    return 0
  fi

  if [[ -n "$sni" ]] && command -v openssl >/dev/null 2>&1; then
    if ! timeout 5 bash -c "echo | openssl s_client -connect 127.0.0.1:${port} -servername '${sni}' 2>/dev/null" | grep -q "CONNECTED"; then
      warn "TCP connects, but a TLS handshake against 127.0.0.1:${port} (SNI: ${sni})"
      echo "         didn't complete cleanly. This can be a loopback/self-connect quirk --" >&2
      echo "         test from a real client before assuming something's wrong. If a real" >&2
      echo "         client also fails, check: journalctl -u xray -e" >&2
      return 0
    fi
  fi

  ok "Handshake check passed: port listening, TCP connects, TLS handshake completes."
}


# =============================================================================
# SECTION 7: CLIENT OUTPUT LIBRARY
# =============================================================================

output_client_info() {
  local server_ip
  server_ip=$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://icanhazip.com 2>/dev/null || \
              true)
  server_ip=$(echo "$server_ip" | tr -d '[:space:]')

  if [[ -z "$server_ip" ]]; then
    warn "Could not determine the server's public IP (all lookup services unreachable)."
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

  local status_now status_color
  status_now=$(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo unknown)
  if [[ "$status_now" == "active" ]]; then status_color="$C_GREEN"; else status_color="$C_YELLOW"; fi

  echo ""
  echo "${C_CYAN}############################################################${C_RESET}"
  echo "  Service status : ${status_color}${status_now}${C_RESET}"
  echo "  Config file    : ${CONFIG_FILE}"
  echo "  Client info    : ${CLIENT_INFO_FILE} (chmod 600)"
  echo "${C_CYAN}############################################################${C_RESET}"
  echo ""
  echo "${C_BOLD}Client link${C_RESET} (import into v2rayN / NekoBox / Shadowrocket / etc.):"
  echo "${C_GREEN}${vless_link}${C_RESET}"
  echo ""
  echo "${C_BOLD}QR code:${C_RESET}"
  qrencode -t ansiutf8 "${vless_link}"
}

# Shared by every mode that ends with save+print+restart, eliminating the
# duplicated save_state/output_client_info/restart sequence that used to
# be hand-rolled slightly differently in install/rotate-uuid/rotate-all/
# restore. Pass "conditional" to allow skipping the restart when nothing
# actually changed (install mode only); pass "always" to unconditionally
# restart (rotate/restore modes, which always changed something by
# definition).
finish_and_restart() {
  local restart_mode="$1"
  save_state
  output_client_info

  if [[ "$restart_mode" == "conditional" ]]; then
    step "final" "Restarting Xray"
    local service_currently_active
    service_currently_active=$(systemctl is-active --quiet "${SERVICE_NAME}" && echo 1 || echo 0)
    if [[ "$CONFIG_CHANGED" == "0" ]] && [[ "$BEFORE_XRAY_VERSION" == "$AFTER_XRAY_VERSION" ]] && [[ "$service_currently_active" == "1" ]]; then
      ok "Nothing changed (config identical, Xray-core unchanged, service already running) -- skipping restart."
      verify_handshake
    else
      restart_and_verify
    fi
  else
    restart_and_verify
  fi
}


# =============================================================================
# SECTION 8: INSTALL STEPS (one function per numbered step, plus the
# pre-step helpers used only by install mode: self-update check, SNI
# prompt, and the post-step reality-shortcut installer)
# =============================================================================

# Best-effort check: is the copy of this script actually running (e.g.
# the installed 'reality' shortcut) behind what's currently on GitHub?
# This is a NOTIFICATION only -- it never replaces or modifies the
# running script (self-modifying a script mid-execution is a real
# footgun: truncated reads, races). Runs in the background so its network
# round-trip overlaps with the SNI prompt and step 1's apt operations
# instead of adding its own delay serially. Sets globals consumed by
# collect_self_update_check_result().
SELF_UPDATE_CHECK_PATH=""
SELF_UPDATE_RESULT_FILE=""
SELF_UPDATE_BG_PID=""

start_self_update_check() {
  SELF_UPDATE_CHECK_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
  SELF_UPDATE_RESULT_FILE=$(mktemp)
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
}

collect_self_update_check_result() {
  if [[ -n "$SELF_UPDATE_BG_PID" ]]; then
    wait "$SELF_UPDATE_BG_PID" 2>/dev/null || true
    if [[ -s "$SELF_UPDATE_RESULT_FILE" ]]; then
      warn "This copy of the script is out of date (differs from ${SCRIPT_SOURCE_URL})."
      echo "         Update with: bash <(curl -Ls ${SCRIPT_SOURCE_URL})" >&2
      echo "         Continuing with the current (older) copy for this run." >&2
    fi
  fi
  rm -f "$SELF_UPDATE_RESULT_FILE"
}

# Only prompts on a genuinely first-time install (no UUID yet means no
# existing state) and only when there's an actual interactive terminal --
# piped/scripted/non-interactive runs just fall through to the existing
# default (env var override, or i.ytimg.com). Sets SNI_DOMAIN global.
prompt_for_sni() {
  if [[ -z "$UUID" ]] && [[ -t 0 ]]; then
    while true; do
      echo ""
      echo "${C_BOLD}REALITY camouflage target (SNI)${C_RESET}"
      echo "This is the real site Xray impersonates during the TLS handshake."
      echo "It should be a real TLS1.3 site, not a huge one (avoid google.com/"
      echo "microsoft.com-scale sites -- large certs can trip protocol issues,"
      echo "and CDN-fronted domains make REALITY easier to fingerprint)."
      local sni_input
      read -r -p "Domain to use [${SNI_DOMAIN}]: " sni_input
      if [[ -n "$sni_input" ]]; then
        # Basic sanitization in case someone pastes a full URL by mistake:
        # strip scheme, path, port, and trailing slashes -- keep just the host.
        sni_input="${sni_input#http://}"
        sni_input="${sni_input#https://}"
        sni_input="${sni_input%%/*}"
        sni_input="${sni_input%%:*}"
        if [[ -n "$sni_input" ]]; then
          SNI_DOMAIN="$sni_input"
        fi
      fi

      # Best-effort live check: does this domain actually resolve and
      # serve TLS1.3 on 443? openssl may not be installed yet this early
      # (that happens in step 1) -- skip gracefully if so.
      if command -v openssl >/dev/null 2>&1; then
        if timeout 6 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 </dev/null >/dev/null 2>&1; then
          ok "Confirmed: ${SNI_DOMAIN} resolves and serves TLS1.3 on port 443."
          break
        else
          warn "Couldn't confirm ${SNI_DOMAIN} serves TLS1.3 on port 443 (DNS failure, no"
          echo "         response, or TLS1.3 unsupported). REALITY requires this to work." >&2
          local sni_force
          read -r -p "Use it anyway? (y/N): " sni_force
          if [[ "$sni_force" =~ ^[Yy]$ ]]; then
            break
          fi
          # loop back and re-prompt
        fi
      else
        break
      fi
    done
    echo "Using: ${C_CYAN}${SNI_DOMAIN}${C_RESET}"
  fi
}

step_01_prepare_server() {
  step "1/9" "Preparing server (updates, cleanup, essential tools)"
  export DEBIAN_FRONTEND=noninteractive
  run_spinner "Updating package lists" apt-get update -y
  run_spinner "Upgrading installed packages" apt-get upgrade -y
  run_spinner "Removing unused packages" apt-get autoremove -y --purge
  run_spinner "Cleaning apt cache" apt-get autoclean -y

  # Packages this script actually depends on -- install must succeed.
  # --no-install-recommends skips recommended-but-unused extras (docs,
  # fonts, etc.) that several of these commonly pull in by default on a
  # headless VPS that doesn't need them.
  run_spinner "Installing required packages" apt-get install -y --no-install-recommends \
    curl wget unzip jq openssl qrencode ufw fail2ban ca-certificates

  # "Nice to have" base tools some environments are missing by default.
  # Not required by anything below, so a missing package here should
  # warn, not abort the whole install.
  if ! run_spinner "Installing optional packages" apt-get install -y --no-install-recommends gnupg lsb-release apt-transport-https logrotate; then
    echo "NOTE: one or more optional packages (gnupg/lsb-release/apt-transport-https/logrotate) were unavailable; continuing anyway, they aren't required."
  fi

  if [[ -f /var/run/reboot-required ]]; then
    echo "NOTE: A previous update marked this system as needing a reboot."
    echo "      The daily reboot timer set up later in this script will handle it,"
    echo "      or reboot manually now with: reboot"
  fi

  # Collect the backgrounded self-update check (started before the SNI
  # prompt) now that step 1's apt operations have given it plenty of time
  # to finish.
  collect_self_update_check_result
}

step_02_install_xray_core() {
  step "2/9" "Installing Xray-core (official installer)"
  mkdir -p "$XRAY_CONFIG_DIR"
  BEFORE_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")

  # The official installer always makes a full network round-trip to
  # check the latest release, even when almost certainly already
  # current. Skip that full check if we already have xray installed and
  # checked within the last 24h.
  local xray_update_check_cache="${XRAY_CONFIG_DIR}/.last-xray-checkupdate"
  local skip_installer_check=0
  if command -v xray >/dev/null 2>&1 && [[ -f "$xray_update_check_cache" ]]; then
    local last_check now
    last_check=$(cat "$xray_update_check_cache" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ "$last_check" =~ ^[0-9]+$ ]] && [[ $((now - last_check)) -lt 86400 ]]; then
      skip_installer_check=1
    fi
  fi

  if [[ "$skip_installer_check" -eq 1 ]]; then
    ok "Xray-core was checked for updates within the last 24h -- skipping the full check this run."
  else
    local xray_install_attempts=3 attempt
    for attempt in $(seq 1 "$xray_install_attempts"); do
      if run_spinner "Downloading and installing Xray-core (attempt ${attempt}/${xray_install_attempts})" \
           bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install; then
        break
      fi
      if [[ "$attempt" -eq "$xray_install_attempts" ]]; then
        err "Failed to install Xray-core after ${xray_install_attempts} attempts (likely a network issue reaching GitHub)."
        exit 1
      fi
      echo "Retrying in 5s..."
      sleep 5
    done
    date +%s > "$xray_update_check_cache"
  fi

  AFTER_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")
}

step_03_setup_credentials() {
  step "3/9" "Setting up credentials (UUID, REALITY keypair, short ID)"
  if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
    echo "Existing credentials found in ${STATE_FILE} -- reusing them (client links stay valid)."
    echo "Need fresh credentials instead? Use --rotate-uuid or --rotate-all, not a plain re-run."
  else
    echo "No existing credentials found -- generating new ones (first-time install)."
    generate_uuid_and_shortid
    generate_reality_keypair
  fi

  # Dedicated unprivileged system account for the xray service to run as
  # (see step 5). Created here, before write_config, so the config
  # file's ownership can be set correctly on first install.
  if ! id -u xray >/dev/null 2>&1; then
    run_spinner "Creating dedicated xray service user" useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi

  # Catch a port conflict here with a clear message, rather than letting
  # it surface later as a generic "service failed to start". A listener
  # that IS our own xray (e.g. a re-run on an already-running instance)
  # is expected and fine; anything else bound to this port is a real
  # conflict.
  local port_holder
  port_holder=$(ss -tlnp 2>/dev/null | awk -v p=":${LISTEN_PORT}\$" '$4 ~ p {print}')
  if [[ -n "$port_holder" ]] && ! echo "$port_holder" | grep -qi "xray"; then
    err "Port ${LISTEN_PORT} is already in use by something other than Xray:"
    echo "$port_holder" | sed 's/^/  /' >&2
    echo "  Stop that service first, or choose a different port (LISTEN_PORT=... env var)." >&2
    exit 1
  fi
}

step_04_write_config() {
  step "4/9" "Writing Xray config (privacy-minded: no access logging)"
  write_config
  ok "Config written and validated"
}

step_05_harden_systemd() {
  step "5/9" "Hardening the systemd service"
  mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf" <<'EOF'
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

  # OnFailure= above fires once the restart-attempt budget
  # (StartLimitBurst) is exhausted and the service gives up -- not on
  # every individual transient restart. Local-only alert (no email/
  # webhook configured anywhere in this setup): broadcasts to logged-in
  # terminals + a critical syslog entry.
  cat > /etc/systemd/system/xray-alert.service <<'EOF'
[Unit]
Description=Local alert when xray.service exhausts its restart attempts

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'logger -p daemon.crit "xray.service has FAILED and exhausted its restart attempts -- check: journalctl -u xray -e"; wall "WARNING: xray.service has failed and given up restarting. Check: journalctl -u xray -e" || true'
EOF

  # Reload the unit + drop-in now so the change is registered, but hold
  # off on actually restarting until every other step below has
  # succeeded -- see finish_and_restart() at the end of mode_install.
  run_spinner "Registering systemd hardening" bash -c "systemctl daemon-reload; systemctl enable '${SERVICE_NAME}' >/dev/null 2>&1 || true"

  # REALITY's handshake validation is timestamp-sensitive -- clock drift
  # causes intermittent, confusing failures. Confirm NTP sync is active
  # rather than assuming the base image has it enabled.
  if command -v timedatectl >/dev/null 2>&1; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
      timedatectl set-ntp true >/dev/null 2>&1 || true
      sleep 2
      if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
        warn "System clock is not confirmed NTP-synchronized."
        echo "         REALITY handshakes are timestamp-sensitive; clock drift can cause" >&2
        echo "         intermittent failures. Check: timedatectl status" >&2
      fi
    fi
  fi
}

step_06_configure_firewall() {
  step "6/9" "Configuring firewall (UFW)"
  SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1)
  SSH_PORT="${SSH_PORT:-22}"

  # If SSH was ever reconfigured to a different port through some other
  # means, an old rule for the previous port could still be sitting
  # here, open forever. Detect and flag it -- but don't auto-delete:
  # this script can't tell a genuinely stale rule apart from an
  # intentional second SSH listener, and getting that wrong risks
  # locking you out.
  local stale_ssh_rules
  stale_ssh_rules=$(ufw status numbered 2>/dev/null | grep "SSH" | grep -v "${SSH_PORT}/tcp" || true)
  if [[ -n "$stale_ssh_rules" ]]; then
    echo "NOTE: Found UFW rule(s) tagged 'SSH' for a port other than the current one (${SSH_PORT}):"
    echo "$stale_ssh_rules"
    echo "      If SSH used to run on a different port, this is probably stale and safe to"
    echo "      remove with: ufw delete <rule number>   (run 'ufw status numbered' to check)"
  fi

  # Make sure UFW actually enforces IPv6 too -- if IPV6=no here, the
  # rules below only apply to IPv4 and a public IPv6 address (common on
  # many VPS providers by default) would be left completely unfiltered.
  if [[ -f /etc/default/ufw ]] && grep -qE '^IPV6=no' /etc/default/ufw; then
    sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
    echo "Enabled IPv6 support in UFW (was disabled; would have left IPv6 unfiltered)."
  fi

  # Pin the default policy explicitly rather than relying on whatever
  # the base image shipped with.
  ufw default deny incoming
  ufw default allow outgoing

  # These two rules are load-bearing (lose either one and you either
  # can't SSH in or the proxy stops working), so a failure here should
  # stop the script rather than be silently swallowed.
  if ! ufw allow "${SSH_PORT}"/tcp comment 'SSH'; then
    err "Failed to add UFW rule for SSH port ${SSH_PORT}. Not enabling the firewall."
    echo "       Fix manually, then re-run: ufw allow ${SSH_PORT}/tcp && ufw --force enable" >&2
    exit 1
  fi
  if ! ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY'; then
    err "Failed to add UFW rule for Xray port ${LISTEN_PORT}. Not enabling the firewall."
    exit 1
  fi

  run_spinner "Enabling firewall" bash -c "ufw --force enable && ufw reload"

  if ! ufw status | grep -q "Status: active"; then
    err "UFW did not report active after enabling. The firewall may not be"
    echo "       protecting this server. Check: ufw status verbose" >&2
    exit 1
  fi
}

step_07_configure_fail2ban() {
  step "7/9" "Configuring fail2ban for SSH brute-force protection"
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
bantime = 1h
findtime = 10m
EOF
  run_spinner "Enabling and restarting fail2ban" bash -c "systemctl enable fail2ban; systemctl restart fail2ban; sleep 1"
  if ! systemctl is-active --quiet fail2ban; then
    warn "fail2ban did not come up after restart. SSH brute-force protection"
    echo "         is NOT active. Check: journalctl -u fail2ban -e" >&2
  fi
}

step_08_kernel_tuning() {
  step "8/9" "Enabling BBR + basic kernel/network hardening"

  # systemd-sysctl.service does NOT wait for or trigger on-demand kernel
  # module loading -- confirmed via the official sysctl.d(5) manpage. A
  # sysctl parameter that depends on a not-yet-loaded module (like
  # tcp_congestion_control=bbr depending on the tcp_bbr module, which is
  # built as a loadable module rather than compiled-in on most Debian/
  # Ubuntu kernels) can silently fail to apply on every boot -- including
  # our own daily reboot timer -- unless the module is loaded via
  # modules-load.d BEFORE sysctl settings are processed at boot.
  modprobe tcp_bbr 2>/dev/null || true
  mkdir -p /etc/modules-load.d
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

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

# Throughput/latency tuning for a proxy carrying real traffic
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF
  run_spinner "Applying sysctl settings" sysctl --system

  local active_cc
  active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  if [[ "$active_cc" != "bbr" ]]; then
    warn "Requested BBR but the kernel reports '${active_cc}' as active."
    echo "         Likely cause: the tcp_bbr kernel module isn't available on this kernel." >&2
    echo "         Check: modprobe tcp_bbr && sysctl net.ipv4.tcp_congestion_control=bbr" >&2
    echo "         Not fatal -- proxy still works, just without BBR's throughput benefit." >&2
  fi

  # net.core.default_qdisc only governs qdisc assignment for interfaces
  # that come up AFTER this sysctl takes effect -- it does NOT
  # retroactively change the qdisc on an interface that was already up
  # at boot, which is always the case for the primary interface on a
  # running VPS. BBR relies on fq specifically for its internal pacing,
  # so apply it live to the actual interface rather than assuming the
  # sysctl default covers it.
  local primary_iface current_qdisc
  primary_iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
  if [[ -n "$primary_iface" ]]; then
    current_qdisc=$(tc qdisc show dev "$primary_iface" 2>/dev/null | awk '/root/ {print $2; exit}')
    if [[ "$current_qdisc" != "fq" ]]; then
      if tc qdisc replace dev "$primary_iface" root fq 2>/dev/null; then
        ok "Applied fq qdisc live to ${primary_iface} (was: ${current_qdisc:-unknown})."
      else
        warn "Could not apply fq qdisc live to ${primary_iface} (was: ${current_qdisc:-unknown})."
        echo "         BBR still works without it, just without full pacing benefit until next reboot" >&2
        echo "         (the daily reboot timer will pick up the sysctl default at that point)." >&2
      fi
    fi
  fi

  # Cap the systemd journal's disk usage explicitly rather than trusting
  # whatever default the base image shipped with.
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-xray-hardening.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  run_spinner "Restarting journald with new log limits" systemctl restart systemd-journald

  # Prevent /var/log/xray/error.log from growing unbounded on a
  # long-lived box.
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
}

step_09_daily_reboot() {
  step "9/9" "Setting up daily reboot at midnight"
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
  run_spinner "Enabling daily reboot timer" systemctl enable --now daily-reboot.timer
}

# Installs a short-name copy so this script can be run as 'reality' from
# anywhere, instead of needing to remember/find the original file path.
# Copies the content (not a symlink), so it keeps working even if the
# original downloaded copy is moved or deleted.
#
# If $0 isn't a real file (e.g. run via `bash <(curl -Ls ...)`, where $0
# points to a process-substitution pipe, not a regular file), falls back
# to re-downloading the script fresh from SCRIPT_SOURCE_URL instead.
install_reality_shortcut() {
  local self_path reality_shortcut_resolved
  self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
  reality_shortcut_resolved=$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")

  if [[ "$self_path" == "$reality_shortcut_resolved" ]]; then
    # Already running as the installed shortcut -- nothing to copy onto itself.
    chmod +x "$REALITY_SHORTCUT" 2>/dev/null || true
  elif [[ -f "$self_path" ]]; then
    cp -f "$self_path" "$REALITY_SHORTCUT"
    chmod +x "$REALITY_SHORTCUT"
  else
    local reality_shortcut_tmp
    reality_shortcut_tmp=$(mktemp)
    if curl -fsSL --connect-timeout 10 --max-time 30 "$SCRIPT_SOURCE_URL" -o "$reality_shortcut_tmp" 2>/dev/null \
       && bash -n "$reality_shortcut_tmp" 2>/dev/null; then
      # Only install it once we've confirmed the download is complete and
      # syntactically valid -- a truncated/partial download would
      # otherwise silently replace a working shortcut with a broken one.
      mv -f "$reality_shortcut_tmp" "$REALITY_SHORTCUT"
      chmod +x "$REALITY_SHORTCUT"
    else
      rm -f "$reality_shortcut_tmp"
      warn "Could not install the 'reality' shortcut (this run wasn't from a"
      echo "         real file on disk, e.g. 'bash <(curl ...)', and re-downloading" >&2
      echo "         from ${SCRIPT_SOURCE_URL} also failed or returned an incomplete file)." >&2
      echo "         Everything else succeeded -- to add the shortcut manually:" >&2
      echo "           curl -fsSL ${SCRIPT_SOURCE_URL} -o ${REALITY_SHORTCUT} && chmod +x ${REALITY_SHORTCUT}" >&2
    fi
  fi
}

print_install_complete_summary() {
  echo ""
  echo "${C_GREEN}${C_BOLD}✓ Setup complete.${C_RESET} Server will reboot daily at 00:00 (server local time)."
  echo "Check timezone with: timedatectl   (change with: timedatectl set-timezone <Region/City>)"
  echo "Cancel the daily reboot with: systemctl disable --now daily-reboot.timer"
  echo ""
  echo "${C_BOLD}Re-run any time${C_RESET} (works via either name, from any directory):"
  echo "  ${C_CYAN}reality${C_RESET}                 -> re-apply full setup (backs up old config first)"
  echo "  ${C_CYAN}reality --rotate-uuid${C_RESET}   -> revoke current client link, keep server identity"
  echo "  ${C_CYAN}reality --rotate-all${C_RESET}    -> full credential reset (invalidates everything)"
  echo "  ${C_CYAN}reality --show${C_RESET}          -> reprint current client link + QR"
}


# =============================================================================
# SECTION 9: MODES
# One function per CLI mode. Each is now short enough to read top-to-bottom.
# =============================================================================

mode_install() {
  start_self_update_check
  prompt_for_sni

  step_01_prepare_server
  step_02_install_xray_core
  step_03_setup_credentials
  step_04_write_config
  step_05_harden_systemd
  step_06_configure_firewall
  step_07_configure_fail2ban
  step_08_kernel_tuning
  step_09_daily_reboot
  install_reality_shortcut

  # Print the client link/QR and all summary info first, and restart
  # xray as the literal last action of the whole script.
  finish_and_restart "conditional"
  print_install_complete_summary
  echo ""
  echo "${C_CYAN}Done in $(elapsed_time).${C_RESET}"
}

mode_rotate_uuid() {
  step "rotate-uuid" "Rotating UUID + short ID (REALITY keypair unchanged)"
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "No existing REALITY keypair found in state. Run a full install first."
    exit 1
  fi
  backup_current_state
  generate_uuid_and_shortid
  write_config
  finish_and_restart "always"
  echo ""
  echo "Old client link is now invalid. Any device using it must import the new link above."
}

mode_rotate_all() {
  if [[ -t 0 ]]; then
    echo ""
    warn "This invalidates EVERY existing client link. Not undoable except by --restore."
    local confirm_rotate_all
    read -r -p "Type 'yes' to continue: " confirm_rotate_all
    if [[ "$confirm_rotate_all" != "yes" ]]; then
      echo "Cancelled. No changes made."
      return 0
    fi
  fi
  step "rotate-all" "Rotating ALL credentials (UUID, short ID, REALITY keypair)"
  backup_current_state
  generate_uuid_and_shortid
  generate_reality_keypair
  write_config
  finish_and_restart "always"
  echo ""
  echo "All previous client links are now permanently invalid."
}

mode_show() {
  if [[ -z "$UUID" || -z "$PUBLIC_KEY" ]]; then
    err "No saved state found (${STATE_FILE}). Run a full install first."
    exit 1
  fi
  output_client_info
}

mode_list_backups() {
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    return 0
  fi
  echo "Available backups (use with --restore <timestamp>):"
  local dir ts contents
  for dir in "$BACKUP_ROOT"/*/; do
    ts=$(basename "$dir")
    contents=$(ls "$dir" 2>/dev/null | tr '\n' ' ')
    echo "  ${ts}   (${contents})"
  done
}

mode_dedupe_backups() {
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    return 0
  fi

  step "dedupe" "Scanning backups for redundant consecutive duplicates"

  # Only collapses a *consecutive run* of identical config.json content
  # (e.g. from repeated no-op 'reality' re-runs before the backup-skip
  # fix) down to the most recent one in that run. Two backups with
  # matching content that AREN'T consecutive -- meaning something
  # changed and then changed back -- are left alone, since they
  # represent genuinely different points in history that happen to
  # coincide.
  local all_backups
  mapfile -t all_backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

  local prev_hash="" prev_dir="" removed_count=0 kept_count=0 dir current_hash
  for dir in "${all_backups[@]}"; do
    if [[ ! -f "${dir}/config.json" ]]; then
      prev_hash=""
      prev_dir=""
      continue
    fi
    current_hash=$(sha256sum "${dir}/config.json" 2>/dev/null | awk '{print $1}')

    if [[ -n "$prev_hash" && "$current_hash" == "$prev_hash" ]]; then
      # This one matches the previous one in sequence -- the previous
      # backup is now redundant (this one is strictly newer with the
      # same content), so remove the previous one and keep this one as
      # the new "most recent representative" of the run.
      rm -rf "$prev_dir"
      removed_count=$((removed_count + 1))
    else
      kept_count=$((kept_count + 1))
    fi
    prev_hash="$current_hash"
    prev_dir="$dir"
  done

  ok "Removed ${removed_count} redundant backup(s), kept ${kept_count}."
}

mode_restore() {
  local restore_dir="${BACKUP_ROOT}/${RESTORE_TS}"
  if [[ ! -d "$restore_dir" ]]; then
    err "No backup found at ${restore_dir}."
    echo "       Run --list-backups to see available timestamps." >&2
    exit 1
  fi
  if [[ ! -f "${restore_dir}/config.json" ]]; then
    err "${restore_dir} doesn't contain a config.json -- can't restore from it."
    exit 1
  fi

  step "restore" "Restoring from backup: ${RESTORE_TS}"
  # Back up the current (about-to-be-overwritten) state too, so
  # restoring is itself undoable.
  backup_current_state

  if ! jq empty "${restore_dir}/config.json" >/dev/null 2>&1; then
    err "Backed-up config.json at ${restore_dir} is not valid JSON. Not restoring."
    exit 1
  fi

  # Same schema-level check write_config uses -- jq only confirms JSON
  # syntax, not that Xray's own schema still accepts this backup (e.g.
  # if it predates a field rename). Format must be specified explicitly
  # since this path doesn't end in .json.
  if command -v xray >/dev/null 2>&1; then
    if ! RESTORE_TEST_OUTPUT=$(xray run -test -format json -config "${restore_dir}/config.json" 2>&1); then
      err "Backed-up config.json at ${restore_dir} fails Xray's own schema check. Not restoring:"
      echo "$RESTORE_TEST_OUTPUT" | sed 's/^/  /' >&2
      exit 1
    fi
  fi

  cp -a "${restore_dir}/config.json" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  [[ -f "${restore_dir}/state" ]] && cp -a "${restore_dir}/state" "$STATE_FILE" && chmod 600 "$STATE_FILE"
  [[ -f "${restore_dir}/client-info.txt" ]] && cp -a "${restore_dir}/client-info.txt" "$CLIENT_INFO_FILE" && chmod 600 "$CLIENT_INFO_FILE"

  restart_and_verify
  echo ""
  echo "Restored from ${RESTORE_TS}. Run --show to reprint the restored client link."
}


# =============================================================================
# SECTION 10: MAIN ENTRY POINT
# =============================================================================

main() {
  parse_arguments "$@"
  banner
  run_preflight_checks
  load_state

  case "$MODE" in
    install)         mode_install ;;
    rotate-uuid)      mode_rotate_uuid ;;
    rotate-all)       mode_rotate_all ;;
    show)             mode_show ;;
    list-backups)     mode_list_backups ;;
    dedupe-backups)   mode_dedupe_backups ;;
    restore)          mode_restore ;;
    *)
      err "Internal error: unknown mode '${MODE}'."
      exit 1
      ;;
  esac
}

main "$@"
