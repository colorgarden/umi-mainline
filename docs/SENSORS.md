# 重力/方向传感器（Umi / SM8250，SLPI/SSC）—— 现状与移植计划

> 参考实现：`zhaoyuanwang123/armbian`
> - `patch/kernel/archive/sm8250-7.2/0044-dts-add-xiaomi-umi-board.patch`（`&slpi` + `slpi_mem`）
> - `config/boards/xiaomi-umi.conf` 里的 `post_family_tweaks_bsp__xiaomi-umi_sensors()`

## 0. 一句话结论

imu（加速度/陀螺/als/…）**不在** I2C/SPI 上，而是挂在 **SLPI（Sensor DSP，SSC）** 后面；
内核只提供 `fastrpc` 通道，真正的传感器服务在 **Hexagon DSP 固件 + userspace 守护进程** 里。
所以「自动旋转」= ①SLPI remoteproc 起来 ②`/dev/fastrpc-sdsp` 出现 ③`hexagonrpcd-sdsp` 跑起来
④`libssc`/`iio-sensor-proxy` 把数据喂给桌面。**缺任何一环桌面都看不到 sensor**。

---

## 1. 内核侧

### 1.1 设备树（照 0044）

```dts
/* reserved-memory 里删掉上游 MTP 的 slpi_mem，按 umi 实际地址重写（47 MB） */
slpi_mem: slpi@88c00000 {
	reg = <0x0 0x88c00000 0x0 0x2f00000>;
	no-map;
};

&slpi {
	status = "okay";
	firmware-name = "qcom/sm8250/umi/slpi.mbn";
};
```

`fastrpc` 的 compute bank **sm8250.dtsi 里已经写好**（`/dev/fastrpc-sdsp` 就是这么来的），
板上不需要额外节点；需要的是固件 + `CONFIG_QCOM_FASTRPC`。

我们现在的状态：`dts/sm8250-xiaomi-umi.dts` 里 `&slpi/&adsp/&cdsp/&venus` 都已写好
`firmware-name`，但 **`status = "disabled"`** —— 固件还没弄到，贸然打开只会刷 -ENOENT。

### 1.2 config

```
CONFIG_QCOM_Q6V5_PAS=m          # remoteproc（adsp/cdsp/slpi 共用）
CONFIG_QCOM_FASTRPC=m
CONFIG_RPMSG_CHAR=m
CONFIG_RPMSG_QCOM_GLINK_SMEM=m
CONFIG_QCOM_SYSMON=m            # sleepmon，SLPI 侧需要
CONFIG_QCOM_PDR_HELPERS=y       # PD 通告（libssc 依赖）
CONFIG_QMI_HELPERS=y
CONFIG_ARM_SMMU / IOMMU 相关（已有）
```

### 1.3 固件

| 文件 | 说明 |
|------|------|
| `qcom/sm8250/umi/slpi.mbn`（`.b00`…`.bNN` 同前缀） | SLPI 固件，来自厂商 `vendor`/`modem` 分区 |
| `adsp.mbn` / `cdsp.mbn` | 音频/计算 DSP，`hexagonrpcd-adsp-*.service` 也要用 |
| `/usr/share/qcom/sm8250/Xiaomi/umi/`（**传感器注册表**） | 从原厂固件抄的 HexagonFS 目录树，hexagonrpcd 通过 `-R` 指到这里 |

> 注册表不是"每台设备的数据"，是「哪颗 sensor 在哪个 SSC 客户端 id 上」的映射；
> armbian 是从原厂镜像里扒的。我们 `dump/` 里如果有 vendor 分区镜像，也能扒。

---

## 2. 用户态（这是重点，内核只是一半）

armbian 装了这些（Arch 上对应改名）：

