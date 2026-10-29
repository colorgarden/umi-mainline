#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# build.sh — 在 WSL 的 ext4 树上编译 小米10(umi) 主线内核 + DTB
#
#   wsl -d umi -u root -- sh <repo>/scripts/build.sh
#
# 环境变量：
#   TREE=/root/linux          内核树
#   OUT=$TREE/out             kbuild 输出目录
#   WS=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)   工作区（放 dts/ config/ 产物）
#   JOBS=$(nproc)
#   TC=gcc | llvm             工具链，默认 gcc（aarch64-none-elf）
#
# 产物：$WS/out/Image.gz, sm8250-xiaomi-umi.dtb, .config, build.log
set -e

TREE=${TREE:-/root/linux}
WS=${WS:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
OUT=${OUT:-$TREE/out}
JOBS=${JOBS:-$(nproc)}
TC=${TC:-gcc}

case "$TC" in
gcc)  MAKEFLAGS_TC="ARCH=arm64 CROSS_COMPILE=aarch64-none-elf-" ;;
llvm) MAKEFLAGS_TC="ARCH=arm64 LLVM=1" ;;
*) echo "TC 只能是 gcc 或 llvm"; exit 1 ;;
esac

# ---- Rust 工具链（drm_panic 的二维码生成器是 Rust 写的）----
# 需要三样：rustc（版本别太新，用和 6.12 同期的 1.82）、bindgen、libclang（bindgen 靠它解析 C 头）
# 缺 libclang 的话 bindgen 会报 "Unable to find libclang" —— Alpine 里要装 clang22-libclang
if [ -x "$HOME/.cargo/bin/rustc" ]; then
	PATH="$HOME/.cargo/bin:$PATH"
	export PATH
	export RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}
	export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
	# 内核一般能自己从 sysroot 找到 rust-src，找不到就显式指一下
	if [ -z "${RUST_LIB_SRC:-}" ]; then
		SYSROOT=$(rustc --print sysroot 2>/dev/null)
		[ -d "$SYSROOT/lib/rustlib/src/rust/library/core" ] && \
			export RUST_LIB_SRC="$SYSROOT/lib/rustlib/src/rust/library"
	fi
fi
# bindgen 找不到 libclang.so 时给个路径（Alpine 的 clang22-libclang 装在 /usr/lib/llvm22/lib）
if [ -z "${LIBCLANG_PATH:-}" ] && [ -e /usr/lib/llvm22/lib/libclang.so ]; then
	export LIBCLANG_PATH=/usr/lib/llvm22/lib
fi
if ! command -v rustc >/dev/null 2>&1 || ! command -v bindgen >/dev/null 2>&1; then
	echo "!! 没有 Rust 工具链（rustc / bindgen）—— drm_panic 的二维码会被静默关掉。"
	echo "   装： wsl -d umi -u root -- sh $WS/scripts/install-rust.sh"
	echo "   或者： scripts/set-console-path.sh simplefb 并去掉 config/umi.config 里的 CONFIG_RUST/QR 相关行"
	RUST_OK=0
else
	echo "== Rust: $(rustc --version 2>/dev/null) / $(bindgen --version 2>/dev/null) / LIBCLANG_PATH=${LIBCLANG_PATH:-<默认>}"
	RUST_OK=1
fi

mkdir -p "$WS/out"

echo "== [1/6] 同步 DTS 和面板驱动到内核树"
for f in sm8250-xiaomi-umi-common.dtsi sm8250-xiaomi-umi.dts sm8250-xiaomi-umi-plus.dts umi-dtbo-stubs.dtsi xiaomi-umi-panels.dtsi sm8250-xiaomi-umi-touch.dtsi sm8250-xiaomi-umi-wifi.dts xiaomi-umi-battery.dtsi; do
	[ -f "$WS/dts/$f" ] || continue
	cp -f "$WS/dts/$f" "$TREE/arch/arm64/boot/dts/qcom/$f"
done

# ---- 面板驱动：patches/ -> drivers/gpu/drm/panel/，并挂上 Kconfig / Makefile ----
# 驱动本身统一放在工作区 patches/ 下（唯一的真实来源），每次编译时拷进树里。
# 如果直接改树里的那份，树被 rm -rf 重建一次就全丢了。
PANEL_DST="$TREE/drivers/gpu/drm/panel/panel-xiaomi-umi.c"
cp -f "$WS/patches/panel-xiaomi-umi.c" "$PANEL_DST"
PANEL_K="$TREE/drivers/gpu/drm/panel/Kconfig"
if ! grep -q 'DRM_PANEL_XIAOMI_UMI' "$PANEL_K"; then
	cat >> "$PANEL_K" <<'EOF'

