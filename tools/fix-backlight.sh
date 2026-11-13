#!/bin/sh
# 背光持久化：systemd-backlight 会保存/恢复亮度，默认存的是那个几乎看不见的 80
set -u
B=/sys/class/backlight/umi-panel
SAVE=/var/lib/systemd/backlight

echo "=== 1) 现状"
echo "  brightness=$(cat $B/brightness) max=$(cat $B/max_brightness)"
echo "  保存值目录: $(ls -l $SAVE 2>/dev/null | head -5)"

echo
echo "=== 2) 看 systemd-backlight 单元"
systemctl is-enabled systemd-backlight@backlight:umi-panel.service 2>&1
systemctl status systemd-backlight@backlight:umi-panel.service --no-pager 2>&1 | head -6

echo
echo "=== 3) 写入合理的默认亮度（60%）并保存"
VAL=$(( $(cat $B/max_brightness) * 60 / 100 ))
echo "$VAL" > "$B/brightness"
mkdir -p "$SAVE"
for f in "$SAVE"/*backlight*; do [ -e "$f" ] && echo "$VAL" > "$f" && echo "  更新 $f"; done
echo "  已写入 $VAL，保存文件: $(for f in "$SAVE"/*backlight*; do echo -n "$f=$(cat "$f") "; done)"

echo
echo "=== 4) 启用 systemd-backlight（开机恢复这个值）"
systemctl enable systemd-backlight@backlight:umi-panel.service 2>&1 | tail -2
echo
echo "=== 5) 最终"
echo "  brightness=$(cat $B/brightness)/$(cat $B/max_brightness) bl_power=$(cat $B/bl_power)"
