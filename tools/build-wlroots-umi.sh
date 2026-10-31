#!/bin/sh
# 在本机（手机）上编一个带 layer-shell revert 的 wlroots0.20 包，
# 版本 0.20.2-1.umi1（比仓库的 0.20.2-1 高）→ pacman -Syu 不会回退它。
set -e

BDIR=/home/colorgarden/build-wlroots
SUDO_OK=1

echo "== 1) 构建依赖"
pacman -S --needed --noconfirm \
	base-devel meson ninja git glslang wayland-protocols \
	libdisplay-info libliftoff lcms2 libinput libdrm libglvnd libxkbcommon \
	libxcb xcb-util-errors xcb-util-renderutil xcb-util-wm seatd vulkan-icd-loader vulkan-headers \
	systemd xorg-xwayland >/tmp/wlroots-deps.log 2>&1 || {
		echo "!! 依赖安装失败，tail:"
		tail -5 /tmp/wlroots-deps.log
		exit 1
	}
echo "   依赖 OK"

echo "== 2) 准备构建目录（makepkg 不能以 root 跑）"
mkdir -p "$BDIR"
cp -f /tmp/PKGBUILD "$BDIR/PKGBUILD"
cp -f /tmp/Revert-layer-shell-error-on-0-dimension-without-anchors.patch "$BDIR/"
chown -R colorgarden:colorgarden "$BDIR"
ls -l "$BDIR"

echo "== 3) 编译（git clone tag 0.20.2 + patch + meson/ninja）"
runuser -u colorgarden -- sh -c "cd $BDIR && makepkg -f --noconfirm --skippgpcheck" 2>&1 | tail -15

echo "== 4) 产物"
ls -l "$BDIR"/*.pkg.tar.* 2>/dev/null || { echo "!! 没编出包"; exit 1; }
