#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# dtb-only.sh — 只编译 DTB（cpp + dtc），不走 kbuild，改 DTS 后秒级验证
#   wsl -d umi -u root -- sh <repo>/scripts/dtb-only.sh
#   wsl -d umi -u root -- sh <repo>/scripts/dtb-only.sh sm8250-xiaomi-umi
set -e

TREE=${TREE:-/root/linux}
WS=${WS:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
OUT=${OUT:-$WS/out}
D="$TREE/arch/arm64/boot/dts/qcom"
INC=$(gcc -print-file-name=include)

if [ $# -eq 0 ]; then
set -- sm8250-xiaomi-umi
fi

# 先把工作区的 dts/ 同步进树里，避免改的是 A 编的是 B
for f in sm8250-xiaomi-umi-common.dtsi sm8250-xiaomi-umi.dts umi-dtbo-stubs.dtsi xiaomi-umi-panels.dtsi sm8250-xiaomi-umi-touch.dtsi xiaomi-umi-battery.dtsi; do
	[ -f "$WS/dts/$f" ] && cp -f "$WS/dts/$f" "$D/$f"
done

mkdir -p "$OUT"
rc=0
for base in "$@"; do
	base=$(basename "$base" .dts)
	if [ ! -f "$D/$base.dts" ]; then
		echo "!! $D/$base.dts 不存在" >&2
		rc=1
		continue
	fi
	if ! gcc -E -nostdinc -isystem "$INC" \
			-I "$TREE/include" -I "$D" -I "$TREE/arch/arm64/boot/dts" \
			-undef -D__DTS__ -x assembler-with-cpp \
			-o "$OUT/$base.dts.cpp" "$D/$base.dts" 2>"$OUT/$base.cpp.log"; then
		echo "!! $base: 预处理(cpp)失败" >&2
		sed -n '1,40p' "$OUT/$base.cpp.log" >&2
		rc=1
		continue
	fi
	if ! dtc -@ -I dts -O dtb -o "$OUT/$base.dtb" \
			-W no-unit_address_vs_reg "$OUT/$base.dts.cpp" 2>"$OUT/$base.dtc.log"; then
		echo "!! $base: dtc 失败" >&2
		sed -n '1,40p' "$OUT/$base.dtc.log" >&2
		rc=1
		continue
	fi
	# dtc 的警告也打出来（Warning 往往是真问题，比如打断了某个节点）
	# 上游 sm8250.dtsi / pm8150b.dtsi 本身带一堆 unique_unit_address 噪声，只保留跟 umi 有关的
	if [ -s "$OUT/$base.dtc.log" ]; then
		REL=$(grep -E 'umi' "$OUT/$base.dtc.log" || true)
		if [ -n "$REL" ]; then
			echo "   $base 警告（与 umi 相关）:" >&2
			printf '%s\n' "$REL" | sed -n '1,30p' | sed 's/^/     /' >&2
		else
			echo "   $base 只有上游 dtsi 的已知噪声警告，忽略" >&2
		fi
	fi
	echo "OK  $OUT/$base.dtb  $(stat -c%s "$OUT/$base.dtb") bytes"
done
exit $rc
