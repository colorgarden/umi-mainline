#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
# -*- coding: utf-8 -*-
"""config-audit.py — 审计 out/config-effective（以及任何 .config）

四件事：
  1) **写法体检**：`# CONFIG_FOO is not set` 只要后面多一个字符，merge_config.sh
     就不认，该选项会保持 defconfig 默认值。这类错误在 .config 里完全看不出来，
     只能靠「和片段对不上」发现 —— 这个脚本就是干这个的。
  2) 逐条核对 config/umi.config 里的设置是否真的进了最终 .config
  3) 按「致命 / 重要」清单检查必须项与必须-不要项
  4) 提示还会造成早期静默挂掉的默认值（cpuidle / SMMU bypass / VA_BITS 等）

用法：
    python tools/config-audit.py                             # 用 out/config-effective
    python tools/config-audit.py path/to/.config
    python tools/config-audit.py path/to/.config --fragment config/umi.config
"""
import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RE_SET = re.compile(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$")
RE_NOTSET = re.compile(r"^# CONFIG_([A-Za-z0-9_]+) is not set$")
# 看起来像 not-set 指令、但不是合法形式（merge_config.sh 会忽略它）
RE_LOOKSLIKE = re.compile(r"^#\s*CONFIG_([A-Za-z0-9_]+)\s+is\s+not\s+set")

# (符号, 期望值, 说明)。期望值 "y"/"m"/数字字符串；"n" 表示必须 not set
MUST = [
    # ---- 会直接导致「黑屏 / 静默卡死」的 ----
    ("ARCH_QCOM", "y", "SoC 支持"),
    ("ARM_PSCI_FW", "y", "PSCI；缺了 SMP/reboot 全废"),
    ("ARM_ARCH_TIMER", "y", "架构定时器"),
    ("SERIAL_QCOM_GENI", "y", "ttyMSM0 = uart12"),
    ("SERIAL_QCOM_GENI_CONSOLE", "y", "真正把 log 写出去的是它"),
    ("SERIAL_EARLYCON", "y", "earlycon 框架（arm64 没有 EARLY_PRINTK）"),
    ("VT", "y", "tty0 需要 VT"),
    ("VT_CONSOLE", "y", "tty0 需要 VT_CONSOLE"),
    ("FB", "y", "fbcon 需要 FB"),
    ("FRAMEBUFFER_CONSOLE", "y", "屏幕上的文字"),
    ("FONT_SUPPORT", "y", "fbcon 字体框架"),
    ("FONT_8x16", "y", "tty0 默认字体；缺了屏幕一个字都没有"),
    ("DRM", "y", "simpledrm 需要"),
    ("DRM_KMS_HELPER", "y", "simpledrm 依赖"),
    ("DRM_SIMPLEDRM", "y", "接管 cont-splash 的最小 DRM 驱动"),
    ("DRM_FBDEV_EMULATION", "y", "缺了 fbcon 挂不到 DRM 上 → 屏幕没 log"),
    ("DRM_PANIC", "y", "panic 时把 log 画到屏上"),
    ("DRM_PANIC_SCREEN_QR_CODE", "y", "二维码模式"),
    ("RUST", "y", "二维码生成器是 Rust 写的；缺了 QR 会被静默关掉"),
    ("FONTS", "y", "FONT_TER16x32 的依赖"),
    ("FONT_TER16x32", "y", "panic 屏大字"),
    ("QCOM_WDT", "y", "接管 ABL 留下的 APSS 看门狗；=m 时没人加载 → 内核被复位"),
    ("PINCTRL_SM8250", "y", "TLMM"),
    ("PINCTRL_QCOM_SPMI_PMIC", "y", "pm8150_gpios（音量键、一堆 supply）"),
    ("QCOM_RPMH", "y", "RPMH RSC；时钟/供电全走它"),
    ("QCOM_SMEM", "y", "smem"),
    ("QCOM_COMMAND_DB", "y", "cmd-db；rpmh 的前置"),
    ("REGULATOR_QCOM_RPMH", "y", "ABL 已开好的轨由它接手"),
    ("TYPEC_TCPM", "y", "救援镜像内建 USB PD/PPS 策略"),
    ("TYPEC_QCOM_PMIC", "y", "PM8150B Type-C/PD PHY"),
    ("REGULATOR_QCOM_USB_VBUS", "y", "Type-C probe 依赖 VBUS provider；救援镜像不加载模块"),
    ("REGULATOR_FIXED_VOLTAGE", "y", "pm8150a_l1 等 workaround 轨"),
    ("QCOM_CLK_RPMH", "y", "RPMH 时钟控制器"),
    ("QCOM_GDSC", "y", "GDSC；UFS/USB 供电域"),
    ("ARM_SMMU", "y", "kona 有 SMMU"),
    ("BLK_DEV_SD", "y", "UFS 走 SCSI 盘符"),
    ("SCSI", "y", "同上"),
    ("SCSI_UFSHCD", "y", "UFS 核心"),
    ("SCSI_UFSHCD_PLATFORM", "y", "UFS 平台总线"),
    ("SCSI_UFS_QCOM", "y", "kona UFS 控制器驱动"),
    ("PHY_QCOM_QMP", "y", "UFS PHY 的父节点"),
    ("PHY_QCOM_QMP_UFS", "y", "UFS PHY"),
    ("BLK_DEV_INITRD", "y", "没有它内核会完全忽略 boot.img 里的 ramdisk"),
    ("RD_GZIP", "y", "initramfs 是 .cpio.gz"),
    ("INITRAMFS_SOURCE", '""', "留空：用 boot.img 里的 ramdisk 而不是内嵌"),
    ("PSTORE", "y", "崩溃现场回读"),
    ("PSTORE_RAM", "y", "ramoops 后端"),
    ("PSTORE_CONSOLE", "y", "console 区"),
    ("PSTORE_PMSG", "y", "用户态 /dev/pmsg0"),
    ("LOG_BUF_SHIFT", "21", "2 MB ring buffer"),
    ("PANIC_ON_OOPS", "y", "oops 也走 panic 屏"),
    ("CMDLINE_FORCE", "y", "内置 cmdline 压掉 bootloader 的（保证 console=tty0）"),
    # ---- USB gadget 备份通道 ----
    ("USB", "y", "USB 核心"),
    ("USB_GADGET", "y", "gadget"),
    ("USB_DWC3", "y", "dwc3 核心"),
    ("USB_DWC3_QCOM", "y", "kona dwc3 glue"),
    ("PHY_QCOM_USB_SNPS_FEMTO_V2", "y", "usb_1_hsphy"),
    ("USB_CONFIGFS", "y", "configfs"),
    ("USB_CONFIGFS_ACM", "y", "/dev/ttyGS0"),
    ("USB_CONFIGFS_MASS_STORAGE", "y", "U 盘模式把 log 带出来"),
    ("BLK_DEV_LOOP", "y", "initramfs 里现做 FAT 镜像"),
    ("VFAT_FS", "y", "同上"),
    ("FAT_FS", "y", "VFAT 依赖"),
    ("NLS_CODEPAGE_437", "y", "FAT 依赖"),
    ("NLS_ISO8859_1", "y", "FAT 依赖"),
    # ---- 输入 / 电源 ----
    ("INPUT", "y", "输入子系统"),
    ("INPUT_EVDEV", "y", "/dev/input/event*"),
    ("KEYBOARD_GPIO", "y", "音量键"),
    ("POWER_RESET_QCOM_PON", "y", "长按电源键重启"),
    ("MFD_SPMI_PMIC", "y", "PMIC 本体"),
    ("SPMI", "y", "SPMI 总线"),
    ("SPMI_MSM_PMIC_ARB", "y", "kona SPMI arbiter"),
    ("REGULATOR", "y", "供电框架"),
    # ---- 必须是保守值的（bring-up） ----
    ("ARM64_VA_BITS", "48", "52-bit VA 要走 LVA/LPA2 运行时回退，盲调阶段先固定 48"),
    ("ARM64_ERRATUM_1508412", "y", "Cortex-A77 数据损坏，必须开"),
]

MUST_NOT = [
    ("DRM_MSM", "mdss 会抢走 cont-splash 然后因为没有面板驱动而全黑"),
    ("FB_SIMPLE", "和 DRM_SIMPLEDRM 互斥，同时开会把 console 抢走"),
    ("RANDOMIZE_BASE", "KASLR 关掉，地址可复现"),
    ("WERROR", "别让 warning 中断编译"),
    # 保守组
    ("ARM_PSCI_CPUIDLE", "bring-up 先不开；cpuidle 挂住时屏幕还没起来"),
    ("ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT", "先放行，避免漏一个 iommus 就 DMA abort"),
    ("QCOM_CPR", "会改写 CPU 电压表"),
    ("ARM_QCOM_CPUFREQ_HW", "同上"),
    # 注意：CPU_IDLE 是关不掉的（drivers/acpi/Kconfig:269 的 ACPI_PROCESSOR 会 select 它，
    # 而 arm64 defconfig 里 ACPI=y）。关掉 ARM_PSCI_CPUIDLE 就够了 —— 没有驱动注册，
    # cpuidle core 会直接走 default_idle_call() → WFI。
]

INFO = [
    ("KALLSYMS", "符号表"),
    ("ARM64_BTI", "运行时探测，无 BTI 的 CPU 自动关"),
    ("ARM64_MTE", "运行时探测"),
    ("ARM64_PTR_AUTH", "运行时探测；52-bit VA 会把 PAC 从 7 位压到 3 位"),
    ("ARM64_PA_BITS", "物理地址位宽"),
    ("PGTABLE_LEVELS", "页表级数"),
    ("PSTORE_BLK", "裸分区 pstore（默认待机）"),
    ("PSTORE_DEFAULT_KMSG_BYTES", "if EXPERT，常常静默失效 → 用 cmdline 的 pstore.kmsg_bytes"),
    ("DEBUG_INFO_NONE", "无调试信息"),
    ("LOCALVERSION", "内核版本后缀"),
    ("PANIC_TIMEOUT", "0 = 不自动重启（配合 panic 屏）"),
    ("CMDLINE", "内置 cmdline（CMDLINE_FORCE=y 时是唯一生效的那份）"),
]


def load(path):
    cfg, order = {}, []
    bad_writes = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n").rstrip("\r")
            m = RE_SET.match(line)
            if m:
                cfg[m.group(1)] = m.group(2)
                order.append(m.group(1))
                continue
            if RE_NOTSET.match(line):
                cfg[RE_NOTSET.match(line).group(1)] = "n"
                order.append(RE_NOTSET.match(line).group(1))
                continue
            if RE_LOOKSLIKE.match(line) and not RE_NOTSET.match(line):
                bad_writes.append((lineno, line))
    return cfg, bad_writes


def parse_fragment(path):
    """片段里的有效指令（包括 `# CONFIG_X is not set`），以及写法有问题的那几行。"""
    want, bad = {}, []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n").rstrip("\r")
            m = RE_SET.match(line)
            if m:
                want[m.group(1)] = m.group(2)
                continue
            if RE_NOTSET.match(line):
                want[RE_NOTSET.match(line).group(1)] = "n"
                continue
            if RE_LOOKSLIKE.match(line):
                bad.append((lineno, line))
    return want, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config", nargs="?", default=os.path.join(WS, "out", "config-effective"))
    ap.add_argument("--fragment", action="append",
                    default=None, help="要核对的片段（可重复），默认 umi.config")
    a = ap.parse_args()

    if not os.path.isfile(a.config):
        print("!! 找不到 %s（先跑 scripts/build.sh）" % a.config)
        return 2
    cfg, bad_in_cfg = load(a.config)
    print("== %s  (%d 个符号)" % (a.config, len(cfg)))

    bad = 0

    # ---------------------------------------------------------------- 1 写法
    frags = a.fragment or [os.path.join(WS, "config", "umi.config")]
    print("\n---- [1] 片段写法体检（这一项是「静默失效」的重灾区）----")
    allwant = {}
    nbad = 0
    for fp in frags:
        if not os.path.isfile(fp):
            print("   ?? 片段不存在：%s" % fp)
            continue
        want, badlines = parse_fragment(fp)
        allwant.update(want)
        for lineno, line in badlines:
            nbad += 1
            print("   !! %s:%d  这一行不是合法的 Kconfig 指令，merge_config.sh 会当注释跳过："
                  % (os.path.basename(fp), lineno))
            print("        %s" % line.strip())
            print("        → 正确写法：另起一行 `# CONFIG_XXX is not set`，后面什么都别加")
    for lineno, line in bad_in_cfg:
        nbad += 1
        print("   !! %s:%d  生成的 .config 里也有不合法形式：%s"
              % (os.path.basename(a.config), lineno, line.strip()))
    if not nbad:
        print("   全部合法 OK（%d 条指令）" % len(allwant))
    bad += nbad

    # ---------------------------------------------------------------- 2 生效
    print("\n---- [2] 片段里每条是否真的生效 ----")
    miss = []
    for k, v in allwant.items():
        got = cfg.get(k, "<不存在>")
        # 期望「关」而 .config 里根本没这个符号：说明它没有提示符（依赖不满足被隐藏），
        # 效果等价于关，不算失败。但单独列出来，因为「为什么没提示符」有时正是问题本身。
        if v == "n" and got == "<不存在>":
            continue
        if got != v:
            miss.append((k, v, got))
    if not miss:
        print("   全部 %d 条生效 OK" % len(allwant))
        hidden = [k for k, v in allwant.items()
                  if v == "n" and cfg.get(k, "<不存在>") == "<不存在>"]
        if hidden:
            print("   ·  其中 %d 条「关」的符号在 .config 里根本不存在（依赖不满足被隐藏，等价于关）："
                  % len(hidden))
            print("      " + " ".join(hidden))
    else:
        bad += len(miss)
        for k, v, got in miss:
            hint = ""
            if got == "<不存在>":
                hint = "  （符号不存在：可能 Kconfig 里没这个符号，或依赖不满足）"
            print("   !! CONFIG_%-42s 想要 %-8s 实际 %s%s" % (k, v, got, hint))

    # ---------------------------------------------------------------- 3 必须
    print("\n---- [3] 必须项 ----")
    n3 = 0
    for k, v, why in MUST:
        got = cfg.get(k, "<不存在>")
        if got != v:
            n3 += 1
            print("   !! CONFIG_%-42s = %-10s (应 %s)  <- %s" % (k, got, v, why))
    bad += n3
    print("   %d 项，%d 项不符" % (len(MUST), n3))

    # ---------------------------------------------------------------- 4 不要有
    print("\n---- [4] 必须「不要有」 ----")
    n4 = 0
    for k, why in MUST_NOT:
        got = cfg.get(k, "<不存在>")
        if got not in ("<不存在>", "n"):
            n4 += 1
            print("   !! CONFIG_%-42s = %-8s  <- %s" % (k, got, why))
        else:
            print("   OK CONFIG_%-40s = %s" % (k, got))
    bad += n4

    # ---------------------------------------------------------------- 5 提示
    print("\n---- [5] 提醒 ----")
    for k, why in INFO:
        got = cfg.get(k, "<不存在>")
        print("   %-3s CONFIG_%-38s = %-28s %s"
              % ("·" if got != "<不存在>" else "?", k, got, why))

    # ---------------------------------------------------------------- 6 依赖
    print("\n---- [6] 依赖传染检查（A=y 但 B 没了 → A 可能被静默丢弃）----")
    pairs = [("DRM_SIMPLEDRM", "DRM_KMS_HELPER"),
             ("DRM_PANIC_SCREEN_QR_CODE", "RUST"),
             ("DRM_PANIC", "DRM_KMS_HELPER"),
             ("USB_CONFIGFS_ACM", "USB_CONFIGFS"),
             ("USB_CONFIGFS_MASS_STORAGE", "USB_CONFIGFS"),
             ("SCSI_UFS_QCOM", "PHY_QCOM_QMP_UFS"),
             ("QCOM_RPMH", "QCOM_COMMAND_DB"),
             ("QCOM_RPMH", "QCOM_SMEM"),
             ("FONT_TER16x32", "FONTS")]
    n6 = 0
    for x, y in pairs:
        if cfg.get(x, "n") not in ("n", "<不存在>") and cfg.get(y, "<不存在>") in ("n", "<不存在>"):
            n6 += 1
            print("   !! %s=y 但 %s 不在" % (x, y))
    if not n6:
        print("   没有发现")
    bad += n6

    print("\n== 结论：%s（%d 处问题）" % ("有问题" if bad else "全部通过", bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
