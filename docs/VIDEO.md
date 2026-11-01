# 视频硬件编解码（Venus）

> 状态：**已启用并验证可用**（2026-11-01）
> 硬件是 SM8250 里独立的 **Venus** 核（`video-codec@aa00000`），不是 Adreno 里的单元。

## 1. 能力（`v4l2-ctl --list-formats-out` 实测）

| 方向 | 节点 | 格式 |
|------|------|------|
| 解码 | `/dev/video0` | H.264 / HEVC / VP9 / VP8 / MPEG-2（都带 `dyn-resolution`） |
| 编码 | `/dev/video1` | H.264 / HEVC |
| 解码输出 | — | `NV12`（system memory）、`Q08C`（高通压缩格式） |

驱动内部固件等级 `fw_level = 0x18`（HFI 6XX），中断 `venus`（GIC SPI 206）。

## 2. 做了什么

1. **固件**：从 `modem` 分区 `image/` 取（`venus.mdt` + `venus.b00..b19`），
   装成 `/lib/firmware/qcom/sm8250/umi/venus.mbn` + `venus.bNN`
   → `tools/install-venus-firmware.sh`
2. **DTS**（`dts/sm8250-xiaomi-umi.dts`）：
   ```dts
   &videocc { status = "okay"; };          /* venus 的 core/vcodec0 时钟 + MVS0/MVS0C 两个 GDSC */
   &venus  { status = "okay"; firmware-name = "qcom/sm8250/umi/venus.mbn"; };
   ```
   ★ 只开 `&venus` 不开 `&videocc`，probe 会一直 `-EPROBE_DEFER`。
   ★ `video_mem`（5 MB，0x86e00000）是驱动给固件用的保留区，别动。
3. **config**：`CONFIG_VIDEO_QCOM_VENUS=m` 本来就有；驱动是三块模块
   `venus-core / venus-dec / venus-enc`。

## 3. 怎么用（关键：Venus 是 **stateful** M2M）

主线 6.12 的 venus 驱动**没有** media controller / request API 代码
（`grep media_device|MEDIA_IOC_REQUEST|SUPPORTS_REQUESTS drivers/media/platform/qcom/venus/` 为空），
所以它是 **stateful V4L2 M2M**，必须两端成对用：OUTPUT 喂码流、CAPTURE 收 NV12。

### 3.0 播放器场景：GStreamer 自动硬解（不需要任何包装）

★ **实测纠正**（2026-11-01 第二轮）：`v4l2h264dec`（GStreamer stateful）**本来就在用 Venus**。
之前用「墙钟时间」判断说它回落软解是错的 —— 判据必须是 **venus 中断计数 + CPU 时间**：

```
gst-launch-1.0 filesrc ! qtdemux ! h264parse ! v4l2h264dec ! fakesink   → venus 中断 +371
gst-launch-1.0 filesrc ! qtdemux ! h264parse ! avdec_h264   ! fakesink   → venus 中断 +0
ffmpeg -c:v h264_v4l2m2m ...                                            → venus 中断 +440
```

`playbin`（也就是所有 GStreamer 应用：clapper / totem / Phosh 播放器）会自动选它：

```
decodebin0/v4l2h264dec  (rank 257)  >  avdec_h264 (rank 256)
输出 caps: video/x-raw(memory:DMABuf), format=DMA_DRM, drm-format=NV12
venus 中断增量 +371
```

所以：

| 播放器 | 是否硬解 | 说明 |
|--------|----------|------|
| **clapper**（已装 `extra/clapper`） | ✅ 自动 | GStreamer 播放器，直接吃到 Venus |
| totem / 其他 GStreamer 应用 | ✅ 自动 | 同上 |
| ffplay | ⚠️ 需手动 | `umi-play in.mp4` 或 `ffplay -vcodec h264_v4l2m2m in.mp4` |
| **mpv** | ❌ 不行 | 这个构建的 `--hwdec` 只有 vaapi/vulkan/vdpau，没有 v4l2m2m |

> 曾经在 `/usr/local/bin` 上做过 ffmpeg/ffplay 的「默认插解码器」包装层，
> 因为 mpv/GStreamer 才是主战场且 GStreamer 已自动硬解，**已回退**。

