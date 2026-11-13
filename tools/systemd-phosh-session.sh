#!/bin/sh
# 桌面交给 systemd 管（系统级 unit + PAMName=login）
#
# 为什么必须是这个形态（这次是结论，不是猜）：
#   phoc 通过 libseat 拿 DRM master 和输入设备，而 libseat 的 logind 后端要求
#   进程位于一个 logind session（session-*.scope）里。systemd --user 的单元跑在
#   user@1001.service/app.slice 下，不在 session 里 -> DRM 原子提交全部被拒
#   （journal 里 'Atomic commit failed'），背光被关（bl_power=4），黑屏；
#   同时没人 inhibit 电源键，logind 按 HandlePowerKey=poweroff 直接关机。
#
#   系统级 unit 加 PAMName=login 时，pam_systemd 会**新开一个 session**，
#   服务的进程就落在这个 session 的 scope 里，seat/ACL/DRM master 全都正常。
#
# 前提：tty1 上不能再有 getty（否则抢 TTY，单元起来即退）。
# 应急：tty2 保留 getty，SSH 一直在。
set -u

echo "=== 1) 系统级 phosh.service"
cat > /etc/systemd/system/phosh.service <<'EOF'
[Unit]
Description=Phosh mobile desktop (tty1)
After=systemd-user-sessions.service
Conflicts=getty@tty1.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=colorgarden
# PAMName=login 让 pam_systemd 开一个真正的 logind session：
# seat0 归属、XDG_RUNTIME_DIR、设备 ACL、DRM master 都靠它
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SESSION_DESKTOP=phosh
ExecStart=/usr/local/bin/umi-session
Restart=always
RestartSec=3
TimeoutStopSec=5
KillMode=control-group

[Install]
WantedBy=graphical.target
EOF

# 桌面没起来时按电源键不要直接关机（默认 HandlePowerKey=poweroff）
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/umi.conf <<'EOF'
[Login]
HandlePowerKey=ignore
EOF

echo "=== 2) 彻底让出 tty1：禁掉 getty 并去掉自动登录"
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
systemctl disable getty@tty1 >/dev/null 2>&1 || true
systemctl mask getty@tty1 >/dev/null 2>&1 || true

echo "=== 3) 应急控制台 tty2"
systemctl enable getty@tty2 >/dev/null 2>&1 || true

echo "=== 4) 关掉 user unit 那条路 + 清兜底计数"
mkdir -p /root/lib-backup/session-user-systemd
mv -f /etc/systemd/user/phosh.service /root/lib-backup/session-user-systemd/phosh.service.disabled 2>/dev/null || true
rm -f /etc/systemd/user/graphical-session.target.wants/phosh.service
rm -f /run/umi-session-fail

echo "=== 5) 检查单元语法并启用"
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/phosh.service 2>&1 | head -5
systemctl enable phosh.service 2>&1 | tail -1

echo
echo "=== 6) 重启进新路径（SSH 会断 ~70 秒）"
sync
reboot -f
