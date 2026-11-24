# umi-mainline

Running a mainline Linux kernel on the **Xiaomi Mi 10** (SM8250 / "kona",
device codename `umi`, model M2001J2C).

This is a working bring-up, not a plan: the kernel boots to userspace in about
12 seconds, drives the 1080×2340 command-mode AMOLED over DSC, dims it, turns
it off and back on, and reads the ST FTS touchscreen. Nothing here flashes a
partition — the kernel is always loaded into RAM with `fastboot boot`.

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x411fd050]
[    0.000000] Linux version 6.12.94-umi (root@umi) #1 SMP PREEMPT ...
[   11.9]      msm_dpu ae01000.display-controller: bound ae94000.dsi
[   12.0]      [drm] Initialized msm 1.12.0 for ae01000.display-controller on minor 1
[   12.4]      Console: switching to colour frame buffer device 135x146
[   12.4]      fts-umi 3-0049: chip id 9886, chip ver ..., fw ver ..., 1080x2340, 10 slots
```

## Status

| Subsystem | State | Notes |
|---|---|---|
| Kernel boot | **works** | 6.12.x, ~12 s to a serial root shell |
| Display | **works** | 1080×2340@60, DSC v1.1, 4-lane command mode |
| Framebuffer console | **works** | `msmdrmfb`, fbcon on card1 |
| Backlight | **works** | 1..2047 via `/sys/class/backlight`, usable range starts ~1000 |
| Power off / on | **works** | sleep-in + reset + full 652-byte init sequence |
| Touchscreen | **works** | ST FTS on `i2c13`, 10 slots, MT-B; needs the `vdd_boost_reg` (PM8150B GPIO5) rail, see `docs/TOUCH.md` §12 |
| Serial console | **works** | USB CDC-ACM on `ttyMSM0`, 115200 |
| USB mass storage | **works** | initramfs exports its report directory as a disk |
| pstore / ramoops | **works** | last crash survives a reboot |
| CPU / clock / regulator | **partial** | boots with `clk_ignore_unused`, `pd_ignore_unused`, `regulator_ignore_unused` |
| GPU (Adreno 650) | **works** | `gpu-initialized: 1`, devfreq 305–587 MHz; `a650_*` firmware must be in the initramfs, see `docs/GPU.md` |
| Wi-Fi (QCA6390) | **works** | `sm8250-xiaomi-umi-wifi.dts` + `ath11k`, MAC pinned `00:03:7f:12:a4:a4`, see `docs/WIFI.md` §14 |
| Vulkan / OpenGL | **works** | turnip (`vulkan-freedreno`) + freedreno: Vulkan 1.3.354, GL 4.6 / GLES 3.2 (`FD650`), see `docs/GPU.md` §5.1 |
| KDE Plasma Mobile | **works** | 6.8.1 on Wayland (kwin_wayland, scale 2.5), boot straight into it; see `docs/KDE.md` |
| Rootfs on UFS | **works** | 223 GiB ext4 on userdata (`/dev/sda34`) |
| 90 Hz mode | works | second timing exists in the panel node, not enabled |

## Hardware

* SoC: Qualcomm SM8250 (Snapdragon 865), 8 cores
* Display: 1080×2340 AMOLED, command mode, DSC 8bpc/8bpp, slice 540×12
* Panel variant on the test device: `j2_mp_42_02_0b__dsc_cmd` (**CSOT / 华星光电**, vendor code `42`)
* Touch: **STMicroelectronics FTS** at `i2c@a94000` (QUPV3 wrap1 SE5), address
  `0x49`, reset GPIO38, IRQ GPIO39, level low
* Power: pm8150 / pm8150l / pm8150b / pm8009

The panel and the touch controller are both variants: the same phone shipped
with CSOT and Samsung panels and with Goodix GT9889 (address `0x5d`, on the
same I2C bus) as the touch alternative. The panel driver is data-driven from DT
so it covers every panel; the touch driver speaks the FTS protocol only.

## Build

Everything is built inside WSL (Alpine on ext4; building on a Windows mount is
painfully slow). One script does the whole job — driver installation, Kconfig
wiring, defconfig, config fragment merge, `make Image.gz dtbs`, and artifact
collection:

```sh
wsl -d umi -u root -e sh scripts/build.sh     # run from the repo root
```

Environment overrides: `TREE` (kernel tree, default `/root/linux`), `OUT`,
`WS`, `JOBS`, `TC=gcc|llvm`.

Requirements:
* a mainline kernel tree, 6.12 or newer, at `$TREE`
* `aarch64-none-elf-` GCC (or clang with `TC=llvm`)
* for `CONFIG_DRM_PANIC_SCREEN_QR_CODE`: a Rust toolchain plus `bindgen` and
  `libclang` (`scripts/install-rust.sh`)

Then pack an Android boot image (header v2, gzip kernel, DTB appended):

```sh
python tools/pack-umi.py --name p16-touch
```

## Boot it

```sh
adb reboot bootloader
fastboot devices
fastboot boot out/boot-umi-p16-touch.img
```

`fastboot boot` downloads the image into RAM and jumps to it. It does **not**
write to any partition, so the installed Android stays untouched — power-cycling
the phone returns to MIUI.

Two gotchas that cost days:

* **Only one `fastboot boot` per bootloader session.** A second one fails with
  `Failed to load/authenticate boot image`; run `fastboot reboot-bootloader`
  in between.
* **`fastboot boot` wants a compressed kernel.** ABL refuses an uncompressed
  `Image` and wants either gzip or `ARM\x64` at offset 56 of the kernel blob.

## Technical notes

The interesting part of this port is the list of things that silently fail.

**The bootloader resolves device-tree overlays by symbol.** ABL applies 29
overlay fragments on top of the base DTB and resolves every `&label` reference
through `__symbols__`. One missing label and the overlay set is dropped without
a single line of output. So the base DTB must be compiled with `dtc -@`, and
`dts/umi-dtbo-stubs.dtsi` adds 200+ placeholder labels that exist only to keep
the downstream overlays resolvable.

**The vendor DSI command format is not the mainline one.** Downstream
`qcom,mdss-dsi-on-command` is a byte stream of packets with a **7-byte header**
per packet:

```
dtype(1) last(1) vc(1) ack(1) wait(1) dlen(2, big endian)
```

`wait` is in **milliseconds** (the vendor driver calls
`usleep_range(wait * 1000, ...)`), and `last` is not a terminator — the vendor
driver ignores it and walks `dlen` instead. 32-bit cells inside `<...>` are
written one byte per cell, big-endian.

**DSC PPS is generated by the driver, not by the panel sequence.** The 652-byte
init sequence of this panel contains 59 packets and *none* of them is a PPS
packet, even though the panel runs DSC. The PPS has to be built from the DT
parameters with `drm_dsc_pps_payload_pack()` and sent with
`mipi_dsi_picture_parameter_set()`.

**No panel, no DPU.** `component_bind_all()` (which contains `dsi_bind()` and
needs a panel) runs *before* `msm_drm_kms_init()` → `dpu_kms_init()`. There is
no way to "test the DPU first and add the panel later": the panel node has to be
present before anything display-related initialises.

**Unclaimed regulators get switched off 42 seconds in.** `display_panel_vci` and
`touch_vddio_vreg` are enabled by the bootloader but have no consumer in Linux,
so `regulator_late_cleanup()` disables them mid-boot and the panel goes dark.
Booting with `regulator_ignore_unused` fixes it — the rails are left exactly as
the bootloader left them, nothing is reprogrammed.

**Brightness is not linear.** 400 out of 2047 is pure black, 1500 is comfortable
indoors. A "perfectly initialised panel" with brightness 400 looks exactly like
a broken one. This single number cost more debugging time than the whole DSI
link.

**The touch protocol is 8-byte events read one at a time.** Command `0x85`
returns one event; `0x00` in byte 0 means "FIFO empty". The class/object
encoding, the 12-bit coordinate packing and the fallback for the older flat
event codes are documented at the top of `patches/fts-umi.c`.

## Layout

```
config/umi.config              config fragment merged on top of defconfig
dts/                           device trees (SM8250 umi, panel data, DTBO stubs, touch)
patches/                       out-of-tree kernel drivers
initramfs/                     init script (busybox, serial shell, report export)
scripts/                       build / initramfs / environment helpers (shell)
tools/                         host-side helpers (python + powershell)
docs/                          porting notes, hardware notes, boot logs
LICENSES/                      full text of every license used here
```

`dump/`, `downstream-kernel/`, `rootfs/` and `out/` are working directories and
are not tracked (see `.gitignore`).

## License

This repository mixes licenses on purpose; `LICENSE` has the table and
`LICENSES/` the full texts.

* `patches/` — **GPL-2.0-only** (a driver cannot enter the kernel otherwise)
* `dts/` — **BSD-3-Clause** (same as the upstream Qualcomm device trees)
* `scripts/`, `tools/` — **CC0-1.0** (public domain, no attribution needed)
* `docs/`, this README — **CC-BY-4.0**

## Third-party material

The port was written by reading a vendor kernel and a vendor device tree that
were already present on the device. Those sources, the decompiled vendor DT and
any firmware images are **not** redistributed here; only the facts that matter
(register values, timings, GPIO numbers, protocol layout) are recorded, in
`docs/HARDWARE.md` and in the source comments.

No voltage, current or power limit is ever changed by this project. Regulators
are enabled and left at the value the bootloader programmed.

## 中文速览

小米 10（umi / SM8250）主线内核移植。目前已经能启动、点亮 1080×2340 屏幕、
调亮度、熄屏再亮、**触摸可用**、**Adreno 650 可用**（GL 4.6 / Vulkan 1.3，
devfreq 305–587 MHz）、**WiFi 可用**（MAC 固定）、**KDE Plasma Mobile 开机直入**，
另有电量计 / 充电 / 快充驱动。全程只 `fastboot boot`，不写任何分区。

**一张镜像搞定，别再按功能分镜像：**

```sh
wsl -d umi -u root -- sh /mnt/d/project/UMI-mainline/scripts/mkimage.sh
# -> out/boot-umi.img

fastboot boot out\boot-umi.img
```

`scripts/mkimage.sh` = `build.sh`（编内核 + DTB）+ `pack-umi.py`（打包），
里面同时含面板 / 触摸 / GPU / WiFi / 电量计充电。`out/archive/` 里那些
`boot-umi-*.img` 是历史实验对照，平时不用管。

踩坑记录在 `docs/`：`BUILD.md`（构建与引导）、`DISPLAY.md`（面板/DSC/DSI）、
`TOUCH.md`（触摸，§12 boost 电源 / §13 fb-blank 死锁 / §14 厂商驱动）、
`GPU.md`（Adreno 650 + 固件/initramfs + fastfetch）、`WIFI.md`、`KDE.md`、
`BATTERY.md`、`TESTLOG.md`（每次上机的实测日志）、`DIAGNOSIS.md`、`HARDWARE.md`。
