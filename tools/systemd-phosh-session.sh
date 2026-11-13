#!/bin/sh
# 把桌面会话交给 systemd 管：phosh.service（系统单元，PAMName=login 拿 seat/logind session）
# 失败自动回滚到 getty 自动登录。
set -u
BK=/root/lib-backup/session-pre-systemd
mkdir -p "$BK"

echo "=== 1) 备份现状"
cp -a /etc/systemd/system/getty@tty1.service.d/autologin.conf "$BK/" 2>/dev/null
cp -a /home/colorgarden/.zprofile "$BK/" 2>/dev/null
cp -a /usr/local/bin/umi-session "$BK/" 2>/dev/null
ls -l "$BK"

echo
echo "=== 2) 写 phosh.service"
cat > /etc/systemd/system/phosh.service <<'EOF'
[Unit]
Description=Phosh mobile desktop on tty1
After=systemd-user-sessions.service
Conflicts=getty@tty1.service
StartLimitIntervalSec=60
StartLimitBurst=4

[Service]
Type=simple
User=colorgarden
# 关键：PAMName=login 让 pam_systemd 开出 logind session
# （seat / XDG_RUNTIME_DIR / device 权限都靠它），否则 phoc 拿不到 DRM。
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
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=graphical.target
EOF
systemctl daemon-reload

echo
echo "=== 3) 应急控制台 + 去掉 tty1 自动登录"
systemctl enable getty@tty2 >/dev/null 2>&1
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null
systemctl daemon-reload
sed -i '/umi-session/,+2d; /XDG_VTNR/d; /WAYLAND_DISPLAY/d' /home/colorgarden/.zprofile 2>/dev/null

echo
echo "=== 4) 启用并启动（会顶掉当前 tty1 会话，SSH 不受影响）"
systemctl enable phosh.service
systemctl start phosh.service
sleep 20

echo
echo "=== 5) 验证"
if systemctl is-active phosh.service | grep -q active &&
	pgrep -x phoc >/dev/null 2>&1 && pgrep -x phosh >/dev/null 2>&1; then
	echo "OK: phosh 起来了"
	systemctl status phosh.service --no-pager 2>/dev/null | head -6
	echo "--- 进程:"
	ps -eo pid,comm | grep -E 'phoc|phosh|gnome-session' | head -5
	echo "--- logind session:"
	loginctl list-sessions --no-legend 2>/dev/null | grep -E '1001|colorgarden' | head -3
	echo "--- wayland socket:"
	ls /run/user/1001/wayland-* 2>/dev/null
else
	echo "FAILED: 回滚到 getty 自动登录"
	journalctl -u phosh.service -n 25 --no-pager 2>/dev/null | tail -25
	systemctl stop phosh.service 2>/dev/null
	systemctl disable phosh.service 2>/dev/null
	mkdir -p /etc/systemd/system/getty@tty1.service.d
	cp -a "$BK/autologin.conf" /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null
	cp -a "$BK/.zprofile" /home/colorgarden/.zprofile 2>/dev/null
	systemctl daemon-reload
	systemctl enable --now getty@tty1
	echo "已回滚"
	exit 1
fi
