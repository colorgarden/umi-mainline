#!/bin/sh
# 把自建的 wlroots0.20-0.20.2-2 装成正式包，并撤掉之前的 hook / 临时库副本。
set -e
PKG=$(ls -1 /home/colorgarden/build-wlroots/wlroots0.20-0.20.2-2-aarch64.pkg.tar.* | head -1)
echo "== 安装 $PKG"
pacman -U --noconfirm "$PKG"

echo "== 这个文件现在归谁:"
pacman -Qo /usr/lib/libwlroots-0.20.so
sha1sum /usr/lib/libwlroots-0.20.so

echo "== 撤掉「事后补回」那套（现在不需要了）"
rm -f /etc/pacman.d/hooks/90-wlroots-umi-revert.hook
rm -f /usr/local/bin/90-wlroots-umi-revert
rm -rf /usr/local/share/umi/wlroots
ls /etc/pacman.d/hooks/ 2>/dev/null | head -5

echo "== IgnorePkg：让 -Syu 不会把仓库版本盖回去"
if ! grep -q '^IgnorePkg' /etc/pacman.conf; then
	echo '' >> /etc/pacman.conf
	echo '# umi: wlroots0.20 是我们自己编的（带 layer-shell revert，phosh 需要）。' >> /etc/pacman.conf
	echo '# 上游涨版本时手工重编：tools/build-wlroots-umi.sh + pacman -U' >> /etc/pacman.conf
	echo 'IgnorePkg = wlroots0.20' >> /etc/pacman.conf
elif ! grep -q 'wlroots0.20' /etc/pacman.conf; then
	sed -i 's/^IgnorePkg *= *\(.*\)$/IgnorePkg = \1 wlroots0.20/' /etc/pacman.conf
fi
grep -n -A2 'umi: wlroots0.20' /etc/pacman.conf | head -4

echo "== 重启会话让 phoc 用上新库"
systemctl restart getty@tty1
sleep 12
echo "== 会话进程:"
ps -eo comm | grep -E 'phosh|phoc' | sort -u | tr '\n' ' '
echo
echo "== phosh 日志最后几行:"
journalctl -b --no-pager _COMM=phosh 2>/dev/null | tail -3
