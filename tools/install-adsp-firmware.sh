#!/bin/sh
# 从 modem 分区把 ADSP 固件装到 /lib/firmware/qcom/sm8250/umi/
#   adsp.mdt -> adsp.mbn（mainline 的 qcom_mdt_load 认 .mbn 前缀，段名 adsp.bNN）
set -e
DST=/lib/firmware/qcom/sm8250/umi
mount -o ro /dev/disk/by-partlabel/modem /mnt/probe 2>/dev/null || true
IMG=/mnt/probe/image
[ -d "$IMG" ] || { echo "!! image/ 不在"; exit 1; }

mkdir -p "$DST"

echo "== 复制 adsp:"
cp -f "$IMG/adsp.mdt" "$DST/adsp.mbn"
for f in "$IMG"/adsp.b[0-9][0-9]; do
	[ -e "$f" ] || continue
	cp -f "$f" "$DST/"
done
ls -l "$DST" | awk '{printf "  %-20s %9d\n", $NF, $5}' | head -22

echo "== 校验段号连续性:"
miss=0
i=0
while [ "$i" -le 99 ]; do
	n=$(printf "adsp.b%02d" "$i")
	[ -f "$DST/$n" ] || { [ "$i" -le 18 ] && { echo "  缺 $n"; miss=1; }; }
	i=$((i + 1))
done
[ "$miss" = 0 ] && echo "  b00..b18 齐全"

echo "== jsn（mainline 不用，留着给以后 pas 配置）:"
[ -f "$IMG/adsp.jsn" ] && cp -f "$IMG/adsp.jsn" "$DST/" || true
ls "$IMG"/adsp*.jsn 2>/dev/null | head -3

umount /mnt/probe 2>/dev/null || true
echo "== done: $DST"
