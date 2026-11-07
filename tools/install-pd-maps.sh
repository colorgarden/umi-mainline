#!/bin/sh
# 把音频需要的 jsn 装到 /lib/firmware（pd-mapper 的 PD 地图来源）
# 这些文件来自 modem 分区 image/*.jsn（adspr/adspua/cdspr/slpir/slpius）
set -e
mount -o ro /dev/disk/by-partlabel/modem /mnt/probe 2>/dev/null || true
mkdir -p /lib/firmware/qcom/sm8250/umi

n=0
for f in /mnt/probe/image/*.jsn; do
	[ -e "$f" ] || continue
	cp -f "$f" /lib/firmware/
	cp -f "$f" /lib/firmware/qcom/sm8250/umi/
	n=$((n + 1))
done
chmod 644 /lib/firmware/*.jsn 2>/dev/null || true
umount /mnt/probe 2>/dev/null || true

echo "装了 $n 个 jsn:"
ls -l /lib/firmware/*.jsn | awk '{printf "  %-24s %6d\n", $NF, $5}'

echo
echo "重启 pd-mapper（它启动时扫一次 /lib/firmware）:"
systemctl restart pd-mapper
sleep 2
systemctl is-active pd-mapper
journalctl -u pd-mapper -n 3 --no-pager 2>/dev/null | tail -3
