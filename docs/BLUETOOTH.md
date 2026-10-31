# Bluetooth（QCA6390，走 uart6）

> 状态（2026-11-01）：**链路已全部打通，卡在最后一步（固件名/模块同步）**。
> 这里记下已经验证的事实，避免再从头摸一遍。

## 1. 硬件与链路

```
QCA6390（和 WiFi 同一颗） ──UART6(ttyHS1, 0x998000)──> AP
                          ├─ WLAN_EN  gpio20 ┐
                          ├─ BT_EN    gpio21 ┘ pwrseq "bt"/"wlan"
                          └─ 固件：qca/hpbtfw21.tlv（patchram）+ qca/hpnv21.bin
```

DT 关键点（都在 `dts/sm8250-xiaomi-umi-common.dtsi` / `*-wifi.dts`）：

- `&uart6 { status = "okay"; bluetooth { compatible = "qcom,qca6390-bt"; ... } }`
- **必须有 `aliases { serial1 = &uart6; }`**：`qcom_geni_serial` 用
  `of_alias_get_id(np,"serial")` 取端口号，取不到就
  `Invalid line -19`，uart6 绑不上；而没绑上的 uart6 会让 qnoc 的
  `sync_state()` 一直 pending，把 `pcie0`（WiFi）一起拖住 ——
  表现就是「蓝牙没好，WiFi 也没了」。
- bluetooth 节点里那六条 `*-supply` **不是给驱动供电**（hci_qca 对 QCA6390
  的 `num_vregs = 0`），而是给 `pwrseq_qcom_wcn_match()` 认 consumer 用的：
  它要求 consumer 的 `vddaon-supply` 解析到「父节点是 PMU」的 regulator。
- `qca6390-pmu` 上的 `wlan-enable-gpios = <&tlmm 20>` / `bt-enable-gpios = <&tlmm 21>`
  是 pwrseq 真正去拉的脚（实测 BT 起来时 `gpio21: out high`）。

## 2. 已经验证成功的日志（这版内核里能看到）

```
/sys/class/bluetooth/hci0                     ← 设备节点出现
gpio21 : out high                             ← BT_EN 被 pwrseq 拉高
Bluetooth: hci0: setting up ROME/QCA6390
Bluetooth: hci0: QCA Product ID  :0x00000010
Bluetooth: hci0: QCA SOC Version :0x400a0200
Bluetooth: hci0: QCA Patch Version:0x00000d2b
```

## 3. 两个剩下的坑

### 3.1 固件名

驱动默认去要 `qca/htbtfw20.tlv`（别的芯片的命名），本机固件是
`qca/hpbtfw21.tlv`。用 DT 覆盖：

```dts
firmware-name = "qca/hpbtfw21.tlv";
```

### 3.2 BT 内建与旧模块树冲突（会连累 WiFi）

`CONFIG_BT=y` 需要 `CONFIG_RFKILL=y`；一旦 RFKILL 变成内建，rootfs 里
`/lib/modules/6.12.94-umi-dirty` 那份**旧构建**的 `rfkill.ko` / `pwrseq-core.ko`
就冲突（`exports duplicate symbol`），进而 `ath11k` 加载失败 → **wlan0 消失**。

两条路，任选其一：

1. **同步模块树**（推荐）：`make modules_install INSTALL_MOD_PATH=out/modroot`
   然后把 `out/modroot/lib/modules/<ver>/` 整棵推到手机上（`tools/push-modules.sh`），
   `depmod -a`。这样 =m 的驱动和内核 ABI 一致，BT 内建也没问题。
2. 或者把 WiFi 链也全部内建（ATH11K=y / QRTR/MHI/PHY_QCOM_QMP_PCIE=y），
   但要注意 `pcie-qcom` 的 early power-on 拿 `-517` 时**不会重试**
   （`Phy link never came up`），需要让它在 defer 时返回 `-EPROBE_DEFER`。

## 4. 复现步骤（模块同步之后）

```sh
# 手机侧
modprobe hci_uart           # 或直接重启，serdev 会自动匹配
ls /sys/class/bluetooth/    # 期望 hci0
bluetoothctl show           # 期望有 Controller 地址
systemctl enable --now bluetooth
```

## 5. 当前选择

为了先保网络，`&uart6` 暂时 `status = "disabled"`（DT 注释里写了原因）。
模块树同步做完后把 `status` 改回 `"okay"` 即可，不需要再动别的。
