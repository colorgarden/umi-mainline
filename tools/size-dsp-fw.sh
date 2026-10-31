#!/bin/sh
# 统计 modem 分区 image/ 里各 DSP 组件的文件数与总大小
mount -o ro /dev/disk/by-partlabel/modem /mnt/probe 2>/dev/null || true
IMG=/mnt/probe/image
[ -d "$IMG" ] || { echo "image/ 不在"; exit 1; }

echo "=== 组件（去掉 b01/mdt/jsn 后缀）:"
ls "$IMG" | sed 's/\.\(b[0-9][0-9]\|mdt\|mbn\|jsn\|bs\)$//' | sort -u | head -24

echo "=== 各组件:"
for c in adsp cdsp slpi venus a650_zap ipa_fws; do
	set -- "$IMG"/$c.*
	[ -e "$1" ] || continue
	n=$#
	sz=$(ls -l "$IMG"/$c.* 2>/dev/null | awk '{t+=$5} END {print t+0}')
	echo "  $c: $n files, $((sz / 1048576)) MB"
done

echo "=== adsp 明细:"
ls -l "$IMG"/adsp.* | awk '{printf "  %-28s %8d\n", $NF, $5}' | head -6
echo "  ..."
ls -l "$IMG"/adsp.* | awk '{printf "  %-28s %8d\n", $NF, $5}' | tail -3

echo "=== jsn/bs/其他:"
ls "$IMG" | grep -E '\.(jsn|bs|elf)$' | head -10

umount /mnt/probe 2>/dev/null || true
