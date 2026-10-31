#!/bin/sh
# 找 adsp.mbn / slpi.mbn / cdsp.mbn 落在哪块分区上（只读挂载，不改任何东西）
for p in dsp modem super bluetooth vendor; do
	d=$(readlink -f /dev/disk/by-partlabel/$p 2>/dev/null)
	[ -b "$d" ] || continue
	printf '%-10s %-10s %8s  %s\n' "$p" "$(basename "$d")" \
		"$(blockdev --getsize64 "$d" 2>/dev/null | awk '{printf "%.0fMB", $1/1048576}')" \
		"$(blkid -o value -s TYPE "$d" 2>/dev/null)"
done

echo "=== 尝试只读挂载:"
for p in dsp modem; do
	d=$(readlink -f /dev/disk/by-partlabel/$p 2>/dev/null)
	[ -b "$d" ] || continue
	mkdir -p /mnt/probe
	mount -o ro,nosuid,nodev "$d" /mnt/probe 2>/dev/null || { echo "$p: mount failed"; continue; }
	echo "--- $p 顶层:"
	ls /mnt/probe | head -6
	echo "--- $p 里 .mbn/.mdt 前 10 个:"
	find /mnt/probe -maxdepth 3 \( -name '*.mbn' -o -name '*.mdt' -o -name 'adsp*' -o -name 'slpi*' \) 2>/dev/null | head -10
	umount /mnt/probe
done
