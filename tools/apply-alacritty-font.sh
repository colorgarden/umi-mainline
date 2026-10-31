#!/bin/sh
# 把 /tmp/alacritty.toml 装到 colorgarden 的 ~/.config/alacritty/，并校验
set -e
CFG=/home/colorgarden/.config/alacritty/alacritty.toml
DIR=$(dirname "$CFG")

mkdir -p "$DIR"
if [ -f "$CFG" ] && [ ! -f "$CFG.bak" ]; then
	cp -a "$CFG" "$CFG.bak"
	echo "backup -> $CFG.bak"
fi

cp /tmp/alacritty.toml "$CFG"
chown colorgarden:colorgarden "$CFG"
chmod 644 "$CFG"

echo "=== TOML 语法检查:"
python3 - "$CFG" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
print("  font =", d.get("font"))
print("  window =", d.get("window"))
PY

echo "=== 字体能不能真的落到 Hack:"
for pat in 'Hack' 'Hack:style=Bold' 'Hack:style=Italic' 'Hack:style=Bold Italic'; do
	printf '  %-24s -> ' "$pat"
	fc-match -f '%{family}|%{style}|%{file}\n' "$pat"
done

echo "=== 文件:"
ls -l "$CFG"
