#!/bin/sh
# 让扬声器路由开机自动生效（声卡起来后设一次 mixer）
#
# 参数是实测调出来的（两颗 CS35L41 + 顶部听筒）：
#   Analog PCM = 4   (约 +4.5 dB，再高小喇叭低音就破)
#   Digital PCM = 913 (0 dB，寄存器默认)
#   DRE = off        (开了反而更容易破音)
#   两路 codec 的 channel map 都是 slot0（机器驱动里设）
set -u
cat > /etc/systemd/system/umi-audio-route.service <<'EOF'
[Unit]
Description=umi speaker routing (TERTIARY MI2S -> CS35L41 x2)
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 声卡可能比 sound.target 晚一点出现，最多等 20 秒
ExecStartPre=/bin/sh -c 'for i in $(seq 1 40); do [ -e /dev/snd/controlC0 ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/bin/sh -c 'C=$(cat /proc/asound/cards | sed -n "s/^ *\([0-9]*\) \[X10.*/\1/p" | head -1); C=${C:-0}; \
  amixer -c $C sset "TERT_MI2S_RX Audio Mixer MultiMedia1" on; \
  amixer -c $C sset "LCV Analog PCM" 4; \
  amixer -c $C sset "RCV Analog PCM" 4; \
  amixer -c $C sset "LCV Digital PCM" 913; \
  amixer -c $C sset "RCV Digital PCM" 913; \
  amixer -c $C sset "LCV DRE" off; \
  amixer -c $C sset "RCV DRE" off;'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now umi-audio-route.service 2>&1 | tail -1
echo "=== 当前 mixer:"
amixer -c 0 sget "TERT_MI2S_RX Audio Mixer MultiMedia1" 2>/dev/null | tail -1
amixer -c 0 sget "LCV Analog PCM" 2>/dev/null | tail -1
amixer -c 0 sget "RCV Analog PCM" 2>/dev/null | tail -1
echo "=== 服务: $(systemctl is-active umi-audio-route.service)"
