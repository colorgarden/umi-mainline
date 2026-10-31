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

## 6. 当前卡点：hci0 没有 mgmt index

现象：

```
$ ls /sys/class/bluetooth/          → hci0
$ ls /sys/class/bluetooth/hci0/     → device power rfkill0 subsystem uevent
$ cat /sys/kernel/debug/bluetooth/hci0/   → 只有 ibs
$ btmgmt info                       → Index list with 0 items
$ bluetoothctl list                 → （空）
$ btmgmt --index 0 info             → Invalid Index
```

已经排除的：

| 猜想 | 证据 |
|------|------|
| 固件没加载 | `QCA setup on UART is completed`，debugfs 里有 `ibs` |
| 线程卡死 | 扫了全部 452 个线程的内核栈，没有一处在 hci/serdev/qca 代码里 |
| 命令超时/被拒 | `dmesg` 里 `Opcode … failed` / `tx timeout` 计数都是 **0** |
| 设备被 unregister | `rfkill0` 还在（`hci_unregister_dev` 会先撤 rfkill 再 `device_del`） |
| rfkill 挡住 | `rfkill list` → hci0 soft/hard 都是 no |

剩下的两条可能（二选一，需要插桩区分）：

1. `hci_dev_init_sync()` 里 `hci_init1_sync()`（Reset + `br_init1`）失败 —— 但**没有打日志**；
2. 判成 **unconfigured**（`HCI_QUIRK_EXTERNAL_CONFIG` / `INVALID_BDADDR`）→ 走
   `hci_unconf_init_sync()`，然后 mgmt 只发 *Unconfigured* Index Added，
   `READ_INDEX_LIST` 会跳过它（所以是 0 items）。

两条路的共同点：`hci_debugfs_create_basic()`（会建 `dut_mode`）都没跑过 —— 
而 `hci0/` 里确实没有 `dut_mode`，说明确实停在 init 早期。

### 6.1 插桩工具

```sh
# 打补丁（在 WSL）
wsl -d umi -u root -- python3 /mnt/d/project/UMI-mainline/patches/bt-debug-trace.py
# 构建 + 刷机后看
dmesg | grep umi-bt
# 定位完还原
wsl -d umi -u root -- python3 /mnt/d/project/UMI-mainline/patches/bt-debug-trace.py --revert
```

会打印：`setup ret=`、`unconf=`、`init1(ret=)`、`init2/3/4=`、`setup_sync=`、
`init_sync=`、`open_sync=`、`power_on open=`、`idx:`（含 bdaddr / rfkill / unconf 三个 flag）。

### 6.2 mgmt 探测工具

`tools/mgmt-probe.py`（推到手机上用 `python3` 跑）直接读
`READ_INDEX_LIST` / `READ_UNCONF_INDEX_LIST` / `READ_INFO(0)`，
用来判断「是没注册」还是「注册了但 unconfigured」。

> 注：`btmgmt` 的交互式命令（`unconf-index-list` 之类）在非 tty 下会挂住，
> 一调用就等着 stdin —— 别在脚本里用。

### 6.3 如果确认是 unconfigured

QCA6390 的 BD_ADDR 来自 NVM；如果 NVM 里是 `00:00:00:00:00:00`，
主线会让它「未配置」，需要用户态给地址：

```sh
btmgmt --index 0 public-addr AA:BB:CC:DD:EE:FF   # 控制器能看见之后
# 或者在 DT 里给：
bluetooth { local-bd-address = [..]; };          # 需要驱动置 HCI_QUIRK_USE_BDADDR_PROPERTY
```

6.12 的通用机制：`hci_dev_get_bd_addr_from_property()` 会读 `local-bd-address`，
但只有 `HCI_QUIRK_USE_BDADDR_PROPERTY` 置位的驱动才会走到 —— `hci_serdev` 不置，
所以要么打小补丁，要么用 `btmgmt public-addr` 一次性写入 NVM。
