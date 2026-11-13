#!/bin/sh
# 让扬声器路由开机自动生效（声卡起来后设一次 mixer）
set -u
cat > /etc/systemd/system/umi-audio-route.service <<'EOF'
[Unit]
Description=umi speaker routing (TERTIARY MI2S -> CS35L41)
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 声卡可能比 sound.target 晚一点出现，最多等 20 秒
ExecStartPre=/bin/sh -c 'for i in $(seq 1 40); do [ -e /dev/snd/controlC0 ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/bin/sh -c 'C=$(cat /proc/asound/cards | sed -n "s/^ *\([0-9]*\) \[X10.*/\1/p" | head -1); C=${C:-0}; \
  amixer -c $C sset "TERT_MI2S_RX Audio Mixer MultiMedia1" on; \
  amixer -c $C sset "LCV Analog PCM" 12; \
  amixer -c $C sset "RCV Analog PCM" 12;'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now umi-audio-route.service 2>&1 | tail -1
echo "=== 当前 mixer 状态:"
amixer -c 0 sget "TERT_MI2S_RX Audio Mixer MultiMedia1" 2>/dev/null | tail -2
echo "=== 服务:"
systemctl is-active umi-audio-route.service