config DRM_PANEL_XIAOMI_UMI
	tristate "Xiaomi Mi 10 (umi) AMOLED panel, data-driven from DT"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	select DRM_DISPLAY_DP_HELPER
	select DRM_DISPLAY_HELPER
	help
	  Support for the AMOLED panel used by the Xiaomi Mi 10
	  (SM8250 / "umi"). Panel timing, DSC parameters and the DSI
	  init sequence are all read from the device tree, so a single
	  driver covers every panel variant that device was shipped with
	  (CSOT j2_42_*, Samsung j2_38_*, ...).
EOF
fi
PANEL_MK="$TREE/drivers/gpu/drm/panel/Makefile"
grep -q 'panel-xiaomi-umi' "$PANEL_MK" || \
	printf 'obj-$(CONFIG_DRM_PANEL_XIAOMI_UMI)\t+= panel-xiaomi-umi.o\n' >> "$PANEL_MK"

# ---- 触摸驱动：patches/fts-umi.c -> drivers/input/touchscreen/ ----
FTS_DST="$TREE/drivers/input/touchscreen/fts-umi.c"
cp -f "$WS/patches/fts-umi.c" "$FTS_DST"
FTS_K="$TREE/drivers/input/touchscreen/Kconfig"
if ! grep -q 'TOUCHSCREEN_FTS_UMI' "$FTS_K"; then
	cat >> "$FTS_K" <<'EOF'

config TOUCHSCREEN_FTS_UMI
	tristate "STMicroelectronics FTS touchscreen (Xiaomi Mi 10)"
	depends on I2C
	depends on OF
	help
	  Minimal driver for the STMicroelectronics FTS touch controller
	  found on the Xiaomi Mi 10 ("umi"), sitting on i2c13 at 0x49.
	  Firmware and configuration live in the controller's own flash,
	  so neither a firmware blob nor a regulator is touched.
EOF
fi
FTS_MK="$TREE/drivers/input/touchscreen/Makefile"
grep -q 'fts-umi' "$FTS_MK" || \
	printf 'obj-$(CONFIG_TOUCHSCREEN_FTS_UMI)\t+= fts-umi.o\n' >> "$FTS_MK"

# ---- 触摸驱动选择 ----
#   TOUCH=fts521 （默认）主线移植版，走标准 i2c_transfer + umi-i2c 适配器
#   TOUCH=stfts        厂商 5.2.4 驱动，取自 zhaoyuanwang123/armbian 的
#                      patch/kernel/archive/sm8250-7.2/0043-…patch
#                      （带 FW_UPDATE_ON_PROBE / PRE_SAVED_METHOD / FOD）
TOUCH_SEL=${TOUCH:-fts521}
echo "   touch driver: $TOUCH_SEL"

if [ "$TOUCH_SEL" = stfts ]; then
	ST_SRC="$WS/stfts"
	if [ -d "$ST_SRC" ]; then
		ST_DST="$TREE/drivers/input/touchscreen/stfts"
		rm -rf "$ST_DST"
		cp -r "$ST_SRC" "$ST_DST"
		# 补丁里的源码是 CRLF 的，内核构建吃不了
		find "$ST_DST" -type f -exec sed -i 's/\r$//' {} +
		grep -q 'touchscreen/stfts/Kconfig' "$FTS_K" || \
			printf 'source "drivers/input/touchscreen/stfts/Kconfig"\n' >> "$FTS_K"
		grep -q 'stfts/' "$FTS_MK" || \
			printf 'obj-$(CONFIG_TOUCHSCREEN_ST_FTS)\t+= stfts/\n' >> "$FTS_MK"
		echo "   stfts: $(ls "$ST_DST" | tr '\n' ' ')"
	fi
fi

