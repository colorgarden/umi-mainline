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
| **mpv** | ✅ 自动（已配好） | `~/.config/mpv/mpv.conf` 里 `hwdec=v4l2m2m-copy`（`tools/install-mpv-hwdec.sh`） |

★ mpv 必须用 **`v4l2m2m-copy`**，不是 `v4l2m2m`：这个构建的零拷贝路径报
`Unsupported hwdec: v4l2m2m`，而 copy 变体可用（`Using hardware decoding (v4l2m2m-copy)`，venus 中断 +185）。

> 曾经在 `/usr/local/bin` 上做过 ffmpeg/ffplay 的「默认插解码器」包装层，
> 用户不接受，**已回退**；现在靠 `mpv.conf`（一行配置）+ GStreamer 的自动选择解决。

### 3.0.1 各编码实测（判据是 venus 中断增量，非 0 即真硬解）

| 编码 | 解码器 | venus 中断 |
|------|--------|-----------|
| H.264 1080p | `h264_v4l2m2m` | +440 ✅ |
| HEVC 720p | `hevc_v4l2m2m` | +452 ✅ |
| VP9 720p | `vp9_v4l2m2m` | +313 ✅ |
| H.264（mpv） | `v4l2m2m-copy` | +185 ✅ |
| H.264（gst playbin） | `v4l2h264dec` | +371 ✅ |

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

## 5. 能力矩阵（实测，2026-11-01 收尾）

判据统一是 **venus 中断增量 > 0**（软解永远是 0）。

### 5.1 解码：编码 × 分辨率 × 位深

| 样本 | ffmpeg `*_v4l2m2m` | mpv `v4l2m2m-copy` | gst playbin |
|------|-------------------|--------------------|-------------|
| H.264 1080p 8bit | ✅ +247 | ✅ +126 | ✅ `v4l2h264dec` +221 |
| HEVC 1080p 8bit | ✅ +421 | ✅ +257 | ✅ `v4l2h265dec` +369 |
| **HEVC 1080p 10bit** | ✅ +413 | ✅ +246 | ✅ `v4l2h265dec` +352 |
| **HEVC 4K 8bit** | ✅ +268 | ✅ +208 | ✅ `v4l2h265dec` +215 |
| **H.264 4K 8bit** | ✅ +117 | — | — |
| VP9 1080p | ✅ +319 | ✅ +145 | ✅ `v4l2vp9dec` +228 |

- 连续多轮解码后 `dmesg | grep -c 'venus.*error'` 仍为 **0**；
- ffmpeg 每次会打一行 `VIDIOC_G_FMT ioctl`（它探测格式的噪声，无害）。

### 5.2 编码（Venus `/dev/video1`）

```sh
ffmpeg -i in.mp4 -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 8M out.mp4
```

- 必须显式 `-pix_fmt nv12`，否则报 `Encoder requires nv12 pixel format`；
- 实测 1080p H.264 5 秒：硬编 845 ms / venus 中断 +313（软编 x264 ultrafast 1392 ms）；
- **录屏仍用 CPU x264**：`wf-recorder` 只能给 RGB 帧，直接喂 `h264_v4l2m2m`
  会报同样的 nv12 错误；而 `wf-recorder -c rawvideo -f -` 管道也不行
  （`avio_open failed`）。要硬件编码只能在文件级 ffmpeg 工作流里做。

### 5.3 已知无害噪声

| 输出 | 说明 |
|------|------|
| `VIDIOC_G_FMT ioctl` | ffmpeg m2m 探测格式，每个进程一次 |
| `Non-monotonic DTS` | 硬编时时间戳规整，输出可正常播放 |
| `connector DSI-1: Atomic commit failed` | phoc 启动时的 1~2 次（与视频无关） |

## 6. 快速自检

```sh
umi-video-check                 # 一条命令跑完：设备/固件/解码/播放器路径
umi-video-check my.mkv          # 检查指定文件能不能硬解
```

手工版：

```sh
v4l2-ctl --list-devices                       # 期望 Qualcomm Venus video decoder/encoder
v4l2-ctl -d /dev/video0 --list-formats-out    # 期望 H264/HEVC/VP9/VP8/MPG2
cat /sys/kernel/debug/venus/fw_level          # 期望非 0
ffmpeg -c:v h264_v4l2m2m -i test.mp4 -f null - && echo 硬解可用
grep -i venus /proc/interrupts                # 跑解码时这个计数应该涨
```

## 7. 会话/环境注意（踩过）

- 播放器要跑在**用户会话**里（`XDG_RUNTIME_DIR=/run/user/1001`、`WAYLAND_DISPLAY`），
  从 root 的 ssh 直接跑 `clapper` 会报 `Failed to open display`。
- 桌面的自动启动放在 `~/.zprofile`（登录 shell 是 zsh），只写 `.bash_profile`
  的话**桌面根本不会起来**（踩过：tty1 上只有 zsh）。见 `tools/fix-session-zsh.sh`。
