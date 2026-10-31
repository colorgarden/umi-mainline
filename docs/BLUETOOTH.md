# Bluetooth（QCA6390，走 uart6）

> 状态（2026-11-01）：
> **固件已经能加载、QCA setup 也走完了**，但 `hci0` 依然没有 mgmt index
> （`bluetoothctl list` 空、`btmgmt info` → "Index list with 0 items"）。见 §6。

## 1. 硬件与链路

```
QCA6390 ── UART6 (geniqup@9c0000 / qupv3_id_1 / serial@998000) ──> hci_uart_qca ──> hci0
        └─ PCIe0 ──> ath11k（WiFi，走同一个 PMU：qca6390-pmu）
```

- UART 波特率：115200 起步，setup 里切到 **3 Mbps**（DT `max-speed = <3200000>`）。
- 电源：`qca6390-pmu`（pwrseq-qcom-wcn）负责 `wlan-enable-gpios = <&tlmm 20>` /
  `bt-enable-gpios = <&tlmm 21>`；**BT 起来时 `gpio21` 必须是 out high**。
- `bt` 节点的 6 条 supply **不是给驱动用的**（`hci_qca` 对 QCA6390 `num_vregs = 0`），
  而是让 `pwrseq_qcom_wcn_match()` 认出这个 consumer —— 它要求 consumer 的
  `vddaon-supply` 解析到「父节点就是 PMU」的那个 regulator。认下来才会
  `pwrseq_power_on()` → 拉高 BT_EN。

## 2. 设备树（`dts/sm8250-xiaomi-umi-common.dtsi`）

```dts
aliases { serial1 = &uart6; };        /* ★ 必须有，见 2.1 */

&uart6 {
	status = "okay";
	bluetooth {
		compatible = "qcom,qca6390-bt";
		vddrfacmn-supply = <&vreg_pmu_rfa_cmn>;
		vddaon-supply    = <&vreg_pmu_aon_0p59>;
		vddbtcmx-supply  = <&vreg_pmu_btcmx_0p85>;
		vddrfa0p8-supply = <&vreg_pmu_rfa_0p8>;
		vddrfa1p2-supply = <&vreg_pmu_rfa_1p2>;
		vddrfa1p7-supply = <&vreg_pmu_rfa_1p7>;
		max-speed = <3200000>;
		firmware-name = "htnv20.bin";     /* ★ 只写裸文件名，见 §3 */
	};
};
```

### 2.1 三颗连环雷

1. **`serial1` alias 缺失** → `qcom_geni_serial 998000.serial: Invalid line -19`，
   serdev 绑不上，`bluetooth` 子节点根本不存在。
2. 更阴的是：没绑上的 uart6 会让 qnoc/interconnect 的 `sync_state()` 一直 pending，
   把 consumer 当 `pcie0` 的东西全拖住 → **表现是「蓝牙没起来，WiFi 也没了」**。
3. `qca6390-pmu` 必须和 `wlan-enable-gpios`/`bt-enable-gpios` 在同一份 DTB 里。
   这就是曾经把「只有 common.dtsi 的 umi.dtb」刷进去就 WiFi/电池/蓝牙全灭的原因
   （见 `dts/sm8250-xiaomi-umi.dts` 顶部的合并说明）。

## 3. 固件命名（最容易踩）

`hci_qca` 的行为：

| 文件 | 谁决定名字 |
|------|-----------|
| patchram | 驱动按 **ROM 版本**自己拼：ROM `0x200` → `qca/htbtfw20.tlv` |
| NVM | DT `firmware-name`，**会再前缀一个 `qca/`**，并且还会试「去掉扩展名 + .bin」 |

所以：

- DT 只能写 **裸文件名** `htnv20.bin` → 最终落到 `qca/htnv20.bin`。
  写 `qca/hnv20.bin` 会变成 `qca/qca/hnv20.bin`（`-2`）。
