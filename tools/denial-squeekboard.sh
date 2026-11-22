#!/bin/sh
# 在 Denial 会话里自动启动 squeekboard（屏幕键盘）。
#
# 为什么需要：Denial 自己不画键盘，它只导出 zwp_input_method_v2 /
# zwp_virtual_keyboard_v1 / zwlr_layer_shell_v1，把键盘交给外部实现。
# squeekboard 这三个协议都支持，所以只要在 Denial 的 Wayland 会话里跑起来就有键盘。
#
# 用 systemd --user 的 unit 挂在 denial-session.target 上，这样：
#   - 它继承会话的 WAYLAND_DISPLAY / XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS；
#   - Denial 重启时它跟着重启。
set -u

mkdir -p /home/colorgarden/.config/systemd/user

cat > /home/colorgarden/.config/systemd/user/squeekboard.service <<'EOF'
[Unit]
Description=Squeekboard on-screen keyboard
PartOf=denial-session.target
After=denial-session.target
Requires=denial-session.target

[Service]
Type=simple
ExecStart=/usr/bin/squeekboard
Restart=on-failure
RestartSec=3

[Install]
WantedBy=denial-session.target
EOF

chown colorgarden:colorgarden /home/colorgarden/.config/systemd/user/squeekboard.service

echo "=== 单元已写，启用（需要用户 manager 在线）"
runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/1001 \
	systemctl --user daemon-reload 2>&1 | tail -1
runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/1001 \
	systemctl --user enable squeekboard.service 2>&1 | tail -1
echo "=== 状态"
runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/1001 \
	systemctl --user is-enabled squeekboard.service 2>&1
