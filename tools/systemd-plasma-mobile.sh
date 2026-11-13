#!/bin/sh
# 把 Plasma Mobile 交给 systemd 管（和 phosh.service 同一形态）
#   PAMName=login 才会由 pam_systemd 开出一个真正的 logind session，
#   seat0/设备 ACL/DRM master 全靠它（缺了就是黑屏 + 无输入）。
set -u

cat > /etc/systemd/system/plasmamobile.service <<'EOF'
[Unit]
Description=Plasma Mobile (tty1)
After=systemd-user-sessions.service
Conflicts=getty@tty1.service phosh.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=colorgarden
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_DESKTOP=KDE
Environment=XDG_CURRENT_DESKTOP=KDE
ExecStart=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
# plasmashell 由 systemd --user 管（plasma-plasmashell.service）。它被重启时
# 不会继承会话环境，缺 WAYLAND_DISPLAY 就会回退 xcb、abort、撞 start-limit，
# 最终把整个会话带崩。这里在 kwin 起来后把 WAYLAND_DISPLAY 导入用户管理器。
ExecStartPost=-/bin/sh -c 'for i in $(seq 1 60); do [ -S /run/user/1001/wayland-1 ] && break; sleep 0.5; done; runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 systemctl --user import-environment WAYLAND_DISPLAY'
Restart=always
RestartSec=3
TimeoutStopSec=10
KillMode=control-group

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/plasmamobile.service 2>&1 | head -3
systemctl disable phosh.service >/dev/null 2>&1 || true
systemctl enable plasmamobile.service 2>&1 | tail -1
echo "=== 单元状态:"
systemctl is-enabled plasmamobile.service phosh.service 2>&1
