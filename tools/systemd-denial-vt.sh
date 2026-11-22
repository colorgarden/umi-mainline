#!/bin/sh
# 开机把活动 VT 切到 Denial 所在的 tty7。
#
# 为什么需要：Denial 起在 tty7，但内核的默认活动 VT 是 tty1。VT 不在前台时
# Denial 的 DRM 输出会保持 powered off（日志：outputs 0/1 active），
# 表现为“屏幕全黑但进程正常”。chvt 需要 root，而 denial.service 以
# colorgarden 身份运行，所以用这个独立的一次性单元来切。
set -u

cat > /etc/systemd/system/denial-vt.service <<'EOF'
[Unit]
Description=Switch active VT to Denial's tty7
After=denial.service
Wants=denial.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 等 Denial 真正把输出建起来再切，太早切会在它接管 DRM 前被覆盖回去。
ExecStart=/bin/sh -c 'for i in $(seq 1 60); do [ -e /sys/class/drm/card1-DSI-1/dpms ] && break; sleep 0.5; done; sleep 2; chvt 7'

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable denial-vt.service 2>&1 | tail -1
echo "=== 已装"
