# QCA6390 WiFi 调查记录（umi）

> 目标：让 mi10 的 WiFi 在主线内核下工作。
>
> 结论（2026-10-24）：**PCIe 控制器已经能起来，但 QCA6390 上不了电** ——
> 控制它上电/复位的两个 GPIO（20、21、79、81）全在 TLMM 的 **NORTH tile**，
> 这块在这台机器上一访问就 SError。**当前主线此路不通**，下面是完整证据。

---

## 1. 硬件是什么

下游 DT（`dump/downstream.dts`）写得很清楚：

```
qcom,cnss-qca6390@b0000000 {
	compatible = "qcom,cnss-qca6390";
	wlan-en-gpio = <0x65 0x14 0x00>;        /* &tlmm 20 */
	qcom,wlan-rc-num = <0x00>;              /* PCIe0 */
	...
}
```

- 芯片：**QCA6390**（Wi-Fi 6，a/b/g/n/ac/ax）
- 总线：**PCIe0**（`1c00000.pcie`），设备 ID `pci17cb,1101`
- 供电：板载 PMU（`qcom,qca6390-pmu`，10 路 LDO）
- 使能：`wlan-en` = **GPIO 20**
- 复位：`perst` = **GPIO 79**（`GPIO_ACTIVE_LOW`）

主线 `ath11k` 是支持的（`ath11k_pci.ko`，`CONFIG_ATH11K_PCI=m`），
固件 `ath11k/QCA6390/hw2.0/{amss.bin,m3.bin,bdwlan.bin,board-2.bin}`
Arch 的 linux-firmware 自带，**已经齐了**，不缺固件。

## 2. 做到哪一步了

设备树 `dts/sm8250-xiaomi-umi.dts`（唯一板级 DTS；`-wifi.dts` 已在 2026-11 合并进它）。

### 2.1 第一版：pinctrl-0 报 -EINVAL

```
sm8250-pinctrl f100000.pinctrl: error -EINVAL: pin-79 (1c00000.pcie)
qcom-pcie 1c00000.pcie: Error applying setting, reverse things back
```

`sm8250.dtsi` 的 `pcie0_default_state` 是 `pins = "gpio79"; function = "gpio"`，
`msm_pinmux_set_mux()` 的 `WARN_ON(i == g->nfuncs)` 分支被走到了。
先 `/delete-property/ pinctrl-0`。

### 2.2 第二版：probe failed -22

```
qcom-pcie 1c00000.pcie: probe with driver qcom-pcie failed with error -22
```

来源是 `pcie-qcom.c:qcom_pcie_probe()`：

```c
pcie->reset = devm_gpiod_get_optional(dev, "perst", GPIOD_OUT_HIGH);
if (IS_ERR(pcie->reset)) { ret = PTR_ERR(pcie->reset); ... }
```

而 `sm8250.dtsi` 给 pcie0 配了：

```dts
perst-gpios = <&tlmm 79 GPIO_ACTIVE_LOW>;
wake-gpios  = <&tlmm 81 GPIO_ACTIVE_HIGH>;
```

**79 / 81 都在 `gpio-reserved-ranges` 的 `<77 8>` 里**，`gpiod_get` 对保留引脚
返回 `-EINVAL`，probe 当场退出。

### 2.3 第三版：控制器起来了，但 link 不上

删掉 `perst-gpios` / `wake-gpios` 之后：

```
qcom-pcie 1c00000.pcie: host bridge /soc@0/pcie@1c00000 ranges:
qcom-pcie 1c00000.pcie:       IO 0x0060200000..0x00602fffff -> 0x0000000000
qcom-pcie 1c00000.pcie:      MEM 0x0060300000..0x0063ffffff -> 0x0060300000
qcom-pcie 1c00000.pcie: iATU: unroll T, 8 ob, 8 ib, align 4K, limit 1024G
qcom-pcie 1c00000.pcie: Phy link never came up          ← 关键
qcom-pcie 1c00000.pcie: PCI host bridge to bus 0000:00
pci 0000:00:00.0: [17cb:010b] type 01 class 0x060400 PCIe Root Port
pcieport 0000:00:00.0: PME: Signaling with IRQ 208
pcieport 0000:00:00.0: AER: enabled with IRQ 208
```

**控制器、iATU、Root Port 全部正常，只是链路上没有设备** ——
因为 QCA6390 根本没被使能（WLAN_EN 没拉高，PERST# 没释放）。

`/sys/bus/pci/devices/` 里只有 `0000:00:00.0`（自己），没有 `17cb:1101`。

## 3. 卡在哪：NORTH tile 的 GPIO 访问不了

要控制 QoS6390 上电，必须用 GPIO 20（WLAN_EN）和 79（PERST#）。
于是把这两个 pin 从 `gpio-reserved-ranges` 里单独放出来：

```dts
- gpio-reserved-ranges = <4 8>, <13 11>, <28 4>, <40 4>, <66 3>, <77 8>, <92 33>;
+ gpio-reserved-ranges = <4 8>, <13 7>, <21 3>, <28 4>, <40 4>, <66 3>, <77 2>, <80 5>, <92 33>;
```

并在 DTS 里加回 `perst-gpios` / `wlan-enable-gpios`。
**结果：手机直接起不来，ABL 回落 fastboot。**

> 这不是新现象。面板 reset 用的 **GPIO 12 是能读能写的**
> （实测 `val = 0x000002c3`，mux=0/OE=1/drive=3/pull-up），
> 但 **pin 28 一读就 synchronous external abort**。
> 所以 NORTH tile 不是整块坏、也不是整块好：**个别 pin 不可访问**，
> 而 20 / 79 恰好都在坏的那一堆里。

