#!/bin/sh
# 修：colorgarden 的登录 shell 是 zsh，所以只写 .bash_profile 不会被读
set -e
U=colorgarden
H=/home/$U

# 1) .zprofile（zsh 的 login 启动文件）
cat > "$H/.zprofile" <<'EOF'
# ---- umi: tty1 自动进桌面会话（zsh 登录壳读这里） ----
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN

if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" = "1" ]; then
	exec /usr/local/bin/umi-session
fi
EOF

# 2) .bash_profile 保留（万一以后换成 bash）
grep -q umi-session "$H/.bash_profile" 2>/dev/null || cat > "$H/.bash_profile" <<'EOF'
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN

if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" = "1" ]; then
	exec /usr/local/bin/umi-session
fi
EOF

chown $U:$U "$H/.zprofile" "$H/.bash_profile"
chmod 644 "$H/.zprofile" "$H/.bash_profile"

# 3) .zshrc 不要覆盖 LANG（zsh 会读 .zshrc，顺带确保没把变量搞乱）
if [ -f "$H/.zshrc" ] && grep -q 'LANG=' "$H/.zshrc"; then
	echo "  注意：.zshrc 里也有 LANG 设置，保持原样"
fi

echo "== .zprofile:"
cat "$H/.zprofile"
echo
echo "== 重启 tty1 会话验证"
systemctl restart getty@tty1
sleep 12
echo "  会话进程: $(ps -eo comm | grep -E 'phosh|phoc' | sort -u | tr '\n' ' ')"
echo "  wayland socket: $(find /run/user/1001 -name 'wayland-*' 2>/dev/null | tr '\n' ' ')"
echo "  umi-session 计数: $(cat /run/umi-session-fail 2>/dev/null || echo 无)"
