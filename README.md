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
- UFW firewall (SSH + Xray port only) and fail2ban for SSH
- Hardened systemd service (sandboxed, auto-restart on failure)
- BBR congestion control and basic sysctl hardening
- Daily reboot at midnight
- A `reality` shortcut command for re-running/managing the setup

## Usage

```bash
reality                 # re-apply setup (keeps existing credentials)
reality --rotate-uuid   # revoke current client link, keep server identity
reality --rotate-all    # full credential reset, invalidates everything
reality --show          # reprint current client link + QR
```

Every run backs up the previous config to `/root/xray-backups/` first.

## Requirements

- Debian or Ubuntu VPS, root access

## Notes

- Don't run anything else on port 443 — REALITY needs to be the only thing answering there.
- Keep `/root/xray-client-info.txt` private; it contains your private key.