# ---- 参考实现：sm7150-mainline 的 fts521（主线 ST FTS5 驱动）----
# 它只通过标准 i2c_transfer() 说话，所以配 umi-i2c 那个 bit-bang 适配器用。
# 目的不是替换 fts-umi，而是拿一份「别处已经跑通的主线实现」去 probe 同一颗芯片：
# 要么它直接能用，要么它同样失败 —— 那软件面就真的到头了。
REF_SRC="$WS/fts521"
if [ -d "$REF_SRC" ] && [ "$TOUCH_SEL" != stfts ]; then
	REF_DST="$TREE/drivers/input/touchscreen/fts521"
	rm -rf "$REF_DST"
	mkdir -p "$REF_DST/fts_lib"
	cp -f "$REF_SRC/Kconfig" "$REF_SRC/Makefile" "$REF_DST"/ 2>/dev/null
	cp -f "$REF_SRC/fts.c" "$REF_SRC/fts.h" "$REF_DST"/ 2>/dev/null
	cp -f "$REF_SRC/fts_lib/"* "$REF_DST/fts_lib"/ 2>/dev/null
	cp -f "$WS/patches/umi-i2c.c" "$TREE/drivers/input/touchscreen/umi-i2c.c"
	if ! grep -q 'TOUCHSCREEN_ST_FTS_V521' "$FTS_K"; then
		cat >> "$FTS_K" <<'EOF'

config TOUCHSCREEN_ST_FTS_V521
	tristate "STMicroelectronics FTS V521 touchscreen (mainline port)"
	depends on I2C
	depends on OF
	help
	  Mainline driver for the ST FTS5 controller family, taken from the
	  sm7150-mainline port of the ST driver.  Plain i2c_transfer() only.

config I2C_UMI_BITBANG
	tristate "Bit-banged i2c adapter for the Xiaomi Mi 10 touch bus"
	depends on I2C
	depends on GPIOLIB
	help
	  Exposes the two touch bus pins as a real i2c_adapter so that standard
	  i2c drivers can probe the controller at 0x49.
EOF
	fi
	grep -q 'fts521/' "$FTS_MK" || \
		printf 'obj-$(CONFIG_TOUCHSCREEN_ST_FTS_V521)\t+= fts521/\n' >> "$FTS_MK"
	grep -q 'umi-i2c' "$FTS_MK" || \
		printf 'obj-$(CONFIG_I2C_UMI_BITBANG)\t+= umi-i2c.o\n' >> "$FTS_MK"
fi
# ---- 电量计 / 充电：power/*.c -> drivers/power/supply/ ----
# 驱动来源：zhaoyuanwang123/armbian 的 sm8250-7.2 补丁 0024/0025（qcom_fg）、
# 0028/0037/0039/0041（qcom_pm8150b_charger）、0511（bq25970）。
# 0037 还要求 power_supply 核心多一个 POWER_SUPPLY_PROP_CHARGING_ENABLED，
# 用一个 python 补丁加上（幂等）。
PWR_SRC="$WS/power"
if [ -d "$PWR_SRC" ]; then
	PWR_DST="$TREE/drivers/power/supply"
	cp -f "$PWR_SRC/qcom_fg.c" "$PWR_SRC/qcom_pm8150b_charger.c" \
	      "$PWR_SRC/bq25970_charger.c" "$PWR_SRC/bq25970_reg.h" "$PWR_DST"/ 2>/dev/null || true
	PWR_K="$PWR_DST/Kconfig"
	PWR_MK="$PWR_DST/Makefile"
	if ! grep -q 'BATTERY_QCOM_FG' "$PWR_K"; then
		cat >> "$PWR_K" <<'EOF'

config BATTERY_QCOM_FG
	tristate "Qualcomm PMIC fuel gauge driver"
	depends on IIO
	help
	  Qualcomm PMIC fuel gauge (PM8150B gen3), from the sm8250-mainline
	  bring-up.  Reports capacity/voltage/current of the battery.

config CHARGER_QCOM_SMB5
	tristate "Qualcomm PM8150B PMIC charger driver"
	depends on IIO
	help
	  PM8150B SMB5 charger: VBUS/ICL/FCC control and charger status.

config CHARGER_BQ25970
	tristate "TI BQ25970 battery charger driver"
	depends on I2C
	help
	  TI BQ25970 40W fast charger found in the Mi 10.