- 用 `hpbtfw21.tlv` / `hpnv21.bin` 会 `Failed to send TLV segment (-104)` 或
  `-110 tx timeout` —— 那是别的 QCA 型号的固件。
- Arch 的 `linux-firmware` **没有** `qca/htbtfw20.tlv`（只有 `hnv20.bin`），
  我们已经把它放进仓库 `firmware/qca/htbtfw20.tlv`（210704 B，来自
  `https://git.kernel.org/…/linux-firmware.git/plain/qca/htbtfw20.tlv`）。

### 3.1 固件放哪儿

- **rootfs** `/lib/firmware/qca/`：手工 rebind 一定成功。
- **initramfs** `/lib/firmware/qca/`：boot 阶段的 serdev probe 发生在切根之前，
  只有 initramfs 里有才加载得到（`scripts/mkinitramfs.sh` 已加这一段）。
- 内核**不跟随符号链接**（5.19 起），必须是真文件。

## 4. 内核配置

```
CONFIG_RFKILL=y          # ★ 没有它 CONFIG_BT=y 会被静默降级成 =m
CONFIG_BT=y
CONFIG_BT_HCIUART=y
CONFIG_BT_HCIUART_SERDEV=y
CONFIG_BT_HCIUART_H4=y
CONFIG_BT_HCIUART_QCA=y
CONFIG_BT_QCA=y
```

`scripts/build.sh` 的 FORCEY 段里已经强制写死这些。
`CONFIG_BT=y` 一旦成立，rootfs 里旧的 `rfkill.ko`/`hci_uart.ko` 会和新内核冲突
（`exports duplicate symbol`），**必须同步模块树**（`out/modroot` + `tools/push-modules.sh` + `depmod`）。

## 5. 已经验证成功的一半

```
Bluetooth: hci0: setting up ROME/QCA6390
Bluetooth: hci0: QCA Product ID   :0x00000010
Bluetooth: hci0: QCA SOC Version  :0x400a0200
Bluetooth: hci0: QCA ROM Version  :0x00000200      ← ROM 0x200 → htbtfw20.tlv
Bluetooth: hci0: QCA Patch Version:0x00000d2b
Bluetooth: hci0: QCA Downloading qca/htbtfw20.tlv
Bluetooth: hci0: QCA Downloading qca/htnv20.bin
Bluetooth: hci0: QCA setup on UART is completed    ← btqca.c 的最后一行，ret=0
```

`/sys/kernel/debug/bluetooth/hci0/ibs` 存在 ⇒ `qca_debugfs_init()` 跑过 ⇒ **setup 返回 0**。

## 6. 曾经的卡点（已解决）：hci0 没有 mgmt index

> **根因：控制器没有可用 BD_ADDR，内核把它当成「未配置控制器」。**
> 修法：DT 的 `bluetooth` 节点里加 `local-bd-address`（小端）。
> 现在用的是 `[cc 3d 78 9d d7 a6]` = `a6:d7:9d:78:3d:cc`。

### 6.1 当时的现象

```
$ ls /sys/class/bluetooth/          → hci0
$ cat /sys/kernel/debug/bluetooth/hci0/   → 只有 ibs（没有 dut_mode）
$ btmgmt info                       → Index list with 0 items
$ bluetoothctl list                 → （空）
```

### 6.2 查证过程（留着，下次遇到类似问题照抄）

1. **先排除"卡死"**：扫了全部线程的内核栈，没有一处在 hci/serdev/qca 里
   （`/proc/*/task/*/stack` 里 grep hci|serdev|qca）。
2. **再排除"命令失败"**：`dmesg` 里 `Opcode … failed` / `tx timeout` 都是 0。
3. **插桩**（`patches/bt-debug-trace.py`）打出关键事实：

```
[umi-bt] hci0 setup ret=0
[umi-bt] hci0 unconf=1 ext_cfg=0                      ← 就是这里
[umi-bt] hci0 open_sync=0 up=1 setup=1 unconf=1 bdaddr=ad:5a:00:00:00:00
[umi-bt] hci0 power_on open=0
```

