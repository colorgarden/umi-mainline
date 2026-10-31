#!/bin/sh
# 把 Arch 的 libwlroots-0.20.so 换成 Debian 那份（带 layer-shell 0 尺寸 revert）
set -e
LIB=/usr/lib/libwlroots-0.20.so
SRC=/tmp/wlrdeb/libwlroots-0.20.so
BAK=/usr/lib/libwlroots-0.20.so.arch-bak

[ -f "$SRC" ] || { echo "!! 先跑 tools/wlroots-revert-layershell.sh 把 deb 取下来"; exit 1; }

if [ ! -f "$BAK" ]; then
	cp -a "$LIB" "$BAK"
	echo "== 备份原库 -> $BAK"
else
	echo "== 已有备份 $BAK"
fi

cp -f "$SRC" "$LIB"
chmod 755 "$LIB"
ldconfig
echo "== 已替换:"
ls -l "$LIB" "$BAK"
sha1sum "$LIB" "$BAK" | sed 's/^/   /'

echo "== 装会话入口:"
mkdir -p /usr/local/bin
cp -f /tmp/umi-session /usr/local/bin/umi-session
chmod 755 /usr/local/bin/umi-session
ls -l /usr/local/bin/umi-session

echo "== 装 .bash_profile（tty1 自动进 umi-session）:"
cp -a /home/colorgarden/.bash_profile /home/colorgarden/.bash_profile.before-phosh 2>/dev/null || true
cat > /home/colorgarden/.bash_profile <<'EOF'
# UMI_LANG: systemd 只会把 locale.conf 给新起的单元，这里自己兜底
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN

# tty1 自动进桌面会话：/usr/local/bin/umi-session 决定是 Phosh 还是 Plasma
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" = "1" ]; then
	exec /usr/local/bin/umi-session
fi
EOF
chown colorgarden:colorgarden /home/colorgarden/.bash_profile
chmod 644 /home/colorgarden/.bash_profile

echo "== 完成，重启后生效"
