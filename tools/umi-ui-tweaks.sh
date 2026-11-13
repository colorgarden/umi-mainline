#!/bin/sh
# 把体感相关的设置固化（重启后仍然生效）
set -u
U=1001
asuser() { runuser -u colorgarden -- env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus "$@"; }

echo "=== 1) GPU 提到最低 = 最高频（无 cpufreq 时这是 UI 跟手的关键）"
cat > /etc/systemd/system/umi-gpu-perf.service <<'EOF'
[Unit]
Description=Keep Adreno GPU at its max frequency (UI responsiveness)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'G=/sys/class/devfreq/3d00000.gpu; [ -e "$G" ] && cat "$G/max_freq" > "$G/min_freq"'
ExecStop=/bin/sh -c 'G=/sys/class/devfreq/3d00000.gpu; [ -e "$G" ] && echo 305000000 > "$G/min_freq"'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now umi-gpu-perf.service 2>&1 | tail -1
echo "  min=$(cat /sys/class/devfreq/3d00000.gpu/min_freq) cur=$(cat /sys/class/devfreq/3d00000.gpu/cur_freq)"

echo
echo "=== 2) 状态栏电量百分比 / 通知横幅 / 关闭热角"
asuser gsettings set org.gnome.desktop.interface show-battery-percentage true
asuser gsettings set org.gnome.desktop.notifications show-banners true
asuser gsettings set org.gnome.desktop.interface enable-hot-corners false 2>/dev/null || true

echo
echo "=== 3) 回读"
for kv in "org.gnome.desktop.interface show-battery-percentage" "org.gnome.desktop.interface font-name" "org.gnome.desktop.interface color-scheme" "org.gnome.desktop.background picture-uri"; do
	set -- $kv
	printf '  %-22s %s\n' "$2" "$(asuser gsettings get "$1" "$2" 2>&1)"
done

echo
echo "=== 4) 当前桌面：壁纸/收藏夹"
echo "  favorites: $(asuser gsettings get sm.puri.phosh favorites 2>&1)"
echo "  壁纸文件: $(ls -l /home/colorgarden/Pictures/wallpaper.png 2>/dev/null | awk '{print $5" 字节"}')"

echo
echo "=== 5) 重启桌面（应用壁纸 + 收藏夹）"
systemctl restart phosh.service
sleep 16
echo "  active=$(systemctl is-active phosh.service) phoc=$(pgrep -x phoc | head -1)"
