#!/bin/sh
# 装 grim（截屏）+ wf-recorder（录屏），并实测一次
set -e
U=colorgarden
UID_N=1001

echo "== 1) 装包"
pacman -S --needed --noconfirm grim wf-recorder >/tmp/shot-deps.log 2>&1 || {
	tail -5 /tmp/shot-deps.log; exit 1
}
command -v grim wf-recorder

echo "== 2) 实测截屏（用户会话里跑）"
run_as_u() {
	runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_N \
		WAYLAND_DISPLAY=wayland-0 "$@"
}
run_as_u grim -o DSI-1 /tmp/umi-shot-test.png
ls -l /tmp/umi-shot-test.png
python3 - <<'PY'
import struct
d=open('/tmp/umi-shot-test.png','rb').read(33)
w,h=struct.unpack('>II', d[16:24])
print(f"   PNG 尺寸: {w}x{h}")
PY

echo "== 3) 实测录屏（3 秒，x264）"
run_as_u timeout 3 wf-recorder -o DSI-1 -f /tmp/umi-rec-test.mp4 -c libx264 -p preset=ultrafast >/tmp/wfrec.log 2>&1 || true
ls -l /tmp/umi-rec-test.mp4 2>/dev/null && tail -3 /tmp/wfrec.log
