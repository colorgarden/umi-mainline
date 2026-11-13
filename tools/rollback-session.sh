#!/bin/sh
# 立刻回滚到已知可用的会话路径（getty -> shell exec phosh-session）
set -u
uid=$(id -u colorgarden)

echo "=== 1) 停掉 user unit，去掉 wants 链接"
runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user stop phosh.service 2>/dev/null || true
runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user disable phosh.service 2>/dev/null || true
rm -f /etc/systemd/user/graphical-session.target.wants/phosh.service
mv /etc/systemd/user/phosh.service /root/lib-backup/session-user-systemd/phosh.service.disabled 2>/dev/null || true

echo "=== 2) 恢复 .zprofile"
mkdir -p /root/lib-backup/session-pre-systemd
cat > /home/colorgarden/.zprofile <<'EOF'
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN

if [ -z "${WAYLAND_DISPLAY}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
	exec /usr/local/bin/umi-session
fi
EOF
chown colorgarden:colorgarden /home/colorgarden/.zprofile
chmod 644 /home/colorgarden/.zprofile

echo "=== 3) 清掉兜底计数（否则会切到 Plasma）"
rm -f /run/umi-session-fail

echo "=== 4) 重启 tty1 会话"
systemctl restart getty@tty1
sleep 25

echo
echo "=== 5) 结果"
phoc_pid=$(pgrep -x phoc | head -1)
echo "  phoc: ${phoc_pid:-无}  phosh: $(pgrep -x phosh | head -1)"
[ -n "${phoc_pid:-}" ] && echo "  phoc cgroup: $(cat /proc/$phoc_pid/cgroup 2>/dev/null)"
echo "  背光: $(for b in /sys/class/backlight/*; do echo -n "$(basename $b) brightness=$(cat $b/brightness 2>/dev/null)/$(cat $b/max_brightness 2>/dev/null) bl_power=$(cat $b/bl_power 2>/dev/null)"; done)"
echo "  wayland: $(ls /run/user/$uid/wayland-0 2>/dev/null || echo 缺)"
echo "  --- 最近的 atomic commit 报错（应为空）:"
journalctl -b -t phoc --no-pager 2>/dev/null | grep -c 'Atomic commit failed'
