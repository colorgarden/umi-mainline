#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# mkinitramfs.sh — 打一个能用的 initramfs（静态 aarch64 busybox + init 脚本）
#
#   wsl -d umi -u root -- sh <repo>/scripts/mkinitramfs.sh
#   ... --no-usb-console            不带 USB 串口 + U盘（默认带）
#   ... --reboot 60                 到点自动重启（方便反复试；默认不重启）
#   ... --dump-partition sda15      把 log 也写进 /dev/sda15（用 TWRP 读回来，谨慎使用）
#   ... --root /dev/sda34           切根到真正的 rootfs（默认就是这个，Arch 装在 userdata）
#   ... --rootfstype ext4           根文件系统类型（默认 ext4）
#   ... --root none                 纯救援镜像，不切根
#
# 产物：$WS/out/initramfs.cpio.gz
set -e

WS=${WS:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
BUILD=${BUILD:-/tmp/initramfs-build}
BB=${BB:-/tmp/armroot/bin/busybox.static}

USB=1
REBOOT=""
DUMPPART=""
ROOTDEV="/dev/sda34"
ROOTFSTYPE="ext4"
while [ $# -gt 0 ]; do
	case "$1" in
	--usb-console) USB=1 ;;
	--no-usb-console) USB=0 ;;
	--reboot) shift; REBOOT="$1" ;;
	--dump-partition) shift; DUMPPART="$1" ;;
	--root) shift; ROOTDEV="$1" ;;
	--rootfstype) shift; ROOTFSTYPE="$1" ;;
	*) echo "未知参数 $1"; exit 1 ;;
	esac
	shift
done

if [ ! -x "$BB" ]; then
	echo "== 没有静态 busybox，先跑 fetch-busybox.sh"
	sh "$WS/scripts/fetch-busybox.sh"
fi
[ -x "$BB" ] || { echo "!! 拿不到静态 busybox"; exit 2; }

# ---- 设备侧文本必须是纯 ASCII ----
# 手机屏幕上的 console 和 panic 屏用的都是 VGA 8x16 字体，没有中文字形 ——
# 中文会变成一堆方块。所以 init 脚本里**打印出来的东西**（以及注释）都强制英文。
if LC_ALL=C grep -q '[^ -~	]' "$WS/initramfs/init"; then
	echo "!! initramfs/init 里有非 ASCII 字符（会在屏幕上显示成方块）："
	LC_ALL=C grep -n '[^ -~	]' "$WS/initramfs/init" | head -10 | sed 's/^/     /'
	echo "   请改成英文再打包。"
	exit 3
fi
echo "== init 脚本是纯 ASCII（屏幕上不会出方块）"

echo "== 组装 $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD/bin" "$BUILD/sbin" "$BUILD/proc" "$BUILD/sys" "$BUILD/dev" \
         "$BUILD/tmp" "$BUILD/etc" "$BUILD/usr/bin" "$BUILD/usr/sbin"

# ---- GPU 固件 ----
# adreno 是内建驱动，probe 发生在 initramfs 阶段（rootfs 还没挂上），那时候
# request_firmware() 只能看到 initramfs 里的 /lib/firmware；否则 dmesg 里就是
#   Direct firmware load for qcom/a650_sqe.fw failed with error -2
# 于是 GPU 停在未初始化状态（devfreq 有节点但 cur_freq=0）。
#
# 文件来自本机 MIUI 的 /vendor/firmware（a650_zap.mdt/.b00-.b02、a650_sqe.fw、
# a650_gmu.bin），放在仓库 firmware/qcom/ 下；qcom/ 和旧式平铺路径各放一份，
# 因为 adreno_request_fw() 两种都会试。
FW_SRC="$WS/firmware/qcom"
if [ -d "$FW_SRC" ]; then
	mkdir -p "$BUILD/lib/firmware/qcom"
	for f in "$FW_SRC"/a650_*; do
		[ -e "$f" ] || continue
		cp "$f" "$BUILD/lib/firmware/qcom/"
		cp "$f" "$BUILD/lib/firmware/"
	done
	echo "== GPU 固件已装入 initramfs:"
	ls "$BUILD/lib/firmware/qcom" | sed 's/^/     /'
else
	echo "== 没有 firmware/qcom，GPU probe 会报 -2（显示不受影响）"
