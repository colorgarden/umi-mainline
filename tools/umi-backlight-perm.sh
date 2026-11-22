#!/bin/sh
# 让 video 组能写背光亮度，保证亮度可调（不依赖 polkit/PowerDevil）。
#
# 背景：Plasma Mobile 的亮度滑块走 PowerDevil -> backlighthelper (kauth/polkit)。
# 这台机器的会话由自建 systemd 单元启动，polkit 有时判定会话不是 active，
# backlighthelper 被拒，PowerDevil 干脆不注册 BrightnessControl 对象，
# UI 里就没有亮度条。直接放开设备权限最稳。
set -u

# udev 的 RUN+= 里 chmod/chgrp 对 sysfs 不生效，用 tmpfiles 的 z 指令（开机后执行）
cat > /etc/tmpfiles.d/umi-backlight.conf <<'EOF'
z /sys/class/backlight/umi-panel/brightness 0664 root video -
z /sys/class/backlight/umi-panel/bl_power   0664 root video -
EOF

cat > /etc/systemd/system/umi-backlight-perm.service <<'EOF'
[Unit]
Description=Allow video group to write umi backlight
After=systemd-udev-settle.service systemd-tmpfiles-setup.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 背光设备是 DSI 面板 probe 时才出现的，tmpfiles 开机那次可能还没它，
# 所以这里再补一次，并等到节点存在。
ExecStart=/bin/sh -c 'for i in $(seq 1 60); do [ -e /sys/class/backlight/umi-panel/brightness ] && break; sleep 0.5; done; chgrp video /sys/class/backlight/umi-panel/brightness /sys/class/backlight/umi-panel/bl_power 2>/dev/null; chmod 0664 /sys/class/backlight/umi-panel/brightness /sys/class/backlight/umi-panel/bl_power 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF

# upower/powerdevil 看的是 udev 属性；让 backlight 节点带上 seat 标签已有，
# 这里只补权限。
systemctl daemon-reload
systemd-tmpfiles --create /etc/tmpfiles.d/umi-backlight.conf 2>/dev/null || true
systemctl enable --now umi-backlight-perm.service 2>&1 | tail -1
echo "=== 权限:"
ls -l /sys/class/backlight/umi-panel/brightness
echo "=== colorgarden 写测试:"
runuser -u colorgarden -- sh -c 'echo 1500 > /sys/class/backlight/umi-panel/brightness' 2>&1 \
	&& echo "可写 OK" || echo "仍不可写"
echo "  brightness=$(cat /sys/class/backlight/umi-panel/brightness)"