### 3.1 手工指定解码器（ffmpeg）

```sh
ffmpeg -c:v h264_v4l2m2m -i in.mp4 -f null -        # 解码（H.264）
ffmpeg -c:v hevc_v4l2m2m -i in.mkv -f null -        # 解码（HEVC）
ffmpeg -c:v vp9_v4l2m2m  -i in.webm -f null -       # 解码（VP9）
```

实测（1080p H.264，300 帧）：

| | 墙钟 | CPU（user+sys） | venus 中断增量 |
|---|---|---|---|
| 软解 | 1.10 s | 6.19 s | 0 |
| `h264_v4l2m2m` | 1.28 s | **0.42 s** | **+518** |

→ CPU 降到 1/15，硬件确实在干活。

### 3.2 编码

```sh
ffmpeg -i in.mp4 -c:v h264_v4l2m2m -b:v 8M out.mp4     # 走 /dev/video1
```

## 4. 哪些路径**不**通（别浪费时间）

| 路径 | 结果 | 原因 |
|------|------|------|
| `v4l2-ctl --stream-mmap` 直接读 | 卡死、0 字节 | 漏了 `--stream-from`（只挂了 CAPTURE 端）；M2M 必须两端都挂 |
| `ffmpeg -hwaccel drm` | `Unsupported` / 回落软解 | FFmpeg 的 **V4L2 stateless request API** 从来没进主线（Bootlin 的补丁集），Arch 的 ffmpeg 没有 |
| mpv `--hwdec=drm` / `--hwdec=v4l2m2m` | `Unsupported hwdec` | 同上；这个 mpv 构建只带 vaapi/vulkan/vdpau |
| GStreamer `v4l2slh264dec`（stateless） | 插件 `0 features` | venus 不是 stateless，`v4l2codecs` 插件找不到带 request API 的设备 |
| GStreamer `v4l2h264dec`（stateful） | **✅ 可用** | 见 §3.0；之前说"回落"是判据错了 |

### 4.1 关于 stateless request API

**不是"修一下"就能有的**：主线 venus 驱动里根本没有 media controller / request 实现
（`grep 'media_device|MEDIA_IOC_REQUEST|SUPPORTS_REQUESTS' drivers/media/platform/qcom/venus/*.c` 为空），
它自 5.x 起就是 stateful M2M。

要让 stateless "可用"，等于**给 venus 写一条全新的解码路径**：

1. 注册 media device / media controller 实体
2. 为每个 buffer 分配 `MEDIA_IOC_REQUEST_ALLOC` + 绑定 request fd
3. 实现 H.264/HEVC/VP9 的 stateless codec controls（slice params、DPB、参考帧列表…）
4. 改 HFI 会话：stateful 是"喂码流让固件解析"，stateless 是"每帧传解析好的参数"
5. 固件侧是否接受这种用法还要验证（HFI 版本 6xx）

这是上游多年来没人做的工作量（数千行 + 固件不确定性），**而它换不来任何用户可见收益**——
因为 stateful 这条路上，GStreamer 已经自动硬解（clapper/totem 直接受益）。

如果目的是让 **mpv** 硬解，那也不是 stateless 的问题，而是 mpv 的构建里没有 v4l2m2m hwdec；
可以走 AUR 重编 mpv，或者直接用 clapper。

## 5. 下一步

1. **播放器**：用 `clapper`（已装）——GStreamer 自动硬解，无需配置。
2. **录屏编码**也可以上 Venus（现在 `umi-rec` 是 CPU x264）：
   试 `wf-recorder -c h264_v4l2m2m`，如果 wf-recorder 的 ffmpeg 编码器名对得上。
3. 真要 stateless：按 §4.1 的清单评估，属于"写驱动"级别的活，不是配置或补丁能解决的。

## 6. 快速自检

```sh
v4l2-ctl --list-devices                       # 期望 Qualcomm Venus video decoder/encoder
v4l2-ctl -d /dev/video0 --list-formats-out    # 期望 H264/HEVC/VP9/VP8/MPG2
cat /sys/kernel/debug/venus/fw_level          # 期望非 0
ffmpeg -c:v h264_v4l2m2m -i test.mp4 -f null - && echo 硬解可用
```
