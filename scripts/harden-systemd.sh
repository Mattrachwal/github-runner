#!/usr/bin/env bash
set -Eeuo pipefail

# Optional extra hardening knobs for all runner instances via drop-in
# Safe defaults; extend as you see fit.

need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }
need_root

install -d -m 0755 /etc/systemd/system/github-runner@.service.d

tee /etc/systemd/system/github-runner@.service.d/security.conf >/dev/null <<'EOF'
[Service]
# Conservative resource ceilings (tweak as needed)
# MemoryMax=4G
# CPUQuota=80%

# Extra sandboxing (be careful tightening further: runner needs network & git)
PrivateDevices=yes
ProtectHostname=yes
ProtectClock=yes
RestrictRealtime=yes
SystemCallArchitectures=native
EOF

systemctl daemon-reload
echo "[harden] Applied security.conf drop-in. Restarting runner services..."
systemctl restart 'github-runner@*' || true
