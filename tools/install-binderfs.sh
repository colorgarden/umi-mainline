#!/bin/sh
# binderfs 开机挂载 + Waydroid 容器随系统启动
#
# 为什么需要：binder 是内建（bool）驱动，binderfs 不会自动挂载；
# Waydroid 依赖 /dev/binderfs 里的 binder-control 动态创建设备。
set -u

mkdir -p /dev/binderfs

cat > /etc/systemd/system/dev-binderfs.mount <<'EOF'
[Unit]
Description=Binder filesystem
After=systemd-tmpfiles-setup-dev.service
Before=waydroid-container.service

[Mount]
What=binder
Where=/dev/binderfs
Type=binder

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable dev-binderfs.mount 2>&1 | tail -1
systemctl start dev-binderfs.mount 2>&1 | tail -1
echo "=== 挂载状态:"
systemctl is-active dev-binderfs.mount
ls /dev/binderfs 2>/dev/null | tr '\n' ' '
echo
systemctl enable waydroid-container.service 2>&1 | tail -1
