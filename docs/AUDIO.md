# 音频（Umi / SM8250）—— 现状与移植计划

> 参考实现：`zhaoyuanwang123/armbian` 的 `patch/kernel/archive/sm8250-7.2/`
> - `0044-dts-add-xiaomi-umi-board.patch` —— 完整 umi 板级 DTS（音频链 + SLPI + 调制解调器）
> - `0510-audio-lpass-q6voice.patch` —— LPASS/ADSP 侧 q6voice（通话音频）补丁
> - `0043-umi-touch-stfts-panel-qdefconfig.patch` —— defconfig 里的音频开关（2.6 MB，含 stfts 驱动）
>
> 本文把「硬件接线 + 内核要什么 + 我们要做什么」拆开写，免得下次又从零翻补丁。

---

## 1. 硬件（从厂商 DT / 0077 之后的 dump 反推）

| 部件 | 型号 | 总线 | 地址 | 作用 |
|------|------|------|------|------|
| 主板 codec | **WCD9380/WCD9385**（`qcom,wcd9380-codec`） | SoundWire（`&swr1` / `&swr2`） | SDW 从设备 | 耳机/耳麦/听筒模拟通路、MBHC 检测 |
| 扬声器功放 ×2 | **Cirrus CS35L41** | I2C（`&i2c3`，1 MHz） | `0x40`（RCV 前缀）/ `0x42`（LCV 前缀） | 立体声喇叭 + 听筒，TDM 接 mi2s2 |
| 数字麦 | 6 路 DMIC | LPASS VA macro | — | 录音 |
| 音频 DSP | **ADSP**（q6afe/q6asm/q6adm） | glink / APR | — | 所有 PCM 播录、DSP 拓扑、通话 |
| 模拟偏置 | PM8150B/PM8150L `bob` | — | — | micbias、功放 VP |

关键电压/引脚（0044 里明确写了）：

```dts
wcd938x: audio-codec {
	compatible = "qcom,wcd9380-codec";
	reset-gpios = <&tlmm 32 GPIO_ACTIVE_LOW>;
	vdd-buck-supply = <&vreg_s4a_1p8>;
	vdd-rxtx-supply = <&vreg_s4a_1p8>;
	vdd-io-supply   = <&vreg_s4a_1p8>;
	vdd-mic-bias-supply = <&vreg_bob>;
	/* 2.75 V：vendor 的 cdc-micbias*-mv 就是 2.75 V，
	 * 用 1.8 V 会把 AMIC 饿死、耳机按键（mbhc）也检测不到 */
	qcom,micbias1-microvolt = <2750000>;   ... 4 路都是 2.75 V
	qcom,mbhc-buttons-vthreshold-microvolt = <75000 150000 237000 500000 500000 500000 500000 500000>;
	qcom,mbhc-headset-vthreshold-microvolt   = <1700000>;
	qcom,mbhc-headphone-vthreshold-microvolt = <50000>;
	qcom,rx-device = <&wcd_rx>;
	qcom,tx-device = <&wcd_tx>;
};
```

CS35L41（注意**同一颗 reset 脚** GPIO114，两根 IRQ 分开：112 = RCV / 113 = LCV）：

```dts
cs35l41_speaker: speaker-amp@40 {   /* sound-name-prefix = "RCV" */
	compatible = "cirrus,cs35l41";
	reg = <0x40>;
	interrupts = <113 IRQ_TYPE_LEVEL_LOW>;
	reset-gpios = <&tlmm 114 GPIO_ACTIVE_HIGH>;
	cirrus,boost-peak-milliamp = <4000>;
	cirrus,boost-ind-nanohenry = <1000>;
	cirrus,boost-cap-microfarad = <15>;
	cirrus,asp-sdout-hiz = <3>;
	cirrus,gpio2-src-select = <4>;
	cirrus,gpio2-output-enable;
};
cs35l41_rcv: speaker-amp@42 {       /* sound-name-prefix = "LCV" */
	... interrupts = <112 IRQ_TYPE_LEVEL_LOW>;
};
```