### 为什么不能「先探测一下再决定」

试过：用 `copy_from_kernel_nofault` 连读 68 个 NORTH 引脚做批量探测，
结果整机被看门狗复位 —— 那些访问产生的是 **SError（异步外部中止）**，
无法归属到某一条指令，`copy_from_kernel_nofault` 兜不住 → panic → WDT。

**教训：验证 NORTH 引脚只能一个一个来，而且每次失败都要按键重启。**

## 4. 还有什么路可以试（未验证）

1. **不通过 GPIO，用 PMIC 直接给 QCA6390 上电**
   下游用 10 路板载 LDO（`qca6390-pmu`）。如果这些 LDO 默认就开着、
   WLAN_EN 只是个 gate，也许可以绕过 GPIO。需要先确认
   `vreg_pmu_*` 在不开 wlan-en 的情况下是否真能输出电压。

2. **查 NORTH tile 的保护来源**
   SM8250 的 TLMM 分 west/south/north 三块（`0xf100000` / `0xf500000` / `0xf900000`）。
   north 的个别引脚可能是被 **XPU / TZ** 保护，也可能是 **interconnect 没打开**。
   值得对照下游 DT 里 `qcom,tlmm-gpio` 之类的配置。

3. **让 ABL 帮我们拉高 WLAN_EN**
   如果 bootloader 在某些条件下会打开 WiFi（比如 fastboot 的某个命令），
   可以在 `fastboot boot` 之前先让它使能。未验证。

4. **接受没有 WiFi**
   现在手机能：串口 console、USB 串口、RNDIS 网卡（Linux 侧 `usb0` 192.168.42.1
   已起来，Windows 侧驱动还差 MS OS Descriptor）。

## 5. 相关文件

| 文件 | 作用 |
|---|---|
| `dts/sm8250-xiaomi-umi-wifi.dts` | 基线树 + PCIe/QCA6390（当前是「控制器能起、link 不上」那一版） |
| `out/boot-umi-wifi4.img` | 上面这棵树 + 基线内核，`fastboot boot` 验证过 |
| `scripts/mk-dtb.sh` | 单独编一个 dtb（不重编内核） |
| `tools/pack-umi.py --dtb` | 换 dtb 打包 boot.img |

## 6. 实验流程备忘

调试期间比较高效的方式（不再需要反复按键）：

```sh
# 电脑上：dtb 190 KB -> gzip 36 KB -> base64 48 K 字符，串口约 5 秒
powershell -File tmp\send-dtb.ps1 -Chunk 400 -DelayMs 100

# 手机上：写进 boot 分区的 dtb 段（0xf2f000 = 15911152，512 字节对齐 = 31076）
dd if=/tmp/new.dtb of=/dev/sde50 bs=512 seek=31076 conv=notrunc
sync
dd if=/dev/sde50 bs=512 skip=31076 count=373 | head -c 190717 | md5sum
reboot
```

**注意**：dtb 段后面只剩 **202512 字节**，dtb 超过它就会踩到别的东西。
当前 dtb 190 KB，还有余量。

**关键前提**：`setsid`/`stty -echo -onlcr` 必须先关终端回显，
否则每发一个字符都被原样回显，带宽翻倍、控制台缓冲溢出，
传 24 KB 就卡死（实测过）。

## 7. 2026-10-24 第二轮：把能控的都控住了，卡仍然不出 link

第一轮的结论是「GPIO 20/79 不可访问」。这一轮把这些逐个证伪了：

### 7.1 找到了一个自己挖的坑：mk-dtb.sh 不同步 dtsi

改了 `sm8250-xiaomi-umi-common.dtsi` 的 `gpio-reserved-ranges`，编译出来的 dtb 里
却还是旧值。原因是 `tmp/mk-dtb.sh` 只把**主 .dts** 拷进内核树，
树里那份 `common.dtsi` 一直是旧的。现在会同步 common/panels/touch/dtbo-stubs 全部。

### 7.2 gpio 79（PERST#）可用

只把 79 从 `<77 8>` 里单独放出来（拆成 `<77 2>` + `<80 5>`），配上：

```dts
&pcie0 { perst-gpios = <&tlmm 79 GPIO_ACTIVE_LOW>; };
```

`probe failed -22` **消失**，控制器完整起来：

```
qcom-pcie 1c00000.pcie: iATU: unroll T, 8 ob, 8 ib, align 4K, limit 1024G
qcom-pcie 1c00000.pcie: PCI host bridge to bus 0000:00
pci 0000:00:00.0: [17cb:010b] PCIe Root Port
pcieport 0000:00:00.0: PME: Signaling with IRQ 208
```

debugfs 里也确认了：`gpio79 : out high func0 2mA pull down`。

### 7.3 gpio 20（WLAN_EN）也可用，而且真被拉高了

上游 `pwrseq-qcom-wcn` 用 `GPIOD_ASIS` 请求 wlan-enable —— **只请求不改电平**，
假设 bootloader 已经拉高。umi 的 ABL 没有。于是用 gpio-hog 强制拉高：

```dts
&tlmm {
	wlan_en_hog: wlan-en-hog {
		gpio-hog;
		gpios = <20 GPIO_ACTIVE_HIGH>;
		output-high;
	};
};
```

20 同样从 `<13 11>` 里单独放出（`<13 7>` + `<21 3>`）。
结果：`gpio20 : out high func0 2mA pull down`，系统正常没崩。

### 7.4 电源也确认全开

