#!/bin/sh
# 在 vendor 里精确找 DSP 固件（只读 loop + debugfs）
SUPER=/dev/disk/by-partlabel/super
EXT=$(python3 /tmp/lp-info.py vendor)
SECT=$(echo "$EXT" | sed -n 's/.*target_sector=\([0-9]*\).*/\1/p')
NUM=$(echo "$EXT" | sed -n 's/.*sectors=\([0-9]*\).*/\1/p')
LOOP=$(losetup -r -f --show --offset $((SECT*512)) --sizelimit $((NUM*512)) "$SUPER")
echo "loop=$LOOP"

echo "=== /firmware 里的 mbn/jsn/bNN:"
debugfs -R "ls -l /firmware" "$LOOP" 2>/dev/null | awk '$NF ~ /\.(mbn|jsn|b[0-9][0-9])$/ || $NF ~ /^(adsp|cdsp|slpi|modem)/ {print $NF, $5}'

echo "=== /bt_firmware:"
debugfs -R "ls -l /bt_firmware" "$LOOP" 2>/dev/null | awk 'NF>6 {print $NF, $5}'

echo "=== /dsp:"
debugfs -R "ls -l /dsp" "$LOOP" 2>/dev/null | awk 'NF>6 {print $NF, $5}' | head -10

echo "=== 关键文件是否存在:"
for f in /firmware/adsp.mbn /firmware/cdsp.mbn /firmware/slpi.mbn \
         /firmware/a650_sqe.fw /firmware/a650_gmu.bin /firmware/adsp.jsn; do
	r=$(debugfs -R "stat $f" "$LOOP" 2>/dev/null | head -2 | tr '\n' ' ')
	[ -n "$r" ] && echo "  $f -> ${r:0:90}"
done

losetup -d "$LOOP"
