#!/bin/sh
# 以横屏启动 Phira，退出后把桌面恢复成竖屏。
#
# 背景：Denial 的输出方向只在启动时从 outputs.conf 读取，运行时靠
# outputs.apply 控制请求切换（denialctl 没封装，用 tools/denial-rotate）。
# 桌面本身要竖屏，只有 Phira 需要横屏，所以在启动器里临时旋转。
#
# 从 .desktop / gio launch 启动时环境可能缺 XDG_RUNTIME_DIR 与 DISPLAY，
# 缺了就会找不到 Denial 控制 socket 和 PipeWire socket，所以在这里补默认值。
set -u

ROTATE=/usr/local/bin/denial-rotate
PORTRAIT=${PHIRA_PORTRAIT_TRANSFORM:-normal}
LANDSCAPE=${PHIRA_LANDSCAPE_TRANSFORM:-90}

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR=/run/user/$(id -u)
    export XDG_RUNTIME_DIR
fi
if [ -z "${DISPLAY:-}" ]; then
    DISPLAY=:0
    export DISPLAY
fi
if [ -z "${HOME:-}" ]; then
    HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
    export HOME
fi

child=
restored=0

restore_portrait() {
    [ "$restored" = 1 ] && return 0
    restored=1
    [ -x "$ROTATE" ] || return 0
    "$ROTATE" "$PORTRAIT" >/dev/null 2>&1 || true
}

forward() {
    [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
}

trap 'forward' TERM INT HUP
trap 'restore_portrait' EXIT

if [ -x "$ROTATE" ]; then
    "$ROTATE" "$LANDSCAPE" >/dev/null 2>&1 || true
fi

cd /opt/phira || { restore_portrait; exit 1; }
./phira-main "$@" &
child=$!

wait "$child"
status=$?
# wait 被信号打断时子进程可能还在，等它真正结束再恢复方向
while kill -0 "$child" 2>/dev/null; do
    wait "$child"
    status=$?
done

restore_portrait
exit "$status"