EOF
	fi
	grep -q 'qcom_fg' "$PWR_MK"        || printf 'obj-$(CONFIG_BATTERY_QCOM_FG)\t+= qcom_fg.o\n' >> "$PWR_MK"
	grep -q 'qcom_pm8150b_charger' "$PWR_MK" || \
		printf 'obj-$(CONFIG_CHARGER_QCOM_SMB5)\t+= qcom_pm8150b_charger.o\n' >> "$PWR_MK"
	grep -q 'bq25970_charger' "$PWR_MK" || \
		printf 'obj-$(CONFIG_CHARGER_BQ25970)\t+= bq25970_charger.o\n' >> "$PWR_MK"
	python3 "$WS/patches/power-supply-charging-enabled.py" \
		"$TREE/include/linux/power_supply.h" \
		"$PWR_DST/power_supply_sysfs.c" || echo "   !! power_supply 属性补丁没打上"
fi

# ---- 电量计 / 充电 ---- end

# ---- GPI DMA：补上 sm8250 的两个 EE 偏移变体 ----
# 6.12.94 的 gpi_of_match 只有 "qcom,sm8250-gpi-dma"（ee_offset 0），而 sm8250
# 的两个 GPI 控制器 EE 窗口偏移并不相同（wrap0 = 0x1000 / wrap1 = 0x6000；
# 这两个值是从一份能工作的 sm8250 内核的 of_device_id data 字段里读出来的）。
# 不补的话 wrap1 的 ee_base 算错，GPI 命令永远等不到完成：
#   gpi a00000.dma-controller: cmd: EV ALLOCATE completion timeout:2
#   geni_i2c a94000.i2c: error -ENODEV: Failed to setup GPI DMA mode
if [ -f "$TREE/drivers/dma/qcom/gpi.c" ]; then
	python3 "$WS/patches/gpi-sm8250-ee-offset.py" \
		"$TREE/drivers/dma/qcom/gpi.c" || echo "   !! gpi 补丁没打上"
fi

# ---- shared-GPIO：7.x 不能对 reserved 行做代理 ----
# sm8250 的 NORTH tile 在这块板子上读不了，DTS 里用 gpio-reserved-ranges 标掉。
# 7.x 新增的 shared-GPIO 机制仍会去 request 其中被引用到的行（GPIO66），拿到
# -EINVAL 后整个 gpiochip 注册失败，GPIO/i2c/触摸全挂。
if [ -f "$TREE/drivers/gpio/gpiolib-shared.c" ]; then
	python3 "$WS/patches/gpiolib-shared-reserved-guard.py" \
		"$TREE/drivers/gpio/gpiolib-shared.c" || echo "   !! shared-gpio 补丁没打上"
fi

MK=$TREE/arch/arm64/boot/dts/qcom/Makefile
for d in sm8250-xiaomi-umi sm8250-xiaomi-umi-plus sm8250-xiaomi-umi-wifi; do
	grep -q "$d\.dtb" "$MK" || \
		printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= %s.dtb\n' "$d" >> "$MK"
	# ★ 必须用 -@ 编译：ABL 会往 base DTB 上打 dtbo overlay，overlay 靠 __symbols__
	#   解析 &label。不带 -@ 就没有 __symbols__，overlay 全失败 -> ABL 静默回 fastboot。
	#   （踩过：build.sh 的 make dtbs 会把 dtb-only.sh 生成的好 DTB 覆盖掉。）
	grep -q "DTC_FLAGS_$d" "$MK" || \
		printf 'DTC_FLAGS_%s\t:= -@\n' "$d" >> "$MK"
done

echo "== [2/6] defconfig"
make -s -C "$TREE" $MAKEFLAGS_TC O="$OUT" defconfig

echo "== [3/6] 合并 umi.config 片段"
# 不依赖 merge_config.sh，直接把片段追加到 .config 末尾：
# kconfig 解析时后出现的赋值覆盖前面的，olddefconfig 会把重复项整理干净。
# 只保留真正的配置行；"# CONFIG_X is not set" 也要保留（它是有效的否定形式）。
#
# ★★ 这里最容易出的错：`# CONFIG_X is not set` 后面多一个字符就会被下面的 case
#    模式匹配不到 → 静默跳过 → 该选项保持 defconfig 默认值。
#    CONFIG_DRM_MSM 以前就是这么被悄悄编成 =m 的。所以现在对「看着像但其实不合法」
#    的行直接报错，不再静默。
FRAG="$OUT/frag.clean"
: > "$FRAG"
badfrag=0
while IFS= read -r line; do
	case "$line" in
	CONFIG_*=*) printf '%s\n' "$line" >> "$FRAG" ;;
	"# CONFIG_"*" is not set") printf '%s\n' "$line" >> "$FRAG" ;;
	"# CONFIG_"*" is not set"[!\ ]*|"# CONFIG_"*" is not set "*)
		echo "   !! 非法指令（后面多了字符，会被 kconfig 当注释跳过）："
		echo "      $line"
		echo "      → 改成独占一行的 '# CONFIG_XXX is not set'"
		badfrag=1 ;;
	esac
