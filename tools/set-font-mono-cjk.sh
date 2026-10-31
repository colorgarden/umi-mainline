#!/bin/sh
# 系统字体从 MiSans（比例字体）换成 Noto Sans Mono CJK SC（等宽 + 全中文覆盖）
set -e
U=colorgarden
UID_N=1001
FAMILY="Noto Sans Mono CJK SC"
SIZE=10

echo "== 1) 删 MiSans 与旧规则"
rm -f /etc/fonts/conf.d/65-umi-misans.conf /etc/fonts/conf.d/66-umi-misans-weight.conf
rm -rf /usr/share/fonts/misans
rm -f /home/$U/.config/fontconfig/fonts.conf
rm -rf /home/$U/.config/fontconfig/conf.d

echo "== 2) 装 fontconfig 默认：sans/serif/monospace/system-ui -> Noto Sans Mono CJK SC"
cat > /etc/fonts/conf.d/70-umi-mono-cjk.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!--
  umi: 系统字体统一用 Noto Sans Mono CJK SC（等宽 + 中文全覆盖）。
  以前这里指到 MiSans（小米的比例字体），换成等宽之后：
    - 中英文对齐（终端、日志、表格都不再跳来跳去）
    - 拉丁字形仍来自 Noto Sans Mono，中文来自 Noto Sans Mono CJK SC
  想换回比例字体：删掉这个文件里 prefer 段，或改 family 名后 fc-cache -f。
-->
<fontconfig>
	<alias binding="strong"><family>sans-serif</family><prefer><family>Noto Sans Mono CJK SC</family></prefer></alias>
	<alias binding="strong"><family>serif</family><prefer><family>Noto Sans Mono CJK SC</family></prefer></alias>
	<alias binding="strong"><family>monospace</family><prefer><family>Noto Sans Mono CJK SC</family></prefer></alias>
	<alias binding="strong"><family>system-ui</family><prefer><family>Noto Sans Mono CJK SC</family></prefer></alias>

	<!-- 等宽场景里中文也走等宽 CJK，避免中文回落到比例字体 -->
	<match target="pattern">
		<test name="family"><string>monospace</string></test>
		<edit name="family" mode="append" binding="weak"><string>Noto Sans Mono CJK SC</string></edit>
	</match>
</fontconfig>
EOF

echo "== 3) 重建字体缓存"
fc-cache -f >/dev/null 2>&1 || true
echo -n "   fc-match sans-serif -> "; fc-match -f '%{family} %{style}\n' sans-serif
echo -n "   fc-match monospace  -> "; fc-match -f '%{family} %{style}\n' monospace
echo -n "   fc-match :lang=zh   -> "; fc-match -f '%{family} %{style}\n' ':lang=zh'

echo "== 4) gsettings（Phosh / GTK 用这个）"
BUS="unix:path=/run/user/$UID_N/bus"
run_as_u() {
	runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_N \
		DBUS_SESSION_BUS_ADDRESS="$BUS" "$@"
}
run_as_u gsettings set org.gnome.desktop.interface font-name "$FAMILY $SIZE" || true
run_as_u gsettings set org.gnome.desktop.interface document-font-name "$FAMILY $SIZE" || true
run_as_u gsettings set org.gnome.desktop.interface monospace-font-name "$FAMILY $SIZE" || true
run_as_u gsettings set org.gnome.desktop.interface titlebar-font "$FAMILY $SIZE" || true
echo "   现在:"
run_as_u gsettings get org.gnome.desktop.interface font-name 2>/dev/null
run_as_u gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null

echo "== 5) GTK 侧再写一份（不依赖 dconf 的应用也能吃到）"
mkdir -p /home/$U/.config/gtk-3.0 /home/$U/.config/gtk-4.0
for d in gtk-3.0 gtk-4.0; do
	cat > /home/$U/.config/$d/settings.ini <<EOF
[Settings]
gtk-font-name=$FAMILY $SIZE
gtk-monospace-font-name=$FAMILY $SIZE
gtk-hint-font-metrics=1
EOF
	chown -R $U:$U /home/$U/.config/$d
done
chown $U:$U /home/$U/.config/gtk-3.0/settings.ini /home/$U/.config/gtk-4.0/settings.ini

echo "== 完成（重启会话生效）"
