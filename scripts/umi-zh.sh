#!/bin/sh
# umi-zh.sh — umi 的 Plasma Mobile 变中文界面 + 小米 MiSans + 等宽终端 + 英文键盘
#
#   UMI_USER=colorgarden sh scripts/umi-zh.sh --apply
#   sh scripts/umi-zh.sh            # 只打印要做什么
#
# 七件事（都是实测踩出来的，别“优化”）：
#
#   1. zh_CN.UTF-8 必须在 locale.gen 里真的 localedef 生成过；
#      否则 Qt 只拿到 C —— 界面还是英文，跟 LANG 写了什么无关
#   2. /etc/locale.conf + .bash_profile 双保险：systemd 只把 locale.conf 交给
#      “之后才启动”的单元，已经跑着的 getty 不会重读
#   3. CJK 字体：一个都没有时中文全是豆腐块（方框）。Plasma 的 zh_CN *.mo
#      本来就在包里，缺的只是字体
#   4. MiSans 取自 @fontpkg/mi-sans（unpkg 上的单字重 OTF，比官方整包小）。
#      它 OS/2 权重是错的（Regular=53），必须按 style 名重设 weight，
#      不然 fontconfig 把 Medium 当常规，整个界面变中黑
#   5. plasma-localerc 管 Plasma 自己的语言/日期格式（LANG 只管 gettext）
#   6. Konsole：MiSans 不是等宽，终端里英文间距会拉很开 —— 等宽回到 Hack，
#      中文靠 fontconfig 回落；终端还能单独跑英文环境（覆盖 .desktop）
#   7. 虚拟键盘：~/.config/plasmakeyboardrc 的 enabledLocales。留空 = 只开
#      系统语言那一个（中文机器上就没英文键盘）；但**别写 zh_CN** —— 拼音插件
#      在、/usr/share/qt6/virtualkeyboard 词典数据没装，zh_CN 被判不可用，
#      结果是键盘整个不显示（journal 只有一句 “without a context”）
set -e

APPLY=no
[ "$1" = "--apply" ] && APPLY=yes

U=${UMI_USER:-colorgarden}
H=/home/$U
PAC="pacman -Sy --noconfirm --disable-sandbox --needed"

run() {
	if [ "$APPLY" = yes ]; then
		sh -c "$1"
	else
		echo "  # $1"
	fi
}

# wf <path>：内容从 stdin 来；非 --apply 时丢弃（顺便确认语法）
wf() {
	if [ "$APPLY" = yes ]; then
		cat > "$1"
	else
		echo "  # 写入 $1:"
		sed 's/^/  #   /'
		cat >/dev/null
	fi
}

echo "== 1/7 zh_CN.UTF-8 locale"
run "sed -i 's/^#\\(zh_CN.UTF-8 UTF-8\\).*/\\1/' /etc/locale.gen"
run "grep -qx 'zh_CN.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen"
run "locale-gen >/dev/null"
run "printf 'LANG=zh_CN.UTF-8\\n' > /etc/locale.conf"
echo "  # 验证：locale -a | grep zh  ->  zh_CN.utf8"

echo "== 2/7 会话环境（systemd + .bash_profile）"
run "systemctl set-environment LANG=zh_CN.UTF-8"
run "systemctl set-environment LANGUAGE=zh_CN"
run "grep -q 'UMI_LANG' $H/.bash_profile || \
	sed -i '1i # UMI_LANG\\nexport LANG=zh_CN.UTF-8\\nexport LANGUAGE=zh_CN\\n' $H/.bash_profile"
echo "  # 验证：tr '\\0' '\\n' < /proc/\$(pgrep -f /usr/bin/plasmashell|head -1)/environ | grep LANG"

echo "== 3/7 CJK 字体（缺了就是豆腐块）"
run "$PAC noto-fonts-cjk || $PAC wqy-zenhei"

echo "== 4/7 MiSans（小米字体）"
run "mkdir -p /usr/share/fonts/misans"
for w in Regular Medium Demibold Light Bold; do
	run "curl -fsSL https://unpkg.com/@fontpkg/mi-sans@4.3.0/MiSans-$w.otf -o /usr/share/fonts/misans/MiSans-$w.otf"
