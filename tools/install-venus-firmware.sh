#!/bin/sh
# 装 venus（视频编解码）固件：modem 分区 image/venus.mdt + bNN -> /lib/firmware/qcom/sm8250/umi/
set -e
DST=/lib/firmware/qcom/sm8250/umi
mount -o ro /dev/disk/by-partlabel/modem /mnt/probe 2>/dev/null || true
IMG=/mnt/probe/image
[ -d "$IMG" ] || { echo "!! image/ 不在"; exit 1; }

mkdir -p "$DST"
echo "== modem 里的 venus 文件:"
ls -l "$IMG"/venus.* | awk '{printf "  %-22s %9d\n", $NF, $5}'

cp -f "$IMG/venus.mdt" "$DST/venus.mbn"
for f in "$IMG"/venus.b[0-9][0-9]; do
	[ -e "$f" ] || continue
	cp -f "$f" "$DST/"
done

echo "== 安装结果:"
ls -l "$DST"/venus.* | awk '{printf "  %-22s %9d\n", $NF, $5}'
echo "== 总大小:"
du -sh "$DST"/venus.* 2>/dev/null | tail -1

umount /mnt/probe 2>/dev/null || true