> ⚠ 槽位顺序是有讲究的：0x42（LCV）接**下喇叭**、0x40（RCV）接**上听筒**，
> 和 Mi 10T 参考正好相反。dai-link 里 `sound-dai = <&cs35l41_rcv 0>, <&cs35l41_speaker 0>;`
> 的顺序决定谁拿 TDM slot 0，写反了左右声道会反。

DSP 固件（remote proc）：

```dts
&adsp { status = "okay"; firmware-name = "qcom/sm8250/umi/adsp.mbn";
	glink-edge { apr { service@3 { iommus = <&apps_smmu 0x1801 0x0>; }; }; };
};
```

---

## 2. 内核需要什么（config）

armbian 的 defconfig 里和我们相关的项（`0043-...patch`）：

```
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_SOC=y
CONFIG_SND_SOC_QCOM=y
CONFIG_SND_SOC_SM8250=m
CONFIG_SND_SOC_CS35L41_I2C=m
CONFIG_SND_SOC_WCD938X_SDW=m
CONFIG_SND_SOC_LPASS_VA_MACRO=m
CONFIG_SND_SOC_LPASS_TX_MACRO=m
CONFIG_SND_SOC_LPASS_RX_MACRO=m
CONFIG_SND_SOC_WSA883X=m          # 我们不用（umi 是 CS35L41）
CONFIG_SOUNDWIRE=m
CONFIG_SOUNDWIRE_QCOM=m
CONFIG_QCOM_Q6V5_PAS=m            # ADSP remoteproc
CONFIG_QCOM_Q6V5_ADSP=m
CONFIG_SND_SOC_QCOM_*（q6afe/q6asm/q6adm/q6routing 都在 SND_SOC_QCOM 里）
```

我们 `config/umi.config` 目前**没有**任何 `SND_*`：所以现在连声卡都不会出现。
`SOUNDWIRE_QCOM` 和 `QCOM_Q6V5_PAS` 也要一起，否则 ADSP 起不来、swr 总线不 probe。

---

## 3. 固件

| 文件 | 来源 | 放哪 |
|------|------|------|
| `qcom/sm8250/umi/adsp.mbn`(+`.jsn`/`.bNN`) | 厂商 `vendor` / `modem` 分区，或从 MIUI 的 `/vendor/firmware` 取 | **initramfs** 不行（ADSP probe 在 rootfs 之后也行，但稳妥起见两边都放）|
| `qcom/sm8250/umi/cdsp.mbn` | 同上 | 同上 |
| `qcom/wcd938x/…`（wcd938x 的 `.bin`/`.jsn`） | linux-firmware 里有 `qcom/wcd9385/` 之类，需按本机型号对 | rootfs `/lib/firmware` |
| CS35L41 的 DSP `.bin/.wmfw` | **不需要**：umi 用 `cirrus,boost-type = <0>` 的固件内置模式，不加载 wmfw | — |
| `qcom/umi-avcs-custom-topologies.bin` | ADSP 的 AVCS 自定义拓扑（`q6core` 按名字加载） | rootfs `/lib/firmware/qcom/` |
| `qcom/q6voice-cal.bin`、`q6voice-vol-cal.bin`、`q6voice-devcfg.bin`、`q6voice-stream-cal.bin` | 通话音频校准（只有打 0510 的 q6voice 补丁才用） | 同上 |

### 3.1 ★ pd-mapper 不是可选项

armbian 的 board config 里写得很直白：

> `pd-mapper`（linux-msm 交叉编译）**REQUIRED for audio**：它让 ADSP 的 `avs/audio`
> 保护域通过 **PDR** 广播出来；没有它，APR 的 audio service 设备根本不会被创建，
> `sm8250-sndcard` 也就永远不会 bind。

也就是说：ADSP 起来了、`adsp.mbn` 也加载了，**声卡还是不出现** —— 先怀疑 pd-mapper，
而不是 device tree。它的源码在 linux-msm/pd-mapper，Arch 没有包，需要自己编：
`git clone https://github.com/linux-msm/pd-mapper && make && make install`（装到 `/usr/bin/pd-mapper`，
配 `pd-mapper.service`，`ConditionPathExists=/dev/fastrpc-adsp` 之类）。