```
vreg_s6a_0p95 = enabled      vreg_s8c_1p35 = enabled
vreg_s5a_1p9  = enabled      vreg_s4a_1p8  = enabled
vreg_l5a_0p88 = enabled      vreg_l9a_1p2  = enabled
```

`pwrseq-qcom_wcn` 和 `pci-pwrctl-pwrseq` 都正确绑定
（后者挂在 `1c00000.pcie:pcie@0:wifi@0` 上）。

### 7.5 PERST 时序也没问题

主线的时序是够的：

```c
qcom_ep_reset_assert:   PERST=1, usleep_range(1000, 1500)
qcom_ep_reset_deassert: msleep(100), PERST=0, usleep_range(1000, 1500)
```

### 7.6 结果：还是 `Phy link never came up`

电源、使能、复位、时序全都满足了，卡依然不响应。所以剩下的唯一解释是
**QCA6390 自己的 PMU 还没有被初始化**。

下游 `cnss2` 驱动（`downstream-kernel/drivers/net/wireless/cnss2/`）的上电序列是：

```c
int cnss_power_on_device(struct cnss_plat_data *plat_priv)
{
	cnss_vreg_on_type(plat_priv, CNSS_VREG_PRIM);   /* 电源 */
	cnss_clk_on(plat_priv, &plat_priv->clk_list);   /* 时钟 */
	cnss_select_pinctrl_enable(plat_priv);          /* WLAN_EN */
	plat_priv->powered_on = true;
}
```

下游 DT 里还有几个主线没有的东西：

```
qcom,sw-ctrl-gpio = <&tlmm 124 0>;     /* 诊断用，打印电平 */
qcom,cmd_db_name = "smpf2";            /* RPMh 命令数据库资源 */
qcom,vdd-wlan-aon-config = <...>;      /* 每路轨的电压配置 */
```

**下一步**要么把 `cnss2` 的电源序列移植成一个小的 mainline 驱动，
要么接受这台机器的 WiFi 在主线内核上暂时做不到。

### 7.7 kexec 能换内核，换不了设备树

顺便试了 `kexec -l Image.gz --initrd=... --dtb=...`：内核加载成功、能启动，
但 `/proc/device-tree` 里还是旧设备树（`pcie status = disabled`）。
**`--dtb` 在 arm64 上不生效**，所以 WiFi 调试没法用 kexec 省按键，
每次换 dtb 还是得 `fastboot boot`。
（kexec 带 initrd 本身是好用的，以后调内核参数可以省一次重启。）

## 8. 第三轮：逐项对齐作者 dtb 后仍然不通，dtbo 也排除了

### 8.1 作者镜像里扒出来的真实情况

`Armbian-unofficial_26.11.0-trunk_Xiaomi-umi_...rootfs.img` 里：

- 内核 `7.2.7-current-sm8250`，**驱动全是主线原版**（ath11k_pci / pwrseq-qcom-wcn /
  pci-pwrctl-pwrseq），**没有任何自定义补丁**
- `lib/firmware/ath11k/QCA6390/hw2.0/` 固件齐全
- 他的 `sm8250-xiaomi-umi.dtb` 里：

```dts
pcie@1c00000 {
	perst-gpios = <&tlmm 79 GPIO_ACTIVE_LOW>;
	wake-gpios  = <&tlmm 81 GPIO_ACTIVE_HIGH>;
	pinctrl-0   = <&pcie0_default_state>;
	status = "okay";
};
qca6390-pmu {
	pinctrl-0 = <&bt_default_state>, <&wlan_default_state>;
	wlan-enable-gpios = <&tlmm 20 GPIO_ACTIVE_HIGH>;
	bt-enable-gpios   = <&tlmm 21 GPIO_ACTIVE_HIGH>;
};
gpio-reserved-ranges = <28 4>, <40 4>;     /* 只保留这两段，NORTH 全放 */
```

我们把这些**逐项照抄**（`wifi10`），结果依旧 `Phy link never came up`。

### 8.2 6.12 和 7.2 的 pinctrl 驱动没有可移植的差异

逐行 diff 过 `pinctrl-msm.c` / `pinctrl-msm.h` / `pinctrl-sm8250.c`：

- `struct msm_pinctrl` 两边都是 `void __iomem *regs[MAX_NR_TILES]`（6.12 就支持多 tile）
- `MSM_ACCESSOR` 宏两边一样，都走 `pctrl->regs[g->tile]`
- `msm_pinmux_set_mux()` 一字不差
- pin 20/28/79 的 `PINGROUP(..., NORTH, ...)` 定义完全相同

**所以「把 7.2 的修复移植回 6.12」这件事本身不成立 —— 没有那个修复。**

### 8.3 dtbo 分区也被排除了

猜过 ABL 会在 `fastboot boot` 时往 base dtb 上打 dtbo overlay，把我们的配置改掉。
实测运行时设备树：

```
/proc/device-tree/qca6390-pmu/wlan-enable-gpios = 00 00 00 54 00 00 00 14 00 00 00 00   (gpio20) ✓
/proc/device-tree/soc@0/pcie@1c00000/perst-gpios = ... 0x4f 0x01                       (gpio79) ✓
/proc/device-tree/soc@0/pcie@1c00000/status      = okay                                 ✓
/proc/device-tree/soc@0/pinctrl@f100000/gpio-reserved-ranges = <28 4> <40 4>            ✓
```

**和送进去的 dtb 完全一致**，overlay 没有动 WiFi 相关的任何节点。

### 8.4 最后把所有能查的都查了，全部正常

