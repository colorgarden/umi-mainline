#!/bin/sh
# push-modules.sh — 把这一版编出来的内核模块推到手机上
#
#   sh tools/push-modules.sh [PHONE_IP]
#
# 为什么需要它：rootfs 里的 /lib/modules/<版本>/ 是**上一次构建**留下的，
# 版本串能对上、ABI 却已经变了。典型症状：
#   modprobe hci_uart   -> "Exec format error"
#   pwrseq_core: exports duplicate symbol ...（它现在是内建的）
#
# 用法前提：在 WSL 里先 `make modules`（或 mkimage.sh 里加 MODULES=1）。
# 推完之后 depmod -a，再 modprobe 需要的东西。
set -e

IP=${1:-192.168.42.1}
WS=${WS:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
OUT=${OUT:-/root/linux/out}
VER=${VER:-$(cat "$OUT/include/config/kernel.release" 2>/dev/null)}

[ -n "$VER" ] || { echo "!! 读不到 kernel.release，先在 WSL 里编一遍"; exit 1; }
echo "== 本机构建版本: $VER"

# 只推我们真的会用到的这几组（整棵 modules_install 太慢）
LIST="
net/bluetooth/bluetooth.ko
net/bluetooth/rfcomm/rfcomm.ko
net/bluetooth/bnep/bnep.ko
drivers/bluetooth/hci_uart.ko
drivers/bluetooth/btqca.ko
drivers/bluetooth/btbcm.ko
drivers/bluetooth/hci_vhci.ko
"

TMP=$(mktemp -d)
n=0
for f in $LIST; do
	[ -f "$OUT/$f" ] || continue
	mkdir -p "$TMP/$(dirname "$f")"
	cp "$OUT/$f" "$TMP/$f"
	n=$((n + 1))
done
echo "== 收集到 $n 个 .ko"

ssh root@"$IP" "mkdir -p /lib/modules/$VER"
(cd "$TMP" && tar cf - .) | ssh root@"$IP" "tar xf - -C /lib/modules/$VER"
rm -rf "$TMP"

ssh root@"$IP" "depmod -a '$VER' 2>/dev/null || true; modprobe -d / hci_uart 2>&1 | head -3; sleep 2; ls /sys/class/bluetooth/ 2>/dev/null; dmesg | tail -5"