`unconf=1` 说明内核走了 `hci_dev_setup_sync()` 里「未配置」那条：

```c
invalid_bdaddr = test_bit(HCI_QUIRK_INVALID_BDADDR) || test_bit(HCI_QUIRK_USE_BDADDR_PROPERTY);
if (!ret) {
	if (USE_BDADDR_PROPERTY && public_addr == ANY) hci_dev_get_bd_addr_from_property();  /* 读 DT */
	if (invalid_bdaddr && public_addr != ANY && hdev->set_bdaddr) { ret = set_bdaddr(); ... }
}
if (EXTERNAL_CONFIG || invalid_bdaddr) set HCI_UNCONFIGURED;
if (HCI_UNCONFIGURED) return hci_unconf_init_sync(hdev);   /* 只读版本号，不建 debugfs */
```

而未配置控制器在 mgmt 里只发 **Unconfigured Index Added**，
`READ_INDEX_LIST` 会直接跳过它 → `bluetoothctl` 永远看不到。

### 6.3 为什么 quirk 会被置上

`btqca.c: qca_check_bdaddr()`：

```c
if (bacmp(&hdev->public_addr, BDADDR_ANY))   return 0;   /* DT 给了就直接跳过 */
... 读 HCI_OP_READ_BD_ADDR ...
if (!bacmp(&bda->bdaddr, &config->bdaddr))               /* 控制器地址 == NVM 里的地址 */
	set_bit(HCI_QUIRK_USE_BDADDR_PROPERTY, &hdev->quirks);
```

本机 NVM（`htnv20.bin`）里没有出厂地址，控制器报回来的是
`ad:5a:00:00:00:00`（`%pM` 序，打印成 `00:00:00:00:5a:ad`），
和 NVM 里的一致 → 驱动认定「等设备树或用户态来给」。

### 6.4 修法与字节序

```dts
&uart6 {
	bluetooth {
		...
		local-bd-address = [cc 3d 78 9d d7 a6];   /* = a6:d7:9d:78:3d:cc */
	};
};
```

`Documentation/devicetree/bindings/net/bluetooth/bluetooth-controller.yaml` 写得很清楚：
**小端、最低有效字节在前** —— 要 `00:11:22:33:44:55` 就得写 `[55 44 33 22 11 00]`。
写反了蓝牙地址会变成镜像倒序（`cc:3d:...` ↔ `a6:d7:...`）。

### 6.5 修好之后

```
[umi-bt] hci0 unconf=0
[umi-bt] hci0 init1(ret=0) init2=0 init3=0 init4=0
btmgmt info → Index list with 1 item
bluetoothctl list → Controller A6:D7:9D:78:3D:CC umi [default]
bluetoothctl power on → succeeded
```

> 注意：`ad:5a:00:00:00:00` 这种半零地址说明 NVM 是"干净"的（`htnv20.bin` 只是默认配置）。
> 想要手机原厂 BD_ADDR，得从原厂的 `bt_nv`/`MODEMST` 分区里取，
> 对功能没影响，只是配对记录跟旧系统不通用。

## 7. 复现步骤（当前最终状态）

```sh
# 固件（rootfs 与 initramfs 都要）
scp firmware/qca/htbtfw20.tlv firmware/qca/htnv20.bin root@PHONE:/lib/firmware/qca/

# 模块树（只要重编过内核就同步）
out/modroot/lib/modules/6.12.94-umi-dirty/kernel  → /lib/modules/6.12.94-umi-dirty/
depmod -a 6.12.94-umi-dirty

# 验证
dmesg | grep -iE 'QCA Downloading|setup on UART'
btmgmt info                       # 期望 Index list with 1 item
bluetoothctl show                 # 期望 Controller … umi
systemctl enable --now bluetooth
```