| 组件 | 作用 | Arch 现状 |
|------|------|-----------|
| `hexagonrpcd`（他们打了个 umi 补丁版 `hexagonrpcd-umi`，带 apollo-sensor-fixes + rooted HexagonFS `-R` + PD 修复） | fastrpc 上的 RPC 守护，负责把 SSC 拉起来 | AUR 有 `hexagonrpc`；**需要打补丁** |
| `chrecd` | CHRE（Context Hub Runtime Environment）守护，部分 sensor 走这条路 | 同仓库 |
| `libhexagonrpc.so.0.4` | fastrpc 库 | 随 hexagonrpc |
| `libssc` | SSC → IIO 的桥，注册 accelerometer/gyro/als 到 `/sys/bus/iio` | AUR `libssc-git` |
| `iio-sensor-proxy` | IIO → D-Bus `net.hadess.SensorProxy`，Plasma 靠它自动旋转 | `community/iio-sensor-proxy` |
| `hexagonrpcd-sdsp.service` + drop-in `10-umi.conf` | SLPI 那一路（`ConditionPathExists=/dev/fastrpc-sdsp`） | 要自己写 |
| `hexagonrpcd-adsp-rootpd.service` / `hexagonrpcd-adsp-sensorspd.service` | ADSP 的两个 PD | 同上 |
| `modules-load.d/umi-sensors.conf` | **fastrpc 必须先加载**，否则 sdsp 的 Condition 判不过 | 要自己写 |
| udev `60-fastrpc-umi.rules` | `/dev/fastrpc-*` 给 `fastrpc` 组 | 要自己写 |
| udev `81-libssc-xiaomi-umi.rules` | 加速度计 mount matrix（方向不对就翻车） | 要自己写，值需实测 |
| `pd-mapper`（linux-msm，交叉编译） | 让 ADSP 的 `avs/audio` PD 通过 PDR 广播 —— **音频也依赖它** | 无 AUR，需自己编 |

### 2.1 启动顺序（抄他们的 Condition 逻辑）

```
modprobe fastrpc  →  /dev/fastrpc-sdsp、/dev/fastrpc-adsp
        ↓
hexagonrpcd-sdsp（-R /usr/share/qcom/sm8250/Xiaomi/umi）
        ↓
libssc 探测 SSC  →  /sys/bus/iio/devices/iio:deviceN
        ↓
iio-sensor-proxy  →  D-Bus net.hadess.SensorProxy
        ↓
KDE：系统设置 → 屏幕 → 方向（或 kwin 的自动旋转）
```

### 2.2 旋转矩阵

`81-libssc-xiaomi-umi.rules` 里给 `accel` 一个 `ACCEL_MOUNT_MATRIX`。
armbian 的注释明确说：**起始值抄 Mi 10T，必须在真机上验**。
验法：`monitor-sensor`（iio-sensor-proxy 自带）看 Orientation 和实际转手机是否一致；
不一致就试那 8 个正交矩阵。

---

## 3. 我们的落地顺序

1. `CONFIG_QCOM_FASTRPC=m`、`QCOM_Q6V5_PAS=m` 进 `config/umi.config`（SLPI 也靠 PAS）。
2. 弄到 `slpi.mbn` → 放 `/lib/firmware/qcom/sm8250/umi/` → 把 DTS 里 `&slpi` 改 `okay`。
   验证：`cat /sys/class/remoteproc/remoteproc*/state`（slpi 那个应该 `running`）、`ls /dev/fastrpc*`。
3. 装 `hexagonrpc`（AUR）+ 打 umi 补丁（rooted HexagonFS），写 sdsp/adsp 三个 unit。
4. 装 `libssc` + `iio-sensor-proxy`；`monitor-sensor` 应该开始有数据。
5. 校准 mount matrix，然后 KDE 自动旋转即可用。

> 顺序上的坑：**`pd-mapper` 不只服务音频**。armbian 说 ADSP 的 `avs/audio` PD 要它广播，
> 而 `hexagonrpcd-adsp-*` 同样依赖 PDR。先把 pd-mapper 编出来（linux-msm 仓库，交叉编译），
> 再做别的会省很多事。

---

## 4. 待确认

- [ ] `slpi.mbn` 从哪取（`modem` / `vendor` / `dump/` 里的哪个镜像）
- [ ] 我们内核 6.12 的 `fastrpc` 支不支持 rooted HexagonFS（`-R`）—— 取决于 `hexagonrpcd` 版本，不是内核
- [ ] `CONFIG_QCOM_PDR_HELPERS` 在 6.12 是否还需要显式开（可能已被 `QCOM_Q6V5_PAS` select）
- [ ] Umi 的 accelerometer 是 **BMI260/BMI26x 还是 ICM4xxx**（决定 mount matrix 和 scale）