> 我们已经踩过一次「=m 的驱动 boot 阶段看不到 initramfs 里的固件」的坑（`docs/BLUETOOTH.md`）。
> ADSP 是 `=m`，probe 在 rootfs 起来之后，所以**放 rootfs 就够**；
> 但 `adsp.mbn` 的分段文件（`.b00`…`bNN` + `.mdt` 命名规则）必须同前缀，
> 具体加载规则见 `drivers/soc/qcom/mdt_loader.c`。

---

## 4. DTS 要加的东西（照 0044 抄）

1. `&sound`（`qcom,sm8250-sndcard`）：`model`、`widgets`、`audio-routing`（0044 有完整 90 行，直接照抄）、
   `pinctrl-0 = <&tert_tdm_active>`，以及 5 条 dai-link：
   - `MultiMedia1/2/3` → `&q6asmdai`
   - `Tertiary TDM Playback` → `&q6afedai TERTIARY_TDM_RX_0` + `&cs35l41_rcv 0`/`&cs35l41_speaker 0`
   - `Tertiary TDM Capture` → `&q6afedai TERTIARY_TDM_TX_0`（回采，AEC 用）
   - `WCD Capture` → `&q6afedai TX_CODEC_DMA_TX_3` + `&wcd938x 1`/`&swr2 0`/`&txmacro 0`
   - `VA Capture` → `&q6afedai VA_CODEC_DMA_TX_0` + `&vamacro 0`
   - （可选的 `CS-VOICE` → `&q6voicedai`，通话才需要，配合 0510 的 q6voice 补丁）
2. `&q6afedai { dai@20 { reg = <TERTIARY_MI2S_RX>; qcom,sd-lines = <1>; }; }`
3. `&wcd938x` 节点（走 `sound/` 顶层，不在 i2c 下）
4. `&swr1`（RX 方向，`qcom,dout-ports = <5>`，挂 `wcd_rx: wcd9380-rx@0,4`，`qcom,rx-port-mapping = <1 2 3 4 5>`）
5. `&swr2`（TX 方向，`qcom,din-ports = <4>`，挂 `wcd_tx: wcd9380-tx@0,3`，`qcom,tx-port-mapping = <2 3 4 5>`）
6. `&txmacro` / `&rxmacro` / `&vamacro`（VA 要 `pinctrl-0 = <&dmic01_active>`、`vdd-micb-supply`、`qcom,dmic-sample-rate = <600000>`）
7. `&i2c3` 上的两颗 CS35L41（**我们当前 i2c3 被触摸占用，得先确认触摸到底在 i2c3 还是 i2c13**）
8. pinmux：`tert_tdm_active`（mi2s2 的 ws/sclk/data0/data1，GPIO135/136/137/…），CS35L41 的 IRQ/reset
9. `&adsp` 打开 + glink `apr` 的 `iommus`（`apps_smmu 0x1801 0`），
   否则 AVCS 拓扑起不来（音频 context bank 没配 DMA 域）

⚠ **i2c3 归属还没定**：我们 `dts/sm8250-xiaomi-umi-touch.dtsi` 把触摸放在 `&i2c13`
（`i2c@a94000`，GPIO36/37），而 0044 把触摸放 `i2c13`、把 CS35L41 放 `i2c3` —— 一致。
但 `sm8250-xiaomi-umi-plus.dts`（已删）当年把触摸写在 `&i2c3` 是错的，别再抄那份。

---

## 5. 用户端（Arch/Plasma Mobile）

```
# 播放测试
speaker-test -D hw:0,0 -c 2 -t sine -f 440

# 走 pipewire（KDE 默认）
wpctl status          # 应该能看到 Analog Stereo / 数字麦
pactl set-default-sink <sink>
```

需要 `pipewire`、`pipewire-pulse`、`wireplumber`（我们已有）。
如果 `aplay -l` 一个 card 都没有 → 内核层面没起来（看 `dmesg | grep -iE 'snd|q6|adsp|swr|cs35l41|wcd'`）。

