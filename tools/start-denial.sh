#!/bin/sh
# 在手机上以 colorgarden 身份启动 Denial 会话（mobile profile）。
#
# 关键点：
# - 必须由 root 用 runuser 切到 colorgarden，并给出 XDG_RUNTIME_DIR；
# - denial-session 会检测 WAYLAND_DISPLAY，若已设置会拒绝启动，所以这里清掉；
# - 用 setsid + 重定向脱离 SSH，避免连接断开时收到 SIGHUP。
set -u

LOG=/var/log/denial-session.log

: > "$LOG"
setsid runuser -u colorgarden -- env \
	HOME=/home/colorgarden \
	XDG_RUNTIME_DIR=/run/user/1001 \
	DISPLAY= \
	WAYLAND_DISPLAY= \
	DENIAL_SHELL_PROFILE=mobile \
	/usr/bin/denial-session \
	>"$LOG" 2>&1 < /dev/null &

sleep 3
echo "started; log: $LOG"
