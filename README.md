# VLESS-TCP-XTLS-Vision-REALITY-automated-script

What it does, end to end:

Installs latest Xray-core from the official XTLS installer
Generates UUID, REALITY x25519 keypair, and a random short ID
Writes config.json: VLESS + TCP + XTLS-Vision + REALITY, listening on 443, camouflaged as i.ytimg.com
Turns off access logging ("access": "none") — only warnings/errors are logged, no per-connection metadata
Hardens the systemd unit: ProtectSystem=strict, NoNewPrivileges, MemoryDenyWriteExecute, capability-bound to only CAP_NET_BIND_SERVICE, etc.
Sets up UFW allowing only your current SSH port + 443
Installs fail2ban with an sshd jail (5 tries / 1h ban)
Enables BBR + fq qdisc, plus standard sysctl network hardening (disables redirects, source routing, enables syn cookies)
Prints a vless:// link and a terminal QR code, and saves both to /root/xray-client-info.txt (chmod 600, contains your private key — keep it off shared machines)