### 5.1 ALSA UCM 配置（没有它 pipewire 不会切通路）

armbian 装的是 pmOS 那套 UCM2 配置：

```
/usr/share/alsa/ucm2/Xiaomi-Mi-10/Xiaomi Mi 10.conf
/usr/share/alsa/ucm2/Xiaomi-Mi-10/HiFi.conf
/usr/share/alsa/ucm2/Xiaomi-Mi-10/VoiceCall.conf
/usr/share/alsa/ucm2/conf.d/sm8250/X10.conf          -> ../../Xiaomi-Mi-10/Xiaomi Mi 10.conf
/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Mi 10.conf -> 同上
```

★ 声卡 short name 是 **`X10`**（long name `Xiaomi Mi 10`），不同 alsa-lib 版本查的是不同的名字，
所以两个符号链接都要建。没有 UCM，`wpctl` 里能看到 sink 但切 speaker/耳机/通话会失败。

**原文已扒到 `contrib/alsa-ucm/`**，三个文件 + 一个通话拓扑服务：

```
contrib/alsa-ucm/Xiaomi Mi 10.conf      → /usr/share/alsa/ucm2/Xiaomi-Mi-10/
contrib/alsa-ucm/HiFi.conf              （SectionVerb + 5 个 Device）
contrib/alsa-ucm/VoiceCall.conf
contrib/alsa-ucm/umi-voice-topology.service
```

HiFi 的 Device 名字（`wpctl`/`callaudiod` 靠这些名字）：

| Device | 说明 |
|--------|------|
| `Speaker` | 内置双喇叭（CS35L41） |
| `Earpiece` | 听筒（0x42 / LCV 前缀），`callaudiod` 通话时按名字选它 |
| `Internal Mic` | 顶部麦 AMIC5（主语音麦） |
| `Dual Mic` | AMIC5 顶 + AMIC1 底（AEC 参考）双麦 |
| `Headset Mic` | 耳机麦 AMIC2（WCD ADC2/INP2） |

### 5.2 通话拓扑要开机设一遍（`umi-voice-topology.service`）

`q6cvp` 是**内建**的，没有 modprobe.d 能带参数，重启就丢。保留默认值时
`bypass_topology` 会把收发都压成 `TOPOLOGY_ID_NONE` —— 通话**双向静音**。
必须开机写：

```sh
printf N        > /sys/module/q6cvp/parameters/bypass_topology
printf 0x00010f70 > /sys/module/q6cvp/parameters/tx_topology   # 发送用 NONE
printf 0x1000feee > /sys/module/q6cvp/parameters/rx_topology   # 接收用板级自定义拓扑
printf 1        > /sys/module/q6cvp/parameters/rx_channels
```

★ 收发故意不一样：自定义**发送**拓扑 `0x1000fffc` 是回声消除那条，
它采的 16 kHz 输入在本板上实测恒为 0 —— 用它就"下行有声、上行全哑"。
（以上是 armbian 在真机上踩出来的结论，不是理论推测。）

---

## 6. 落地顺序（建议）

1. **先只做 ADSP + remoteproc**：`CONFIG_QCOM_Q6V5_PAS=y`、`adsp.mbn` 进 rootfs、`&adsp` 打开。
   验证：`cat /sys/class/remoteproc/remoteproc*/state` → `running`；`dmesg` 里 `q6afe/q6asm` 注册成功。
2. **再加声卡**：`CONFIG_SND_SOC_SM8250=y`（内建，避免 initramfs/模块树时序）、`&sound` + q6afe/q6asm dai。
   此时应该出现 `card0`，但没声音（功放没配）。
3. **再点 CS35L41**（I2C + TDM）：`card0` 上有 Playback 且能出声。
4. **最后做 WCD938x + SoundWire**：耳机/耳麦/mbhc。
5. 通话（0510 的 q6voice）放最后 —— 它依赖 SDX55 调制解调器那条线，我们还没做。

---

## 7. 待确认（下次开工会卡住的点）