done < "$WS/config/umi.config"
if [ "$badfrag" = 1 ]; then
	echo "!! config/umi.config 里有非法指令，先修再编译"
	exit 2
fi
cat "$FRAG" >> "$OUT/.config"
# TOUCH=stfts：换掉 umi.config 里的主线触摸选项（后写的覆盖前面的）
if [ "${TOUCH_SEL:-fts521}" = stfts ]; then
	{
		echo '# CONFIG_TOUCHSCREEN_ST_FTS_V521 is not set'
		echo '# CONFIG_TOUCHSCREEN_FTS_UMI is not set'
		echo 'CONFIG_TOUCHSCREEN_ST_FTS=y'
		echo 'CONFIG_FTS_FOD_AREA_REPORT=y'
	} >> "$OUT/.config"
fi
make -s -C "$TREE" $MAKEFLAGS_TC O="$OUT" olddefconfig

echo "== [4/6] 校验关键配置是否真的生效"
fail=0
cfgval() {           # cfgval 符号 -> 打印值（不存在则打印 <absent>）
	v=$(sed -n "s/^CONFIG_$1=\(.*\)\$/\1/p" "$OUT/.config" | tail -1)
	[ -n "$v" ] || v="<absent>"
	printf '%s' "$v"
}
check_y() {
	v=$(cfgval "$1")
	[ "$v" = "y" ] && echo "   OK   $1=y" || { echo "   FAIL $1=$v"; fail=1; }
}
# ★ 以前这里只判 =y，漏掉了 =m —— 而 CONFIG_DRM_MSM=m 正是 defconfig 的默认值，
#   于是一个「必须关掉」的选项在 build.sh 这里被当成 OK 放过去了。现在 y 和 m 都算「开着」。
check_n() {
	v=$(cfgval "$1")
	case "$v" in
	y|m) echo "   FAIL $1=$v（应该关掉）"; fail=1 ;;
	*)   echo "   OK   $1 关闭（$v）" ;;
	esac
}
check_v() {          # check_v 符号 期望值
	v=$(cfgval "$1")
	[ "$v" = "$2" ] && echo "   OK   $1=$2" || { echo "   FAIL $1=$v（应为 $2）"; fail=1; }
}
for s in SERIAL_QCOM_GENI SERIAL_QCOM_GENI_CONSOLE DRM_SIMPLEDRM DRM \
           FRAMEBUFFER_CONSOLE VT_CONSOLE PSTORE_RAM SCSI_UFS_QCOM \
           USB_DWC3_QCOM REGULATOR_QCOM_RPMH PINCTRL_SM8250 QCOM_WDT \
           DRM_PANIC BLK_DEV_INITRD RD_GZIP ARM64_ERRATUM_1508412 ARM_PSCI_CPUIDLE \
           QCOM_COMMAND_DB QCOM_SMEM ARCH_QCOM \
           DRM_MSM DRM_MSM_MDSS DRM_MSM_DPU DRM_MSM_DSI DRM_MSM_DSI_7NM_PHY; do
	check_y "$s"
done
# 面板驱动：只有它编进去了，&mdss_dsi0 下面那个 umi-panel 节点才有人接。
# 编成模块（=m）等于没编：initramfs 里不会去加载它，DSI 就一直 EPROBE_DEFER。
check_y DRM_PANEL_XIAOMI_UMI
check_y TYPEC_TCPM
check_y TYPEC_QCOM_PMIC
check_y REGULATOR_QCOM_USB_VBUS
# 触摸：同样是 =m 等于没编（initramfs 无模块加载器）。
#   TOUCH=fts521（默认）主线移植版，走标准 i2c_transfer
#   TOUCH=stfts         厂商 5.2.4 驱动（取自 zhaoyuanwang123/armbian 的
#                       sm8250-7.2 补丁 0043），带 FW_UPDATE_ON_PROBE/FOD
if [ "${TOUCH:-fts521}" = stfts ]; then
	check_y TOUCHSCREEN_ST_FTS
