#!/bin/sh
# 让 Denial 以真正的 logind 会话（seat0/tty7, Type=wayland）启动。
#
# 为什么必须走 systemd 单元而不是 ssh + setsid：
#   libseat 的 logind 后端要求调用进程属于一个 active 的图形会话，
#   ssh 会话没有 seat，deniald 会拿到 ENOSYS(38) “Failed to open session”。
#   这里照抄 Plasma 那套能工作的形态：PAMName=login + TTYPath=/dev/tty7。
set -u

cat > /etc/systemd/system/denial.service <<'EOF'
[Unit]
Description=Denial (mobile shell)
After=systemd-user-sessions.service
Conflicts=getty@tty7.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=colorgarden
PAMName=login
TTYPath=/dev/tty7
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_DESKTOP=Denial
Environment=XDG_CURRENT_DESKTOP=Denial
Environment=DENIAL_SHELL_PROFILE=mobile
ExecStart=/usr/bin/denial-session
Restart=on-failure
RestartSec=5
TimeoutStopSec=10

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload

# 清掉可能残留的旧会话，避免 VT/seat 冲突
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="colorgarden"{print $1}'); do
	loginctl terminate-session "$s" 2>/dev/null || true
done

systemctl enable denial.service 2>&1 | tail -1
echo "=== 单元已装"