- [ ] `adsp.mbn` / `adsp.jsn` 从哪块分区取（`dump/` 里有 partitions 表，`modem` / `vendor` 都可能是载体）
- [ ] WCD938x 到底是 9380 还是 9385（影响 `compatible` 和固件名）
- [ ] `tert_tdm_active` 的 pinmux 是否已在 `sm8250.dtsi` 里（主线有 `tert_mi2s_active`，要 `/delete-node/ data0-pins` 后加 data1-pins）
- [ ] 我们 `&i2c3` 上有没有别的从设备（bq25970 在 i2c15，触摸在 i2c13，应该空着）

## 8. 当前卡点（2026-11-14 实测）

链路全部打通到 DSP，只剩最后一步：

```
声卡 X10 注册 ret=0
cs35l41 3-0040/3-0042 probe OK，PRE_PMU 无错（忽略 PUP 轮询超时）
cs35l41 set_sysclk 24.576MHz OK
AFE port 0x9020 start ret=0，set_param ret=0，scfg=yes
ADM device open（apr_send 48B）OK，matrix_map path=1 port=56 session=1 copp=0
ASM open / hw_params(48k,2ch,S16) / prepare / RUN 全部 ret=0
ASM_DATA_CMD_WRITE_V2 → status=0xa（ADSP_ENOTREADY）→ aplay EIO
```

已排除：TDM 槽位（含 8x32/96k 与 48k 两种）、TDM 位时钟、功放 PUP、
cs35l41 sysclk、ADM 端口/会话号、RUN 异步完成延迟（+50ms）、
q6asmdai 的 iommus/SID、MI2S 替代 TDM（声卡注册 -ENODEV，已回退）。

下一步候选：
1. ADM COPP topology：`q6routing_stream_open` 用 `NULL_COPP_TOPOLOGY`，
   TDM 端口可能需要专用 topology id；可打印/替换试。
2. 用 ADSP 侧命令抓包对比（设备上没有 AR/ASM 字符串，固件被压缩，
   拿不到版本信息）。
3. 换另一条 BE（如 PRIMARY MI2S）验证 ASM 数据面是否与 TDM 无关；
   若 MI2S 也 EIO，则是 ASM/ADM 配置问题，不是 TDM。

## 9. 已成功（2026-11-14）

**扬声器已经出声，用户确认听到 1 kHz。**

关键配置（三条都必需）：

1. `dts/sm8250-xiaomi-umi.dts`：speaker dai-link 的 cpu dai 用
   **`TERTIARY_MI2S_RX`**（port 20 / AFE 0x1004），不是 TDM_RX_0。
2. `&q6asmdai { iommus = <&apps_smmu 0x1801 0x0>; }`：
   缺了它 `q6asm_dai_probe` 得到 `sid = -1`，ADSP 拿裸物理地址访问共享内存。
3. 机器驱动 MI2S 分支里给每颗 CS35L41 设 channel map（RX1/RX2 = {!j,j}）
   + `set_sysclk(MI2S_BCLK_RATE)`，外加 cs35l41 的 PUP 轮询/SYSCLK 补丁。

持久化：`tools/install-audio-route.sh` 装 `umi-audio-route.service`，
开机后把 `TERT_MI2S_RX Audio Mixer MultiMedia1` 打开、功放音量设 12（60%）。
重启后实测：服务 active、mixer on、`aplay` rc=0，只有关闭时一条无害的
`status=0xa`（DSP 对关闭后到达的写响应）。

对照实验（说明为什么之前一直失败）：
| 后端 | aplay 结果 |
|---|---|
| DISPLAY_PORT_RX | 成功（无 EIO） |
| TERTIARY TDM | ASM_DATA_CMD_WRITE_V2 → 0xa (ENOTREADY) |
| **TERTIARY MI2S** | **成功出声** |

待办：PipeWire/WirePlumber 还没有把这张卡做成可用的 sink（UCM 文件仍不完整，
`spa.alsa: Path Speaker is not a volume or mute control`），普通应用要出声
还需要修 UCM 或加 WirePlumber 规则。
