#!/bin/sh
# mkimage.sh —— **唯一**的镜像入口：编内核 + 打一张全功能镜像 out/boot-umi.img
#
#   wsl -d umi -u root -- sh /mnt/d/project/UMI-mainline/scripts/mkimage.sh
#
# 这张镜像里同时有（都在内核/DT 里，不需要再挑）：
#   - 面板驱动（CSOT j2_mp_42_02_0b，DSC cmd mode）
#   - 触摸（fts521 主线移植版；换厂商版用 TOUCH=stfts 并另存名）
#   - GPU（Adreno 650，DT 打开 gmu/gpu + initramfs 里的 a650 固件）
#   - WiFi/BT（QCA6390 PCIe，MAC 固定）
#   - 电量计 / 充电器 / 快充（PM8150B fg + SMB5 + bq25970）
#
# 也就是说：**平时只需要刷这一张**。其它 boot-umi-*.img 都是实验对照，
# 要么是某个驱动还没合进来的验证版（TOUCH=stfts），要么是历史遗留。
set -e
WS=${WS:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
NAME=${NAME:-boot-umi.img}

echo "== [1/2] 编内核（默认配置：全功能）=="
sh "$WS/scripts/build.sh"

echo "== [2/2] 打包 $WS/out/$NAME =="
python3 "$WS/tools/pack-umi.py" \
--dtb "$WS/out/sm8250-xiaomi-umi.dtb" \
	-o "$WS/out/$NAME"

ls -l "$WS/out/$NAME"
echo "== 完成：fastboot boot out/$NAME =="