else
	check_y I2C_UMI_BITBANG
	check_y TOUCHSCREEN_ST_FTS_V521
fi
check_y I2C_QCOM_GENI
check_y QCOM_GPI_DMA
# 「必须关掉」的（y 或 m 都算失败）
# 注意不含 CPU_IDLE：drivers/acpi/Kconfig:269 的 ACPI_PROCESSOR 会 select 它，关不掉。
# 关掉 ARM_PSCI_CPUIDLE 就等于关掉了 arm64/DT 下唯一会注册的 cpuidle 驱动。
for s in FB_SIMPLE RANDOMIZE_BASE WERROR \
         QCOM_CPR ARM_QCOM_CPUFREQ_HW; do
	check_n "$s"
done
# SMMU bypass：6.12 上还能在编译期关掉，7.x 起它变成 default y 且只在
# CONFIG_EXPERT 下可见，写 "# ... is not set" 会被 olddefconfig 改回去。
# 真正生效的开关是 cmdline 里的 arm-smmu.disable_bypass=0，所以这里按它判断。
if grep -q '^CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y' "$OUT/.config"; then
	if grep -q 'arm-smmu.disable_bypass=0' "$OUT/.config"; then
		echo "   OK   SMMU bypass 由 cmdline 关闭（arm-smmu.disable_bypass=0）"
	else
		echo "   FAIL ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y 且 cmdline 里没有 disable_bypass=0"
		fail=1
	fi
else
	echo "   OK   ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT 关闭"
fi
# 必须等于特定值
check_v ARM64_VA_BITS 48
check_v CMDLINE_FORCE y
check_v INITRAMFS_SOURCE '""'
check_v LOG_BUF_SHIFT 21
if [ "$RUST_OK" = 1 ]; then
	check_y RUST
	check_y DRM_PANIC_SCREEN_QR_CODE
fi
check_y FONT_TER16x32
echo "   PANIC_SCREEN: $(sed -n 's/^CONFIG_DRM_PANIC_SCREEN="\(.*\)"$/\1/p' "$OUT/.config" | tail -1)"
sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$OUT/.config" | tail -1 | sed 's/^/   CMDLINE: /'
if [ "$fail" = 1 ]; then
	echo "!! 配置校验失败，先修 config/umi.config 再编译（见 $OUT/.config）"
	echo "   把片段和 .config 对一遍： python tools/config-audit.py $OUT/.config"
	exit 2
fi

echo "== [5/6] 编译（-j$JOBS, TC=$TC）"
# 先删旧产物：编译失败时下面的存在性检查才能真的报错（踩过：编挂了却拿旧 Image.gz 打包）
rm -f "$OUT/arch/arm64/boot/Image.gz" "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi.dtb"
( make -C "$TREE" $MAKEFLAGS_TC O="$OUT" -j"$JOBS" Image.gz dtbs ) 2>&1 | tee "$OUT/build.log" | tail -25
# tee 之后 make 的退出码在 POSIX sh 里拿不到，用产物判断
for p in "$OUT/arch/arm64/boot/Image.gz" \
         "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi.dtb"; do
	[ -s "$p" ] || { echo "!! 编译失败：缺少 $p（完整日志 $OUT/build.log）"; exit 3; }
done

echo "== [6/6] 收集产物到 $WS/out"
cp -f "$OUT/arch/arm64/boot/Image.gz"      "$WS/out/Image.gz"
cp -f "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi.dtb"      "$WS/out/sm8250-xiaomi-umi.dtb"
[ -f "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi-plus.dtb" ] && \
	cp -f "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi-plus.dtb" "$WS/out/sm8250-xiaomi-umi-plus.dtb"
[ -f "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi-wifi.dtb" ] && \
	cp -f "$OUT/arch/arm64/boot/dts/qcom/sm8250-xiaomi-umi-wifi.dtb" "$WS/out/sm8250-xiaomi-umi-wifi.dtb"
cp -f "$OUT/.config" "$WS/out/config-effective"
ls -l "$WS/out" | sed -n '1,20p'
echo "== 完成"
