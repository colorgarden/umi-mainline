#!/bin/sh
# umi-plasma.sh — 在 umi 的 Arch 根分区上把 Plasma Mobile 开起来
#
#   UMI_USER=colorgarden UMI_PASS='...' sh scripts/umi-plasma.sh --apply
#   sh scripts/umi-plasma.sh                 # 只打印要做什么
#
# 做六件事（每一条都是踩过的坑）：
#
#   1. 装包：plasma-mobile / plasma-settings / kscreen / konsole / sudo
#   2. 建桌面用户（wheel + input/video/render/audio），设密码
#   3. sudo：wheel 组免讲（/etc/sudoers.d/10-wheel）
#   4. tty1 自动登录该用户，~/.bash_profile 里 exec startplasmamobile
#      （不用 SDDM：touch-only 的机器上多一个 greeter 只会多一处坏掉的地方）
#   5. **udev uaccess**：触摸是 platform(i2c) 设备，systemd 自带的
#      70-uaccess.rules 只给 USB 输入设备打 uaccess tag，logind 就不给登录
#      用户授权 /dev/input/event*，KWin 的 libinput 打不开 → 触摸完全没反应
#   6. locale：Qt/KWin 要 UTF-8（默认 LANG=C 时 kwin 会警告并退回 C.UTF-8）
#
# 密码只从环境变量读，不写进仓库。
set -e

APPLY=no
[ "$1" = "--apply" ] && APPLY=yes

USER_NAME=${UMI_USER:-colorgarden}
PASS=${UMI_PASS:-}
GROUPS="wheel,input,video,render,audio"

if [ -z "$PASS" ] && [ "$APPLY" = yes ]; then
	echo "!! 需要 UMI_PASS='...' 环境变量"
	exit 2
fi

run() {
	if [ "$APPLY" = yes ]; then
		sh -c "$1"
	else
		echo "  # $1"
	fi
}

echo "== 1/6 装包"
# pacman 7 的下载沙箱依赖 Landlock，内核没编 CONFIG_SECURITY_LANDLOCK 时必须关掉
# （--disable-sandbox 只影响本次；抄进 pacman.conf 是为了之后手动 pacman 也不炸）
if [ "$APPLY" = yes ]; then
	sed -i 's/^#DisableSandboxFilesystem$/DisableSandboxFilesystem/; s/^#DisableSandboxSyscalls$/DisableSandboxSyscalls/' /etc/pacman.conf
fi
run "pacman -Sy --noconfirm --disable-sandbox"
run "pacman -S --noconfirm --needed --disable-sandbox plasma-mobile plasma-settings kscreen konsole sudo"

echo "== 2/6 用户 $USER_NAME（$GROUPS）"
if [ "$APPLY" = yes ]; then
	if id "$USER_NAME" >/dev/null 2>&1; then
		usermod -aG "$GROUPS" "$USER_NAME"
	else
		useradd -m -s /bin/bash -G "$GROUPS" "$USER_NAME"
	fi
	echo "$USER_NAME:$PASS" | chpasswd
	id "$USER_NAME"
else
	echo "  # useradd -m -s /bin/bash -G $GROUPS $USER_NAME && chpasswd"
fi

echo "== 3/6 sudo（wheel 组）"
if [ "$APPLY" = yes ]; then
	mkdir -p /etc/sudoers.d
	printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
	chmod 440 /etc/sudoers.d/10-wheel
	command -v visudo >/dev/null 2>&1 && visudo -cf /etc/sudoers >/dev/null
fi
echo "  # /etc/sudoers.d/10-wheel: %%wheel ALL=(ALL:ALL) ALL"

echo "== 4/6 tty1 自动登录 + 起 Plasma Mobile"
if [ "$APPLY" = yes ]; then
	mkdir -p /etc/systemd/system/getty@tty1.service.d
	cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER_NAME --noclear %I linux
EOF
	cat > "/home/$USER_NAME/.bash_profile" <<'EOF'
# tty1 自动进 Plasma Mobile（Wayland）
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" = "1" ]; then
	exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
fi
EOF
	chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.bash_profile"
	chmod 644 "/home/$USER_NAME/.bash_profile"
	systemctl daemon-reload
	systemctl disable sddm 2>/dev/null || true
fi
echo "  # getty@tty1 drop-in: agetty --autologin $USER_NAME"
echo "  # ~$USER_NAME/.bash_profile: exec startplasmamobile"

echo "== 5/6 udev：platform 输入设备也要 uaccess"
if [ "$APPLY" = yes ]; then
	cat > /etc/udev/rules.d/71-umi-input-uaccess.rules <<'EOF'
# umi: 触摸 (fts, platform:a94000.i2c) / gpio-keys 都不是 USB 设备，
# systemd 的 70-uaccess.rules 只覆盖 USB 输入设备，所以 logind 永远不给登录
# 用户授权 /dev/input/event*，Wayland 合成器（KWin/libinput）就打不开。
SUBSYSTEM=="input", KERNEL=="event[0-9]*", TAG+="uaccess"
EOF
	udevadm control --reload
	udevadm trigger --action=change --subsystem-match=input
fi
echo "  # /etc/udev/rules.d/71-umi-input-uaccess.rules"

echo "== 6/6 locale = UTF-8，界面中文"
if [ "$APPLY" = yes ]; then
	# zh_CN 必须在 locale.gen 里真的生成过，否则 Qt 只拿到 C -> 界面全英文
	for L in en_US.UTF-8 zh_CN.UTF-8; do
		sed -i "s/^#\($L UTF-8\).*/\1/" /etc/locale.gen
		grep -qx "$L UTF-8" /etc/locale.gen || echo "$L UTF-8" >> /etc/locale.gen
	done
	locale-gen >/dev/null
	printf 'LANG=zh_CN.UTF-8\n' > /etc/locale.conf
	# 没有 CJK 字体时中文全是豆腐块（zh_CN 的 340 个 *.mo 本来就装好了）
	if ! fc-list :lang=zh 2>/dev/null | grep -q .; then
		pacman -Sy --noconfirm --disable-sandbox --needed noto-fonts-cjk || \
			pacman -Sy --noconfirm --disable-sandbox --needed wqy-zenhei
		fc-cache -f >/dev/null 2>&1 || true
	fi
	# Plasma 自己还读 plasma-localerc：LANG 管 gettext，这里管界面语言+日期格式
	CFG=/home/$USER_NAME/.config/plasma-localerc
	install -d -o "$USER_NAME" -g "$USER_NAME" "$(dirname "$CFG")"
	printf '[Formats]\nLANG=zh_CN\n\n[Translations]\nLANGUAGE=zh_CN\n' > "$CFG"
	chown "$USER_NAME:$USER_NAME" "$CFG"
	echo "  locale.conf = $(cat /etc/locale.conf)"
	echo "  中文字体  = $(fc-list :lang=zh 2>/dev/null | wc -l) 个"
	echo "  # MiSans / KDE 字体 / 终端等宽字体 -> scripts/umi-zh.sh（docs/KDE.md §8）"
fi

echo
echo "完成。重开一次会话让新用户/KWin 重新枚举输入设备："
echo "  loginctl terminate-session \$(loginctl list-sessions --no-legend | awk '\$4==\"seat0\"{print \$1;exit}')"
echo "  systemctl restart getty@tty1"
