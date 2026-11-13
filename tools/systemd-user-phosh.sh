#!/bin/sh
# 桌面交给 systemd --user 管（最终版，幂等）
#
# 设计：
#   getty 自动登录（保留，因为它正确创建 logind session / seat / XDG_RUNTIME_DIR）
#   -> ~/.zprofile 起 phosh.service（user unit）
#   -> phosh-session 跑 phoc + gnome-session，Restart=always 自愈
#
# 踩过的三个坑（都实测过）：
#   1) 系统级 unit + PAMName=login：会和 tty1 上已有会话/seat 打架，单元 1 秒即
#      "Deactivated successfully"，桌面起不来 -> 放弃这条路。
#   2) PartOf=graphical-session.target：主进程一死，systemd 把它当"被 stop"，
#      Restart 永远不触发（日志只有 Stopped，没有 Scheduled restart）-> 去掉。
#   3) phoc 收到 SIGTERM 会做退出时的 DRM atomic commit，失败后不退出，
#      默认 15s 停不下来 -> TimeoutStopSec=5 + KillMode=control-group。
set -u
uid=$(id -u colorgarden)
asuser() { runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/"$uid" "$@" 2>&1; }

echo "=== 1) user 单元 /etc/systemd/user/phosh.service"
mkdir -p /etc/systemd/user /etc/systemd/user/graphical-session.target.wants
cat > /etc/systemd/user/phosh.service <<'EOF'
[Unit]
Description=Phosh mobile desktop
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/phosh-session
Restart=always
RestartSec=5
TimeoutStopSec=5
KillMode=control-group

[Install]
WantedBy=graphical-session.target
EOF
ln -sf /etc/systemd/user/phosh.service /etc/systemd/user/graphical-session.target.wants/phosh.service

echo "=== 2) ~/.zprofile"
cat > /home/colorgarden/.zprofile <<'EOF'
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN

# tty1 自动登录后：桌面交给 systemd --user 管（崩了自动重启，可 systemctl --user restart phosh）
if [ -z "${WAYLAND_DISPLAY}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
	systemctl --user start phosh.service
	# 保持 logind session 存活：seat / XDG_RUNTIME_DIR 由它提供
	exec sleep infinity
fi
EOF
chown colorgarden:colorgarden /home/colorgarden/.zprofile
chmod 644 /home/colorgarden/.zprofile

echo "=== 3) 状态"
echo "  user manager : $(asuser systemctl --user is-system-running | head -1)"
echo "  phosh.service: $(asuser systemctl --user is-active phosh.service)"
echo "  phoc: $(pgrep -x phoc | head -1)  phosh: $(pgrep -x phosh | head -1)"
echo "  wayland: $(ls /run/user/"$uid"/wayland-0 2>/dev/null || echo 缺)"
