#!/bin/sh
# 把 Plasma Mobile 交给 systemd 管（和 phosh.service 同一形态）
#   PAMName=login 才会由 pam_systemd 开出一个真正的 logind session，
#   seat0/设备 ACL/DRM master 全靠它（缺了就是黑屏 + 无输入）。
set -u

cat > /etc/systemd/system/plasmamobile.service <<'EOF'
[Unit]
Description=Plasma Mobile (tty7)
After=systemd-user-sessions.service
Wants=user@1001.service
After=user@1001.service
Conflicts=getty@tty7.service phosh.service
StartLimitIntervalSec=0

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
TTYVTDisallocate=yes
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_DESKTOP=KDE
Environment=XDG_CURRENT_DESKTOP=KDE
ExecStart=/bin/sh -c 'mkdir -p /run/user/1001 && chown colorgarden:colorgarden /run/user/1001 && chmod 700 /run/user/1001; export XDG_RUNTIME_DIR=/run/user/1001; for i in $(seq 1 120); do grep -lq connected /sys/class/drm/card*-DSI-*/status 2>/dev/null && break; sleep 0.5; done; echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true; exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile'
# plasmashell 由 systemd --user 管（plasma-plasmashell.service）。它被重启时
# 不会继承会话环境，缺 WAYLAND_DISPLAY 就会回退 xcb、abort、撞 start-limit，
# 最终把整个会话带崩。这里在 kwin 起来后把 WAYLAND_DISPLAY 导入用户管理器。
ExecStartPost=-/bin/sh -c 'for i in $(seq 1 60); do [ -S /run/user/1001/wayland-1 ] && break; sleep 0.5; done; runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 systemctl --user import-environment WAYLAND_DISPLAY'
# 开机时活动 VT 往往还停在 tty1（fbcon 在用 DRM），必须显式激活会话并切到 tty7，
# 否则 kwin 已经跑起来但画面留在控制台。
ExecStartPost=-/bin/sh -c 'sleep 8; S=$(loginctl list-sessions --no-legend 2>/dev/null | awk "/colorgarden/{print \$1}" | tail -1); [ -n "$S" ] && loginctl activate "$S" 2>/dev/null; chvt 7 2>/dev/null; true'
Restart=always
RestartSec=3
TimeoutStopSec=10
KillMode=control-group
# 重启时最恶心的问题：旧 logind 会话还占着 tty1，新会话在 pam_systemd 里
# 直接报 VirtualTerminalAlreadyTaken -> 没有 seat/DRM -> kwin "Could not create
# wayland socket" 并 abort。停止后把该用户残留的会话全部终止，保证下一次能起。
ExecStopPost=-/bin/sh -c 'sleep 1; loginctl list-sessions --no-legend 2>/dev/null | awk "/colorgarden/{print \$1}" | xargs -r -n1 loginctl terminate-session >/dev/null 2>&1; true'

[Install]
WantedBy=graphical.target
EOF

cat > /etc/tmpfiles.d/umi-runtime.conf <<'EOF2'
d /run/user/1001 0700 colorgarden colorgarden -
EOF2
systemd-tmpfiles --create /etc/tmpfiles.d/umi-runtime.conf 2>/dev/null || true
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/plasmamobile.service 2>&1 | head -3
systemctl disable phosh.service >/dev/null 2>&1 || true
systemctl enable plasmamobile.service 2>&1 | tail -1
echo "=== 单元状态:"
systemctl is-enabled plasmamobile.service phosh.service 2>&1
