#!/bin/sh
# 从 armbian 的 blobless clone 里按需取回 umi 的文本配置文件
# （git cat-file 会按需从 origin 拉 blob，走的是 clone 时用的代理）
set -e
REPO=/mnt/d/project/UMI-mainline
BUILD="$REPO/tmp/armbian/build"
cd "$BUILD"

get() { # get <sha> <dest>
	git cat-file blob "$1" > "$2"
	echo "  $(wc -c < "$2") B  $2"
}

mkdir -p "$REPO/contrib/alsa-ucm" "$REPO/contrib/sensors"

echo "== ALSA UCM"
get 72877611a387548a34cca62ac7370eed1878ec1c "$REPO/contrib/alsa-ucm/HiFi.conf"
get c7cb3cf241e80642fd1bc446eacc86df7d5a1e0e "$REPO/contrib/alsa-ucm/VoiceCall.conf"
get df4e9f512d0d972166e721ac2746929df8fea185 "$REPO/contrib/alsa-ucm/Xiaomi Mi 10.conf"
get 2f5142346e6c5888a800c9a4b19f8a1bb21d406a "$REPO/contrib/alsa-ucm/umi-voice-topology.service"

echo "== sensors"
get eaf100a7f65bbebdf769f8962dec864535f51f9e "$REPO/contrib/sensors/README.md"
get 6ac82c87e4c348a6e23bddab7a9255bbac245901 "$REPO/contrib/sensors/umi-sensors.conf"
get 8e09de3c6dcef873a640ee8efc2382f779ad6e69 "$REPO/contrib/sensors/81-libssc-xiaomi-umi.rules"
get cac73350a7490a4ff070d9cb58ddd3db748aeabd "$REPO/contrib/sensors/60-fastrpc-umi.rules"
get a4dcb79462849c22ea63a8454019bab1102a3c60 "$REPO/contrib/sensors/hexagonrpcd-sdsp.service"
get 729f25f32caf466157fe3280ea6c734fb7124ec5 "$REPO/contrib/sensors/hexagonrpcd-sdsp.service.d-10-umi.conf"
get af099eaf4aedb81eccbca99cbf5008904c60d861 "$REPO/contrib/sensors/hexagonrpcd-adsp-rootpd.service"
get fc8a6c0bf2b4d2270e8009fbeb649433d3ba5d28 "$REPO/contrib/sensors/hexagonrpcd-adsp-rootpd.service.d-10-umi.conf"
get df1beea9770a5c613f129f7cbf3c9e315d612a55 "$REPO/contrib/sensors/hexagonrpcd-adsp-sensorspd.service"
get 8de092e368b57e0ee5cb925063faa468804d0bec "$REPO/contrib/sensors/hexagonrpcd-adsp-sensorspd.service.d-10-umi.conf"
echo "== done"