| 项目 | 实测值 |
|---|---|
| `gpio20` (WLAN_EN) | `out high func0 16mA` ✅ 真的拉高了（pwrseq power_on 干的） |
| `gpio79` (PERST#) | `out high` ✅ 复位已释放 |
| `gpio81` (WAKE) | `in high` ✅ |
| `gpio124` (SW_CTRL) | `in high` |
| `pcie_0_gdsc` | `on` ✅ |
| `vreg_l5a_0p88` / `vreg_l9a_1p2` | `enabled` users=4/3 ✅ |
| `gcc_pcie_wifi_clkref_en` | `1` (by `1c06000.phy` ref) ✅ |
| `gcc_pcie_phy_aux_clk` | `1` ✅ |
| `gcc_pcie0_phy_refgen_clk` | `1` @100 MHz ✅ |
| `gcc_pcie_0_pipe_clk` | `2` ✅ |
| PHY 驱动 | `qcom-qmp-pcie-phy` 已绑定 ✅ |
| PERST 时序 | assert 1 ms → hold 100 ms → release ✅ |

**电源域、六路 regulator、四个时钟、PHY、复位、使能，全部到位，QCA6390 仍然不参与 PCIe 链路训练。**

### 8.5 结论：卡在主线够不到的地方

主线这一侧已经没有可改的了。剩下的可能性都在驱动之外：

1. **RPMh / XPU 配置**：下游 DT 有 `qcom,cmd_db_name = "smpf2"`，
   `cnss2` 用它向 RPMh 查询资源并下发 sleep/wake 命令。主线没有这个机制，
   而 QCA6390 很可能需要 XPU 授权它才能被 PCIe 看到。
2. **硬件本身**：这颗 QCA6390 在 umi 上可能确实没工作（或者需要固件先跑起来）。
3. 作者那句「完全能跑」大概率指的是**系统**能跑，不一定包括 WiFi ——
   他的镜像里没有留下任何 WiFi 已连通的痕迹。

**当前状态**：Arch + 串口 + SSH + USB 网卡可用，WiFi 待续。

## 9. 第四轮：移植 7.2 的 LTSSM 诊断，找到时序死锁，但卡确实不在总线上

作者镜像里 `/etc/NetworkManager/system-connections/ZZzzx.nmconnection`
写着 `interface-name=wlp1s0` —— **他的 WiFi 是真用过的**，所以「主线做不到」这个
结论被我推翻，重新查。

### 9.1 从 v0 boot.img 里取出他真正的 dtb

他的 `boot.img` 是 **v0 格式**（`dtb_size = 0`），dtb 追在 gzip 流后面
（`Image.gz-dtb`）。用 `zlib.decompressobj().unused_data` 正好把 gzip 流和
尾部 dtb 分开：

```
kernel blob 17142916 B -> Image 58690048 B + tail 135434 B (F04DFEED = FDT)
```

拿到的 dtb 和我们照抄的配置**逐项一致**（`perst-gpios 79` / `wake-gpios 81` /
`pinctrl-0` / `wlan-enable-gpios 20` / `gpio-reserved-ranges = <28 4> <40 4>`），
所以 dtb 这条线没有差异可找了。

### 9.2 移植 7.2 的 LTSSM 读取（关键工具）

7.2 在 link 超时时会读 LTSSM 状态，这是判断「卡死没死」的唯一直接手段。
Qcom 的 ELBI 块把 LTSSM 放在 `ELBI_SYS_STTS[17:12]`：

```c
#define ELBI_SYS_STTS				0x08
#define ELBI_SYS_STTS_LTSSM_STATE_MASK		GENMASK(17, 12)
val = readl(pcie->elbi + ELBI_SYS_STTS);
```

6.12 的 `qcom_pcie` 里已经有 `elbi` 指针，所以只要加两个 define 和一次
`dev_info` 就行。补丁：`patches/pcie-qcom-ltssm-debug.py`。
（踩坑：注释里写了 `Config.*/L0`，`*/` 把注释提前闭合，报 `'L0' undeclared`。）

**探针位置很重要**：一开始放在 reset deassert 之后，读到的永远是
`Detect.Quiet` —— 因为那时训练还没开始。真正有意义的是
`dw_pcie_host_init()` 返回之后（训练已超时）那个值。
补丁：`patches/pcie-qcom-ltssm-after.py`。

### 9.3 发现时序死锁

LTSSM 第一次读数配合日志时间戳暴露了一个环：

```
41.48  LTSSM: state=0x0                     ← 训练时，卡沉默
42.47  Phy link never came up
42.55  pci 0000:00:00.0: Root Port          ← 枚举出来之后，wifi@0 才存在
       → pci-pwrctl-pwrseq 才 probe → pwrseq_power_on() 才拉高 WLAN_EN
```

`gpio20 : out high` 是真的，**但那是在 link training 失败之后**。
作者的 dtb 里 `wlan-default-state` 是 `output-low`，所以训练时它也是低的。

修法：用 `gpio-hog` 在 tlmm gpiochip 注册时就拉高（远早于 PCIe 探针）。
补丁：dts 里 `wlan_en_hog_early`。**但是——拉高之后 LTSSM 依然是 0x0**，
所以时序不是瓶颈。

### 9.4 PERST 后的等待从 1 ms 加到 120 ms

主线 `qcom_ep_reset_deassert()` 在释放 PERST 后只 `usleep_range(1000, 1500)`
就进训练，而 PCIe 规范 T_PVPERL 是「PERST 释放到参考时钟稳定」最多 100 ms。
补丁：`patches/pcie-qcom-perst-delay.py` 改成 `msleep(120)`。
**结果依旧是 0x0。**

### 9.5 最终实测（三重证据都指向同一件事）

```
[41.89] LTSSM: raw=0x00000001 state=0x0                  ← 训练开始前
[42.89] Phy link never came up                            ← 训练跑满 1 秒
[43.40] LTSSM after training: raw=0x00000001 state=0x0    ← 训练结束后仍是 Detect.Quiet
```

``` 
/sys/kernel/debug/pcie@1c00000/link_transition_count
  L0s transition count: 0
  L1  transition count: 0
  L1.1 transition count: 0
  L1.2 transition count: 0
  L2  transition count: 0
```

同时确认这些**全部正常**：

```
gpio20  : out high 16mA          (WLAN_EN，hog 提前拉高)
gpio79  : out high               (PERST 已释放)
pcie_0_gdsc : on
gcc_pcie_wifi_clkref_en  : 1     (by 1c06000.phy ref)
gcc_pcie_phy_aux_clk     : 1
gcc_pcie0_phy_refgen_clk : 1 @100 MHz
gcc_pcie_0_pipe_clk      : 2
vreg_l5a_0p88 / vreg_l9a_1p2 : enabled
qcom-qmp-pcie-phy        : 已绑定
```

**LTSSM = Detect.Quiet 意味着：链路训练跑满一秒，总线上始终没有任何设备在应答。**

### 9.6 结论

软件侧已经穷尽：电源域、六路 regulator、四个时钟、PHY 驱动、RESET 时序、
WLAN_EN 时序全部到位且用 debugfs 逐个核实过。卡依旧不出现。

剩下只有三种可能，都不是改代码能解决的：

1. **REFCLK 没有真正到达卡**（PHY 的参考时钟输出是硬件路径，主线没有可关/可开的开关）
2. **这颗 QCA6390 在本机确实不工作**（作者那台能用，不排除批次/个体差异）
3. **XPU/TZ 层面把 PCIe 端点挡在外面**

**当前状态**：Arch + 串口 + SSH + USB 网卡可用，WiFi 判为硬件/固件层面受限。
所有诊断工具（LTSSM 探针、PERST 延时补丁）都保留在仓库里，
换机器或换固件后可以直接复测。

## 10. 第五轮：结论推翻了 —— pwrseq 自己挂了，hog 是元凶

第 9 节的结论（硬件/固件层面受限）**是错的**，收回。真正的线索来自一条
一直被忽略的日志：

```
[17.009900] pwrseq-qcom_wcn qca6390-pmu: error -EBUSY: Failed to get the WLAN enable GPIO
[17.091671] pwrseq-qcom_wcn qca6390-pmu: probe with driver pwrseq-qcom_wcn failed with error -16
```

### 10.1 为什么 -EBUSY：hog 和白名单冲突

`drivers/power/sequencing/pwrseq-qcom-wcn.c` 的 probe：

```c
ctx->wlan_gpio = devm_gpiod_get_optional(dev, "wlan-enable", GPIOD_ASIS);
if (IS_ERR(ctx->wlan_gpio))
        return dev_err_probe(dev, PTR_ERR(ctx->wlan_gpio),
                             "Failed to get the WLAN enable GPIO\n");
```

**gpio-hog 是独占的**：`wlan_en_hog_early` 在 tlmm gpiochip 注册时就把 gpio20
锁了，之后任何 consumer 去 request 这条线都会拿到 `-EBUSY`。

于是形成第二个环，而且是**第 9 节所有实验的共同前提被破坏**：

```
hog 占住 gpio20
  → pwrseq_qcom_wcn probe 失败 (-EBUSY)
  → pwrseq 设备根本不存在
  → devm_pwrseq_get() 永远拿不到它
  → pwrseq_power_on() 永远不会执行：8 路 regulator 一次都没使能
  → 卡的 vddio/vddaon/vddpmu/vddrfa*/vddpcie* 全是关的
  → 卡当然不在总线上，LTSSM 当然 Detect.Quiet
```

也就是说第 9 节里「六路 regulator 全就绪」的核实**只看了 PMIC 那几路**
（`vreg_l5a_0p88` / `vreg_l9a_1p2`），PMU 的 8 路根本没查 —— 它们确实没开。

### 10.2 7.2 到底不一样在哪

`pwrseq_qcom_wcn_match()` 要求 consumer 的 `vddaon-supply` 指向的 regulator，
其 parent 必须是 PMU 节点本身：

```c
if (!reg_node->parent || !reg_node->parent->parent ||
    reg_node->parent->parent != ctx->of_node)
        return 0;
```

- `qca6390-pmu` 自己的 `vddaon-supply = <&vreg_s6a_0p95>` → parent 是 PMIC ❌
- `wifi@0` 的 `vddaon-supply = <&vreg_pmu_aon_0p59>` → parent 是 PMU ✅

所以 consumer 只能用 `wifi@0`，而 `wifi@0` 是 `of_pci` 扫总线后才建出来的。
7.2 用新的 `pci_pwrctrl` 框架在 **PERST# 释放之前** 调
`pci_pwrctrl_power_on_devices()` 把这一步提前了；6.12 只有旧的 `pci_pwrctl`，
它绑的就是 `wifi@0`，必须等枚举 —— 死锁。

最小等价实现：`patches/pcie-qcom-early-poweron2.py` 在 `qcom_pcie_host_init()`
里 `of_platform_device_create(wifi_np)` + `devm_pwrseq_get(&wdev->dev, "wlan")`
+ `pwrseq_power_on()`，位置就在 `qcom_ep_reset_deassert()` 之前。

**踩的两个坑**：

1. `of_get_child_by_name()` 比的是 `np->name`，**不含 unit address** ——
   必须传 `"pcie"` / `"wifi"`，传 `"pcie@0"` / `"wifi@0"` 永远返回 NULL
   （日志：`early power-on: no wifi@0 node`）。补丁 `patches/fix-node-names.py`。
2. consumer 不能用 `qca6390-pmu`，否则 `devm_pwrseq_get()` 返回 `-EPROBE_DEFER`
   （日志：`early power-on: pwrseq unavailable (-517)`）。

### 10.3 本轮的改动

- **DTS 删掉 `wlan_en_hog_early`**：所有权交回 pwrseq，由 early power-on 在
  PERST 之前拉高。gpio20 的 pinmux（`wlan_default_state`，output-low）保留。
- `patches/pcie-qcom-early-poweron2.py` + `patches/fix-node-names.py` 进内核。
- `CONFIG_POWER_SEQUENCING=y`、`CONFIG_POWER_SEQUENCING_QCOM_WCN=y`（原来 `=m`
  导致 `undefined reference to devm_pwrseq_get`）。
- `patches/revert-pcie-refclk.py`：REFCLK 相关的实验全部回退，7.2 从没碰过那个寄存器。

### 10.4 附带发现：rootfs 里有重复的 pwrseq_core.ko

```
[43.017830] pwrseq_core: exports duplicate symbol devm_pwrseq_device_register (owned by kernel)
```

`pwrseq_core` 现在是 `=y` 编进内核的，rootfs 里还留着早先 `=m` 时代装进去的
`pwrseq_core.ko`，modprobe 时撞名。无害但要在手机上清掉：

```sh
find /lib/modules/$(uname -r) -name 'pwrseq*core*.ko*' -delete
depmod -a
```

## 11. 第六轮：WiFi 通了 —— 根因是 PM8009 SMPS2 没供电

### 11.1 一句话

**`vddpmu` / `vddrfa0p95` 接错了 PMIC 轨。** 它们在这台机器上是
**PM8009 SMPS2**（0.95V，WiFi PMU 的 digital 域），我们却接到了 PM8150 S6A
（AON）。于是 PM8009 S2 一个 consumer 都没有，一直是关着的：

```
$ grep s2f /sys/kernel/debug/regulator/regulator_summary
       vreg_s2f_0p5     0 users   512mV      ← 关着，而且只有 512mV
       vreg_bob         1 users  3352mV
       vreg_s4a_1p8     3 users  1800mV
       vreg_s6a_0p95    4 users   952mV
```

PMU 的数字域完全没电 → QCA6390 在 PCIe 上是"死的" → LTSSM 永远
Detect.Quiet。第 9 节"硬件受限"的结论是错的，第 10 节解决的是另一个真实问题
（hog/pwrseq），但两个都不是最后一层。

### 11.2 怎么找到的

对照三份 DT，只有下游 DT 写明了板级真实接线：

| cnss 供应（下游 `qcom,cnss-qca6390`） | 实际 rail（`dump/downstream.dts`） |
|---|---|
| `vdd-wlan-aon` 0.95V | `pm8150_s6` |
| **`vdd-wlan-dig` 0.95V** | **`pm8009_s2`** |
| `vdd-wlan-io` 1.8V | `pm8150_s4` |
| `vdd-wlan-rfa1` 1.9V | `pm8150_s5` |
| `vdd-wlan-rfa2` 1.35V | `pm8150a_s8` |

作者的 7.2 dtb 也是这么接的（`vddaon = vreg_s6a_0p95`、`vddpmu =
vddrfa0p95 = vreg_s2f_0p95`、`vddrfa1p3 = vreg_s8c_1p3`、`vddrfa1p9 =
vreg_s5a_1p9`、`vddio = vreg_s4a_1p8`），只是我们抄的时候把 vddpmu 写成了 S6A。

顺带排除了两个假线索：`refgen`（0x088e7000）是**显示 DSI** 的 reference
generator，不是 PCIe 的；7.2 的 `pwrseq-qcom-wcn` 对 qca6390 也没有实质变化。

### 11.3 修法

`dts/sm8250-xiaomi-umi-common.dtsi` 的 `regulators-2`（PM8009）：

```dts
		vreg_s2f_0p5: vreg_s2f_0p95: smps2 {
			regulator-name = "vreg_s2f_0p95";
			regulator-min-microvolt = <900000>;
			regulator-max-microvolt = <952000>;
			regulator-initial-mode = <RPMH_REGULATOR_MODE_AUTO>;
		};
```

`dts/sm8250-xiaomi-umi-wifi.dts`：

```dts
		vddaon-supply      = <&vreg_s6a_0p95>;
		vddpmu-supply      = <&vreg_s2f_0p95>;
		vddrfa0p95-supply  = <&vreg_s2f_0p95>;
```

**坑**：`min == max` 会让 regulator 注册时去读当前电压，RPM 回
`-ENOTRECOVERABLE(-131)`，整个 `regulators-2` probe 失败（连带 pwrseq 拿不到
supplier，`early power-on: pwrseq -517`）。必须像作者一样给一个区间
（900000–952000）+ `RPMH_REGULATOR_MODE_AUTO`。

### 11.4 结果

```
[42.319] pci 0000:01:00.0: 4.000 Gb/s available PCIe bandwidth, limited by 5.0 GT/s PCIe x1 link
[42.732] qcom-pcie 1c00000.pcie: LTSSM after training: raw=0x00011401 state=0x11   ← L0
[42.865] ath11k_pci 0000:01:00.0: Adding to iommu group 10
[42.931] ath11k_pci 0000:01:00.0: qca6390 hw2.0
[43.387] ath11k_pci 0000:01:00.0: fw_version 0x10121492 fw_build_timestamp 2021-11-04
[43.612] ath11k_pci 0000:01:00.0 wlp1s0: renamed from wlan0
```

```
$ ip -br link
lo      UNKNOWN  00:00:00:00:00:00
usb0    UP       02:1d:6b:01:04:01    ← USB 网卡照旧
wlp1s0  DOWN     00:03:7f:12:e7:e7    ← WiFi 接口
```

`usb0`（RNDIS）和串口控制台都没有受影响，符合"保留 USB 网卡"的要求。

### 11.5 还差什么

- `wlp1s0` 还是 DOWN：rootfs 里没有 `iw` / `wpa_supplicant` / `iwd` /
  NetworkManager，只有 `dhcpcd`。
- 没有 `/lib/firmware/regulatory.db`（`cfg80211: failed to load regulatory.db`），
  需要 `wireless-regdb`；缺它时按 world regdomain 走，5 GHz 会受限。

## 12. 第七轮：真的连上网了（iwd + 内核 crypto）

### 12.1 为什么最后选了 iwd，又为什么先改内核

先用 `wpa_supplicant`：它自己带 openssl，理论上不依赖内核 crypto，但
Arch 的 `wpa_supplicant` 包硬依赖 `pcsclite` → `polkit` → `duktape` 一整条链，
而 `pcsclite` 的 `libpcsclite.so.1` 又必须在运行期解析到 `libpolkit-gobject-1.so.0`。

`iwd` 只要 `iwd + ell` 两个包，但它启动时会逐个检查内核配置，缺一个就
`status=1` 退出：

```
CONFIG_KEY_DH_OPERATIONS is not set
CONFIG_CRYPTO_{ECB,MD5,CBC,SHA256,AES,DES,CMAC,HMAC,SHA512,SHA1} / CONFIG_CRYPTO_USER_API*
```

这些默认大多是 `=m`，rootfs 里又没装 crypto 模块。**正解是把它们编进内核**
（比往 rootfs 里塞模块、或者装一整条 polkit 链都干净）：

```
CONFIG_KEY_DH_OPERATIONS=y
CONFIG_CRYPTO_DH=y
CONFIG_CRYPTO_DES=y
CONFIG_CRYPTO_CBC=y
CONFIG_CRYPTO_CMAC=y
CONFIG_CRYPTO_MD5=y
CONFIG_CRYPTO_USER_API=y
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_CRYPTO_USER_API_SKCIPHER=y
CONFIG_CRYPTO_USER_API_AEAD=y
CONFIG_CRYPTO_USER_API_RNG=y
```

（`CONFIG_CRYPTO_AES/ECB/HMAC/SHA1/SHA256/SHA512` 本来就是 `=y`，只补缺的。）

### 12.2 联网步骤

```sh
# 包：iwd + ell（外加 iw / wireless-regdb）
pacman -U --noconfirm --disable-sandbox ell-*.pkg.tar.xz iwd-*.pkg.tar.xz

printf '[General]\nEnableNetworkConfiguration=true\n\n[Network]\nNameResolvingService=systemd\n' \
	> /etc/iwd/main.conf

systemctl enable --now iwd
iwctl station wlan0 connect 'SSID' --passphrase 'PASS'
```

`EnableNetworkConfiguration=true` 让 iwd 自己跑内置 DHCP，地址/路由/ DNS
都自动下来，不用再拉 `dhcpcd`。

### 12.3 结果

```
iwctl station wlan0 show
    State                 connected
    Connected network     HUAWEI-SVTYH4_5G
    IPv4 address          192.168.3.169

ip route
    default via 192.168.3.1 dev wlan0 proto dhcp src 192.168.3.169 metric 304
    192.168.3.0/24 dev wlan0 proto dhcp scope link
    192.168.42.0/24 dev usb0 proto kernel scope link src 192.168.42.1   ← USB 网卡还在

ping 1.1.1.1 → 0% packet loss
```

然后 `pacman -Sy fastfetch` 直接从仓库装上了（之前卡死的 `yyjson` 依赖这次
由 pacman 正常解析成 `yyjson-0.13.0-1`）。

### 12.4 踩坑记录

- **接口名不固定**：某次启动叫 `wlp1s0`，某次叫 `wlan0`。用之前先
  `iwctl device list` 看实际名字，别写死。
- **pacman 密钥环是空的**：直接装包报
  `error: keyring is not writable / required key missing`。
  先 `pacman-key --init && pacman-key --populate archlinuxarm`（需要 `gnupg`，
  rootfs 里有）。
- `pacman` 在这个内核上仍然要 `--disable-sandbox`（Landlock 没开）。
- 凭据只存在 `/var/lib/iwd/<ssid>.psk`（root 可读），没有写进仓库。




## 13. 固定 MAC（路由器绑定规则要用）

不打 local-mac-address 时，QCA6390 的固件**每次开机现生成一个 MAC**
（实测  0:03:7f:12: 后面依次是 e7:e7 / 89:89 / 19:19 / 5:a5 /
9c:9c），路由器的转发/MAC 绑定规则就没法用。

注意 systemd 的 .link 里写 MACAddress= **不管用** —— 驱动在 udev 打完
add 事件之后才把固件的 MAC 写进 netdev，会把 udev 设的值盖掉（实测

etworkctl 显示 Link File 已生效，但 ip link 里还是固件那个）。

正确做法是在 DT 里给 wifi@0 加属性：

`dts
&pcieport0 {
	wifi@0 {
		local-mac-address = [00 03 7f 12 a4 a4];
	};
};
`

th11k_mac_register() 里有 device_get_mac_address(ab->dev, mac_addr)，
只要属性存在就优先用；QCA6390 是单 radio，b->pdevs_macaddr_valid 永远
alse（那一支要求 
um_radios > 1），所以 DT 的值一定生效。

验证：连着重启两次，ip link show wlan0 都是同一个 MAC。

## 14. 合并镜像：显示 + 触摸 + GPU + WiFi 一条镜像（2026-10）

之前 WiFi 只能用 `sm8250-xiaomi-umi-wifi.dts` 单独跑（主 DTS 没开 PCIe，
`build.sh` 也不编它），而 GPU/触摸在主 DTS 上，两边没法同时存在。现在合了：

1. `dts/sm8250-xiaomi-umi-wifi.dts` 补上 GPU 段（`&gmu` / `&gpu`，和主 DTS
   完全一样；boost 电源、触摸、面板都来自 `common.dtsi`，不用重复）。
2. `scripts/build.sh`：
   - 同步列表加 `sm8250-xiaomi-umi-wifi.dts`
   - DTB 循环加 `sm8250-xiaomi-umi-wifi`（顺带拿到 `-@` 编出的 `__symbols__`，
     ABL 的 dtbo overlay 要用）
   - 产物收集时一并拷 `out/sm8250-xiaomi-umi-wifi.dtb`
3. 打包时指定这份 DTB：

```sh
python tools/pack-umi.py --dtb out/sm8250-xiaomi-umi.dtb --name all1
fastboot boot out/boot-umi-all1.img
```

实测（`all1`，6.12.94，约 18 s 起 SSH）：

```
wlan0: <...UP,LOWER_UP> ... link/ether 00:03:7f:12:a4:a4
iwctl: State connected / HUAWEI-SVTYH4_5G / IPv4 192.168.3.175   <- 固定 MAC 生效
0000:01:00.0 ath11k_pci: qca6390 hw2.0, fw_version 0x10121492
gpu: gpu-initialized: 1, revision: 650 (6.5.0.2), devfreq 空闲 305 MHz
touch: MS_RAW spread 15688（真实帧），vdd_boost_reg=enabled
```

两点注意：

- `pcie0` 的 `perst-gpios`(79) / `pinctrl-0` / `wake-gpios`(81) 必须留着，
  所以 `&tlmm` 的 `gpio-reserved-ranges` 要按 wifi.dts 那份放开
  （`<28 4>, <40 4>`）。主 DTS 那份保留 NORTH，**不能拿主 DTS 打 WiFi**。
- `pcie-qcom` 的 early power-on 补丁已经在树里（
  `grep pwrseq drivers/pci/controller/dwc/pcie-qcom.c` 应有 10 处命中）：
  它在释放 PERST# 之前调 `pwrseq_power_on()`，否则 WLAN_EN 永远是低。

## 15. Wi-Fi 6（802.11ax）支持情况

**芯片和驱动都支持 Wi-Fi 6。** QCA6390 本身就是 11ax 芯片（`docs/WIFI.md` §1
里写的 "a/b/g/n/ac/ax"），主线的 `ath11k_pci` 也是 QCOM 11ax 家族驱动，不是
11ac 的 `ath10k`：

```
ath11k_pci 0000:01:00.0: qca6390 hw2.0
ath11k_pci 0000:01:00.0: fw_version 0x10121492 ...
```

能力边界（QCA6390 这颗芯片本身的上限，不是驱动限制）：

| 项目 | QCA6390 |
|---|---|
| 标准 | 802.11a/b/g/n/**ac**/**ax**（HE） |
| 频段 | 2.4 / 5 GHz（**没有 6 GHz**，所以不是 Wi-Fi 6E） |
| 空间流 | 2×2（MU-MIMO/OFDMA 支持，随 AP） |
| 带宽 | 20/40/**80** MHz（**没有 160 MHz**） |
| 最高 PHY | HE80 2SS MCS11 ≈ **1201 Mbps**（实测一般 600–900） |
| 协议开销 | 需 AP 也广播 HE；连 11ac AP 时自然退回 VHT |

### 15.1 怎么确认当前真的跑在 11ax

```sh
# 1) 驱动/固件
dmesg | grep -i ath11k | head
iw list | grep -A8 "HE Iftypes"          # 有 “HE Iftypes: managed” 就说明支持 HE

# 2) 当前连接协商成什么
iw dev wlan0 link                        # rx/tx bitrate；11ax 会带 HE-MCS
iw dev wlan0 station dump | grep -i -e bitrate -e "rx he" -e "tx he"

# 3) AP 有没有 HE（关键：AP 不支持就只能跑 ac）
iw dev wlan0 scan | grep -A25 "SSID: <你的AP>" | grep -i -e he -e vht -e ht
```

### 15.2 想要速度的几个注意点

- **关省电**：`iw dev wlan0 set power_save off`
  （NM 里持久化：`nmcli connection modify <名字> wifi.powersave 2`），
  省电模式会把吞吐砍得很厉害。
- **5 GHz + 80 MHz**：我们默认连的是 `HUAWEI-SVTYH4_5G`，如果它能给 80 MHz，
  链路理论上限就是 1201 Mbps 那一档。
- **PCIe 链路**：QCA6390 挂在 PCIe0 上，灌满 1.2 Gbps 需要链路至少稳在 Gen2 x1；
  `dmesg | grep -i ltssm` 能看到 `state=0x11`，那是正常训练完成。
- **测速**：`pacman -S iperf3` 之后 `iperf3 -c <另一台> -t 30 -P 4`。
