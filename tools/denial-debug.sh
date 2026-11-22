#!/bin/sh
# 用与 denial.service 相同的会话形态（PAMName=login + TTYPath）跑一次，
# 但把 deniald 的 stdout/stderr 完整落到文件，便于定位 status=134 的原因。
set -u

cat > /etc/systemd/system/denial-debug.service <<'EOF'
[Unit]
Description=Denial debug capture
After=systemd-user-sessions.service
Conflicts=getty@tty7.service denial.service

[Service]
Type=simple
User=colorgarden
PAMName=login
TTYPath=/dev/tty7
StandardInput=tty
TTYReset=yes
TTYVHangup=yes
Environment=XDG_SESSION_TYPE=wayland
Environment=DENIAL_SHELL_PROFILE=mobile
Environment=RUST_BACKTRACE=full
Environment=RUST_LOG=deniald=debug,smithay=debug,libseat=debug
ExecStart=/bin/sh -c 'exec /usr/bin/denial-session >/var/log/denial-debug.log 2>&1'
TimeoutStopSec=10
EOF

systemctl daemon-reload
systemctl reset-failed denial-debug 2>/dev/null || true
systemctl start denial-debug 2>&1 | tail -2
sleep 20
systemctl stop denial-debug 2>/dev/null || true
echo "=== 日志尾部"
tail -40 /var/log/denial-debug.log 2>/dev/null
