#!/bin/sh
# 装 umi-shot / umi-rec（截屏 / 录屏），并放进 Phosh 的应用网格。
#
# 为什么用它们：Phosh 跑在 phoc（wlroots）上，phoc 提供 zwlr_screencopy_manager_v1，
# 所以 grim（截屏）和 wf-recorder（录屏）是这条链上最直接可用的工具。
#
# 注意两点（都踩过）：
#   1. wf-recorder 默认只在画面变化（damage）时才向合成器要帧 —— 手机屏幕经常是
#      静态的，不加 -D 录出来可能只有几百字节。这里固定用 -D + 30fps。
#   2. Adreno 650 没有 VAAPI 编码器（v4l2 那条主线还没接），只能 CPU x264：
#      ultrafast + crf 28，1080x2340@30 在 SD865 上实测能跟上（~33 KB/s）。
set -e

echo "== 装包"
pacman -S --needed --noconfirm grim wf-recorder >/tmp/umi-shot-deps.log 2>&1 || {
	tail -5 /tmp/umi-shot-deps.log; exit 1
}

echo "== /usr/local/bin/umi-shot"
cat > /usr/local/bin/umi-shot <<'EOF'
#!/bin/sh
# 截屏：umi-shot [输出名]   （默认 DSI-1）
OUT="${1:-DSI-1}"
DIR="${HOME:-/home/colorgarden}/Pictures/Screenshots"
mkdir -p "$DIR"
F="$DIR/shot-$(date +%Y%m%d-%H%M%S).png"
grim -o "$OUT" "$F" || { echo "截屏失败"; exit 1; }
echo "$F"
command -v notify-send >/dev/null 2>&1 && notify-send -a Screenshot "截图已保存" "$F" 2>/dev/null || true
EOF

echo "== /usr/local/bin/umi-rec"
cat > /usr/local/bin/umi-rec <<'EOF'
#!/bin/sh
# 录屏开关：
#   umi-rec            第一次=开始，第二次=停止
#   umi-rec status     看在不在录、最近的文件多大
#   umi-rec stop       显式停止（等同再调一次）
OUT="${1:-DSI-1}"
DIR="${HOME:-/home/colorgarden}/Videos/Recordings"
RUN="${XDG_RUNTIME_DIR:-/tmp}/umi-rec.pid"
mkdir -p "$DIR"

running() { [ -f "$RUN" ] && kill -0 "$(cat "$RUN" 2>/dev/null)" 2>/dev/null; }

case "$OUT" in
status)
	running && echo "正在录屏（pid $(cat "$RUN")）" || echo "当前没有在录屏"
	F=$(ls -t "$DIR"/*.mp4 2>/dev/null | head -1)
	[ -n "$F" ] && ls -lh "$F" | awk '{print "最近的文件: " $NF "  (" $5 ")"}'
	exit 0 ;;
stop) ;;
esac

if running; then
	kill -INT "$(cat "$RUN")"
	rm -f "$RUN"
	echo "停止录屏（文件已收尾）"
	F=$(ls -t "$DIR"/*.mp4 2>/dev/null | head -1)
	[ -n "$F" ] && echo "$F"
	command -v notify-send >/dev/null 2>&1 && notify-send -a Recorder "录屏已停止" "$F" 2>/dev/null || true
	exit 0
fi

rm -f "$RUN"
F="$DIR/rec-$(date +%Y%m%d-%H%M%S).mp4"
wf-recorder -o "$OUT" -D -f "$F" -c libx264 -p preset=ultrafast -p crf=28 -r 30 \
	>/dev/null 2>&1 &
echo $! > "$RUN"
echo "开始录屏 -> $F"
command -v notify-send >/dev/null 2>&1 && notify-send -a Recorder "开始录屏" "$F" 2>/dev/null || true
EOF
chmod 755 /usr/local/bin/umi-shot /usr/local/bin/umi-rec

echo "== 应用网格图标"
mkdir -p /usr/share/applications
cat > /usr/share/applications/umi-shot.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=截屏
Name[en]=Screenshot
Comment=保存当前屏幕到 ~/Pictures/Screenshots
Exec=/usr/local/bin/umi-shot
Icon=camera-photo-symbolic
Terminal=false
Categories=Utility;Graphics;
X-Phosh-Supported=true
EOF
cat > /usr/share/applications/umi-rec.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=录屏
Name[en]=Screen record
Comment=点一次开始，再点一次停止（存到 ~/Videos/Recordings）
Exec=/usr/local/bin/umi-rec
Icon=media-record-symbolic
Terminal=false
Categories=Utility;AudioVideo;
X-Phosh-Supported=true
EOF
update-desktop-database /usr/share/applications 2>/dev/null || true

echo "== 自检：截一张"
if [ -d /run/user/1001 ]; then
	runuser -u colorgarden -- env HOME=/home/colorgarden XDG_RUNTIME_DIR=/run/user/1001 \
		WAYLAND_DISPLAY=wayland-0 /usr/local/bin/umi-shot || true
fi
echo "== 完成：终端里 umi-shot / umi-rec，或应用网格里点「截屏」「录屏」"
