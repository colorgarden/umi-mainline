
## 5. Type-C / PD 充电（2026-11-15 修好）

### 5.1 症状

- 插电脑正常（SDP 5V）
- 插 PD 充电器：`online` 每 2 秒 0/1 跳变、VBUS 反复归零、`cc-state-change` 与
  `vbus-change` 中断持续增长 —— 表现为“充电断连循环”
- PD 从未协商：`power_operation_mode = 3.0A`（这其实只是 Type-C 电流档），
  `tcpm-source-psy-*` 一直 offline，`usb_power_delivery/sink-capabilities` 为空

### 5.2 根因

`&pm8150b_typec` 的 `connector` 里没有写 `data-role`。TCPM 在 sink attach 时调用：

```c
#define tcpm_data_role_for_sink(port) \
	((port)->typec_caps.data == TYPEC_PORT_DFP ? TYPEC_HOST : TYPEC_DEVICE)
```

`typec_caps.data` 来自 DT 的 `data-role`；缺省时退化成 DFP，于是
`data_role` 被报成 **host**。而这块板的 dwc3 是 `dr_mode = "peripheral"`（只能做 device），
角色冲突导致 PD 状态机无法完成协商，充电器一直在 Source/Sink 之间反复重试。

### 5.3 修复

`dts/sm8250-xiaomi-umi-common.dtsi` 的 connector 里加一行：

```dts
data-role = "device";
```

### 5.4 验证

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `data_role` | `[host]` | `[device]` |
| `power_operation_mode` | `3.0A` | `usb_power_delivery` |
| VBUS | 0（反复断） | 11.92–11.94 V |
| `online` | 0/1 循环跳 | 持续 1 |
| 电流 | 0 | 165–187 mA（偶发 12.13V/0mA 是 PD 微调） |

电池 `status` 从 `Discharging` 变 `Full`，容量 49% → 51%。