done
run "fc-cache -f >/dev/null"
wf /etc/fonts/conf.d/65-umi-misans.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- zh 优先 MiSans，MiSans 缺的字回落 Noto Sans CJK SC -->
  <match target="pattern">
    <test name="lang" compare="contains"><string>zh</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>MiSans</string></edit>
    <edit name="family" mode="append" binding="weak"><string>Noto Sans CJK SC</string></edit>
  </match>
  <alias binding="same">
    <family>sans-serif</family>
    <prefer><family>MiSans</family></prefer>
  </alias>
</fontconfig>
EOF
wf /etc/fonts/conf.d/66-umi-misans-weight.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- MiSans(@fontpkg 4.3.0) 的 OS/2 权重是错的（Regular=53 / Medium=75），
       按 style 名重设，否则 fontconfig 把 Medium 当常规 -->
  <match target="scan"><test name="family"><string>MiSans</string></test><test name="style"><string>Regular</string></test><edit name="weight" mode="assign"><const>regular</const></edit></match>
  <match target="scan"><test name="family"><string>MiSans</string></test><test name="style"><string>Light</string></test><edit name="weight" mode="assign"><const>light</const></edit></match>
  <match target="scan"><test name="family"><string>MiSans</string></test><test name="style"><string>Medium</string></test><edit name="weight" mode="assign"><const>medium</const></edit></match>
  <match target="scan"><test name="family"><string>MiSans</string></test><test name="style"><string>Demibold</string></test><edit name="weight" mode="assign"><const>demibold</const></edit></match>
  <match target="scan"><test name="family"><string>MiSans</string></test><test name="style"><string>Bold</string></test><edit name="weight" mode="assign"><const>bold</const></edit></match>
</fontconfig>
EOF
run "fc-cache -f >/dev/null"
echo "  # 验证：fc-match 'sans-serif:lang=zh-cn'  ->  MiSans-Regular.otf"

echo "== 5/7 Plasma 语言 + KDE 字体"
run "install -d -o $U -g $U $H/.config"
wf "$H/.config/plasma-localerc" <<'EOF'
[Formats]
LANG=zh_CN

[Translations]
LANGUAGE=zh_CN
EOF
run "chown $U:$U $H/.config/plasma-localerc"
run "runuser -u $U -- kwriteconfig6 --file kdeglobals --group General --key font 'MiSans,10'"
run "runuser -u $U -- kwriteconfig6 --file kdeglobals --group General --key fixed 'Hack,9'"
echo "  # kdeglobals: font=MiSans,10  fixed=Hack,9（等宽必须真等宽）"

echo "== 6/7 Konsole（等宽 + 更小 + 可单独英文）"
run "mkdir -p $H/.local/share/konsole $H/.local/share/applications"
wf "$H/.local/share/konsole/Mobile.profile" <<'EOF'
[Appearance]
ColorScheme=Breeze
Font=Hack,8

[General]
Name=Mobile
Parent=FALLBACK/

[Scrolling]
HistoryMode=unlimited
EOF
run "chown -R $U:$U $H/.local/share/konsole"
run "runuser -u $U -- kwriteconfig6 --file konsolerc --group 'Desktop Entry' --key DefaultProfile Mobile.profile"
wf "$H/.local/share/applications/org.kde.konsole.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Exec=env LANG=en_US.UTF-8 LANGUAGE=en konsole
Icon=utilities-terminal
Name=Terminal
Name[zh_CN]=终端
Comment=Terminal emulator (English environment)
Comment[zh_CN]=终端（英文环境）
Categories=Qt;KDE;System;TerminalEmulator;
X-KDE-StartupNotify=true
EOF
run "chown -R $U:$U $H/.local/share/applications"
run "runuser -u $U -- kbuildsycoca6 --noincremental 2>/dev/null || true"
echo "  # 注意：这个 .desktop 里有中文，脚本必须以 UTF-8 文件形式传上去"
echo "  #       （别用 PowerShell 管道管道过去，会被 GBK 转坏 -> 菜单里乱码）"

echo "== 7/7 虚拟键盘：只开英文"
wf "$H/.config/plasmakeyboardrc" <<'EOF'
[General]
enabledLocales=en_US
EOF
run "chown $U:$U $H/.config/plasmakeyboardrc"
run "$PAC hunspell-en_US"
run "runuser -u $U -- kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/bin/plasma-keyboard"
echo "  # 改完要重开一次会话，键盘面板才会按新配置重建"

echo
echo "重开一次会话："
echo "  loginctl terminate-user $U; pkill -9 -u $U -f plasmashell; systemctl restart getty@tty1"
