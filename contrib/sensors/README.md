# Xiaomi Mi 10 (umi) — SLPI sensor userspace

传感器(加速度计/陀螺仪/光感等)数据面在 SLPI(Sensor Low Power Island)上,
应用侧经 fastrpc `/dev/fastrpc-sdsp` 与之通信。内核侧(QCOM_FASTRPC=m、
sm8250.dtsi 的 slpi fastrpc/compute-cb 节点、slpi.mbn 固件)已就绪;这里
是用户态三件套:

## 内容

| 文件 | 去向 | 说明 |
|---|---|---|
| `bin/hexagonrpcd-umi` | `/usr/bin/` | 上游 linux-msm/hexagonrpc @ 93f3467 + `apollo-sensor-fixes.patch`(有根 HexagonFS `-R`、PD 修复)。无补丁的版本会让 SLPI 每分钟崩溃约 25 次并拖垮整机 |
| `bin/chrecd` | `/usr/bin/` | 上游附带(remoted ECD),保留备用 |
| `lib/libhexagonrpc.so.0.4` | `/usr/lib/` | daemon 依赖 |
| `systemd/*.service` | `/usr/lib/systemd/system/` | 上游原版单元 |
| `systemd/*.service.d/10-umi.conf` | 同上 `.d/` | ExecStart → hexagonrpcd-umi;sdsp 加 `-R /usr/share/qcom/sm8250/Xiaomi/umi` |
| `firmware/sm8250/Xiaomi/umi/` | `/usr/share/qcom/sm8250/Xiaomi/umi/` | 传感器注册表/配置树,取自 stock 固件(royka1 注:非设备特定;如后续发现 umi 专属差异可替换) |

umi 的 SLPI fastrpc 在 sdsp 上,`hexagonrpcd-sdsp.service` 是主服务;
两个 adsp 单元因 `ConditionPathExists=!/dev/fastrpc-sdsp` 自动跳过,
drop-in 仅为与 Mi 10T 布局对齐。

启用(board.conf `post_family_tweaks__xiaomi-umi_enable_services`,trixie):
创建 `fastrpc` 系统用户 → `ldconfig` → `systemctl enable hexagonrpcd-sdsp`。

## 一键 deb(已建好的 rootfs 上安装)

上面的 BSP 安装只在完整镜像构建时生效;在已经刷好的 trixie rootfs 上,
装一个包即可完成同样的动作:

```bash
# 构建(输出到 ~/build/output/debs/):
~/build/packages/bsp/xiaomi-umi/sensors/debian-pkg/build.sh
# 设备上(先刷 7.2.11-Sa2de-D0000-Pb69e 或更新的 kernel/dtb):
dpkg -i umi-sensors_1.0-umi3_arm64.deb
```

包内容 = 本目录全部用户态 + udev 挂载矩阵规则 + modules-load;postinst 会
创建 `fastrpc` 系统用户、ldconfig、enable 并(在 /dev/fastrpc-sdsp 已存在时)
restart `hexagonrpcd-sdsp`、reload udev 规则。

## 重新交叉编译 daemon

```bash
git clone https://github.com/linux-msm/hexagonrpc   # 93f3467dcfe1601bb70547611866a069ae914de5
cd hexagonrpc && patch -p1 < ~/Xiaomi-Apollo-pmOS-packages/hexagonrpcd-apollo/apollo-sensor-fixes.patch
# Debian 交叉工具链缺 arm64 libc 开发文件:
apt-get download libc6-dev-arm64-cross && dpkg -x libc6-dev-arm64-cross*.deb /tmp/arm64-dev
sed -i 's|/usr/aarch64-linux-gnu/lib/libc.so.6|...真实路径|; ...' /tmp/arm64-dev/usr/aarch64-linux-gnu/lib/libc.so
# 内核 uapi 头(fastrpc.h)与 asm/types.h:
make -C <kernel-tree> ARCH=arm64 headers_install  # → <tree>/usr/include
meson setup build --cross-file <ini>   # 见 git log / 本会话记录
ninja -C build && cp build/hexagonrpcd/hexagonrpcd bin/hexagonrpcd-umi
```
