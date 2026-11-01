#!/bin/sh
# 给 colorgarden 配 mpv 默认硬解（venus 的 v4l2m2m-copy）
set -e
U=colorgarden
H=/home/$U
D="$H/.config/mpv"
mkdir -p "$D"

cat > "$D/mpv.conf" <<'EOF'
# Xiaomi Mi 10 (umi) —— Venus 硬件解码
#
# 为什么是 v4l2m2m-copy 而不是 v4l2m2m：
#   主线 6.12 的 venus 是 stateful V4L2 M2M，解码器能出 DMABuf，
#   但这个 mpv 构建的 v4l2m2m（零拷贝）路径不可用（"Unsupported hwdec"），
#   而 v4l2m2m-copy（解码后拷到系统内存）实测可用：
#     venus 中断 +188，日志 "Using hardware decoding (v4l2m2m-copy)"。
#
# 实测 CPU（1080p H.264 300 帧）：软解 6.19s -> 硬解 0.42s（ffmpeg 侧同口径）。
hwdec=v4l2m2m-copy

# 屏幕是 1080x2340 竖屏，缩放交给 GPU
vo=gpu
profile=fast

# 省电/省流量：不主动补帧
video-sync=audio
EOF

chown -R $U:$U "$H/.config/mpv"
echo "== 写入:"
cat "$D/mpv.conf" | head -6

echo
echo "== 验证：不写任何参数，直接 mpv 是否硬解"
F=/tmp/venus-test/t1080.mp4
irq() { grep -i venus /proc/interrupts | awk '{s=0; for(i=2;i<=9;i++) s+=$i; print s}'; }
I0=$(irq)
runuser -u $U -- env HOME="$H" mpv --no-audio --vo=null --frames=150 -v "$F" 2>&1 |
	grep -iE 'Using hardware|Using software|hwdec' | head -3
I1=$(irq)
echo "   venus 中断增量 = $((I1-I0))"
