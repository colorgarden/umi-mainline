#!/bin/sh
# 保证音频整条链在开机时就加载，声卡不会卡在 EPROBE_DEFER
#
# 症状：/proc/asound/cards 是 "--- no soundcards ---"，dmesg 里
#   snd-sm8250 sound: umi-trace probe parse_of ret=-517
# 反复出现但没有后续；手动 modprobe q6asm/q6afe/q6adm/q6routing 后声卡才出现。
# 原因：q6* 模块靠 udev modalias 自动加载，时序不稳定；声卡 probe 先跑到，
# 依赖组件还没注册就 EPROBE_DEFER，之后没人再触发 probe。
set -u

cat > /etc/modules-load.d/umi-audio.conf <<'EOF'
# 音频整条链：APR 服务 -> q6 ASM/AFE/ADM/ROUTING -> 板级声卡
# 不显式列出时，声卡 probe 会在模块加载前 EPROBE_DEFER(-517)，之后就没人再触发
q6core
q6afe
q6afe-dai
q6asm
q6asm-dai
q6adm
q6routing
snd_soc_cs35l41
snd_soc_cs35l41_i2c
snd_soc_sm8250
EOF

depmod -a "$(uname -r)" 2>/dev/null || true
echo "已写入 /etc/modules-load.d/umi-audio.conf，重启后生效"