fi

# ---- 蓝牙固件（QCA6390）----
# 同理：hci_qca 是内建的，probe 在 rootfs 挂上之前就发生了，所以
#   Direct firmware load for qca/htbtfw20.tlv failed with error -2
# 而手动 unbind/bind（rootfs 已挂）又能成功 —— 差别就在于 initramfs 里有没有。
BFW_SRC="$WS/firmware/qca"
if [ -d "$BFW_SRC" ]; then
	mkdir -p "$BUILD/lib/firmware/qca"
	for f in "$BFW_SRC"/htbtfw20.tlv "$BFW_SRC"/htnv20.bin; do
		[ -e "$f" ] || continue
		cp "$f" "$BUILD/lib/firmware/qca/"
	done
	echo "== 蓝牙固件已装入 initramfs:"
	ls "$BUILD/lib/firmware/qca" | sed 's/^/     /'
else
	echo "== 没有 firmware/qca，蓝牙 probe 会报 -2"
fi

cp "$BB" "$BUILD/bin/busybox"
chmod 755 "$BUILD/bin/busybox"
# 常用 applet 先建好链接（init 里也会 busybox --install，这里做双保险）
for a in sh ls cat echo mount umount sleep dmesg grep sed tr cut head tail \
         reboot poweroff sync mkdir ln mknod find cp mv rm chmod date printf \
         tee hexdump od which ps kill setsid dd; do
	ln -sf /bin/busybox "$BUILD/bin/$a"
done

cp "$WS/initramfs/init" "$BUILD/init"
chmod 755 "$BUILD/init"

[ "$USB" = 1 ] && echo "usb" > "$BUILD/usb-console"
[ -n "$REBOOT" ] && echo "$REBOOT" > "$BUILD/reboot-after"
[ -n "$DUMPPART" ] && echo "$DUMPPART" > "$BUILD/dump-partition"
# 切根目标：写进 initramfs 的小文件，init 脚本读它，不用重编内核（cmdline 是编译期固定的）
if [ -n "$ROOTDEV" ]; then
	echo "$ROOTDEV" > "$BUILD/root-dev"
	echo "$ROOTFSTYPE" > "$BUILD/root-fstype"
fi

echo "== 打包 cpio.gz"
cd "$BUILD"
find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$WS/out/initramfs.cpio.gz"

ls -l "$WS/out/initramfs.cpio.gz"

# ---- 体积上限 ----
# ABL 自己算 ramdisk 的落点，头里的 ramdisk_addr 是死的（实测被忽略）。
# 这台机器下游启动时 ramdisk 落在 0xafe9f000，而我们的 ramoops 保留区从
# 0xb0000000 开始 —— 中间只有 0x161000 = 1,449,984 字节。
# 如果 ABL 把我们这个 ramdisk 摆在同一个位置，超过这个数就会**覆盖 ramoops**
# （表现：pstore 永远是空的，甚至启动就崩）。
# 现在只有 663 KB（约 46%），但加了东西容易忘 —— 所以在这里卡一道。
SIZE=$(wc -c < "$WS/out/initramfs.cpio.gz")
LIMIT_WARN=$((1100 * 1024))
LIMIT_HARD=$((1350 * 1024))
if [ "$SIZE" -ge "$LIMIT_HARD" ]; then
	echo "!! initramfs 有 $SIZE 字节，超过安全上限 $LIMIT_HARD"
	echo "   0xafe9f000(下游 ramdisk 落点) 到 0xb0000000(ramoops 起点) 只有 1,449,984 字节。"
	echo "   要么把东西挪到 USB 里，要么把 ramoops 挪到别处（见 DIAGNOSIS.md 的 ramoops 一节）。"
	exit 4
elif [ "$SIZE" -ge "$LIMIT_WARN" ]; then
	echo "   · 注意：initramfs 已到 $SIZE 字节（安全上限 $LIMIT_HARD）"
else
	echo "== 体积 OK：$SIZE 字节（上限 $LIMIT_HARD，约 $((SIZE * 100 / LIMIT_HARD))%）"
fi

echo "== 内容预览"
zcat "$WS/out/initramfs.cpio.gz" | cpio -t --quiet 2>/dev/null | head -20
echo "== 完成"
