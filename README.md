# VLESS-TCP-XTLS-Vision-REALITY Setup

Automated installer for a hardened Xray REALITY proxy on a Debian/Ubuntu VPS. Personal use.

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/davidbr5264/VLESS-TCP-XTLS-Vision-REALITY-automated-script/master/setup-xray-reality.sh)
```

Run as root. Prints a `vless://` link + QR code when done.

## What it sets up

- Xray-core (VLESS + TCP + XTLS-Vision + REALITY), camouflaged as a real site
- Encrypted DNS (DoH) so domain lookups aren't visible in cleartext
- Outbound blackhole for cloud metadata (169.254.169.254) and private IP ranges
- Runs as a dedicated unprivileged user, not root
- UFW firewall (SSH + Xray port only) and fail2ban for SSH
- Hardened systemd service: sandboxed, auto-restart on failure, no core dumps
- BBR congestion control and sysctl/kernel hardening
- NTP sync check (REALITY handshakes are timestamp-sensitive)
- Daily reboot at midnight, capped journal size, log rotation
- A `reality` shortcut command for re-running/managing the setup

## Usage

```bash
reality                  # re-apply setup (keeps existing credentials)
reality --rotate-uuid    # revoke current client link, keep server identity
reality --rotate-all     # full credential reset, invalidates everything
reality --show           # reprint current client link + QR
reality --list-backups   # list available backups
reality --restore <ts>   # restore config/state from a backup
```

Every run backs up the previous config to `/root/xray-backups/` first (most recent 15 kept).

## Requirements

- Debian or Ubuntu VPS, root access, 1GB+ free disk space

## Security notes

- Keep `/root/xray-client-info.txt` private; it contains your private key.
- Don't run anything else on port 443 — REALITY needs to be the only thing answering there.
- **Trust model**: this installs Xray-core via `curl | bash` from the official XTLS installer, and this script itself is typically run the same way. Neither is signature-verified — this is the standard (if imperfect) trust model for scripts like this. Read the script before running it if that matters to you.
