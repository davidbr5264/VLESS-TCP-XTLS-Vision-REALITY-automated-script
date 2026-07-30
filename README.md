# VLESS-TCP-XTLS-Vision-REALITY Setup

Automated installer for a hardened Xray REALITY proxy on a Debian/Ubuntu VPS. Personal use.

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/davidbr5264/VLESS-TCP-XTLS-Vision-REALITY-automated-script/master/setup-xray-reality.sh)
```

Run as root. On a fresh install, you'll be prompted for a camouflage domain (SNI) with a sensible default — press Enter to accept it. Prints a `vless://` link + QR code when done.

## What it sets up

- Xray-core (VLESS + REALITY + XTLS-Vision), camouflaged as a real site, validated against Xray's own config schema (not just JSON syntax) before every restart
- Dual-stack listener (IPv4 + IPv6)
- Encrypted DNS (DoH) so domain lookups aren't visible in cleartext
- Outbound blackhole for cloud metadata (169.254.169.254) and private IP ranges, with `IPIfNonMatch` domain resolution so a domain that resolves to a private IP is caught too, not just IP literals
- Runs as a dedicated unprivileged user, not root
- UFW firewall (SSH + Xray port only, with a port-conflict check before binding) and fail2ban for SSH
- Hardened systemd service: sandboxed, auto-restart on failure, no core dumps, local alert if it exhausts its restart attempts
- BBR congestion control and sysctl/kernel hardening
- NTP sync check (REALITY handshakes are timestamp-sensitive)
- Daily reboot at midnight, capped journal size, log rotation, pruned backups (most recent 15 kept)
- A `reality` shortcut command for re-running/managing the setup
- A lock file so two concurrent runs can't race on the same files

## Usage

```bash
reality                  # re-apply setup (keeps existing credentials)
reality --rotate-uuid    # revoke current client link, keep server identity
reality --rotate-all     # full credential reset, invalidates everything (asks for confirmation)
reality --show           # reprint current client link + QR
reality --list-backups   # list available backups
reality --restore <ts>   # restore config/state from a backup (schema-validated first)
```

Every state-changing run backs up the previous config first.

## Requirements

- Debian or Ubuntu VPS, root access, 1GB+ free disk space

## Security notes

- Keep `/root/xray-client-info.txt` private; it contains your private key.
- Don't run anything else on port 443 — REALITY needs to be the only thing answering there.
- The interactive SNI prompt does a best-effort live check (DNS + TLS1.3 handshake) on whatever domain you enter, but ultimately trusts you if you choose to proceed anyway.
- **Trust model**: this installs Xray-core via `curl | bash` from the official XTLS installer, and this script itself is typically run the same way. Neither is signature-verified — this is the standard (if imperfect) trust model for scripts like this. Read the script before running it if that matters to you.
