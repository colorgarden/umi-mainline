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

### 3.0 已经做成「默认硬解」（ffmpeg / ffplay 包装层）

ffmpeg 没有「默认解码器」这种配置项，所以在 PATH 里（`/usr/bin` 之前）顶了一层包装：

```
contrib/ffmpeg-wrapper/ffmpeg   -> /usr/local/bin/ffmpeg
contrib/ffmpeg-wrapper/ffplay   -> /usr/local/bin/ffplay
```

行为：

1. 找第一个 `-i` 的输入（ffplay 取第一个真实存在的文件），用 `ffprobe` 看编码；
2. 有对应的 `*_v4l2m2m`，就在 `-i` **之前**插 `-c:v <dec>`
   （`-c:v` 只有放在 `-i` 前才作用于「输入解码」，输出的 `-c:v libx264` 不受影响）；
3. **硬解失败自动回退软解**（非 0 退出就用原始参数重跑）——
   硬解遇到异常 profile / 超大分辨率会硬失败，不能让视频因此打不开；
4. 信息类调用（`-version` / `-decoders` / …）和用户已经显式写了 `-c:v` 的命令**原样透传**。

```sh
ffmpeg -i in.mp4 out.mp4                    # 自动硬解 + 软编
ffplay in.mp4                               # 自动硬解播放
umi-play in.mp4                             # 等价（自带 codec 探测）

UMI_FFMPEG_SOFTWARE=1 ffplay in.mp4         # 临时强制软解
UMI_FFMPEG_WRAPPER_DEBUG=1 ffplay in.mp4    # 打印最终 argv（排错）
```

实测（1080p H.264，2 秒）：默认路径 venus 中断 **+87**；`UMI_FFMPEG_SOFTWARE=1` 时 **+0**。

### 3.1 手工指定解码器（不走包装时）

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
| GStreamer `v4l2h264dec`（stateful） | 静默回落 `avdec_h264` | 见下 |

### 4.1 `v4l2h264dec` 为什么会回落（还没啃完）

`gst-inspect` 能看到设备（`Probing 'Qualcomm Venus video decoder' /dev/video0`，
输出格式 flags `0x9` = COMPRESSED|DYN_RESOLUTION），caps 也能协商成
`byte-stream, alignment=au`，但实际跑到 1.19s（= 软解耗时），Venus 零中断。

要排查的话从这里下手：

```sh
GST_DEBUG='v4l2*:7' gst-launch-1.0 -v filesrc location=in.mp4 ! qtdemux \
    ! h264parse ! v4l2h264dec ! fakesink sync=false 2>&1 | grep -iE 'error|negotiat|buffer|format'
```

猜测方向：`v4l2h264dec` 需要 `V4L2_FMT_FLAG_CONTINUOUS_BYTESTREAM`（flags 里只有 0x9），
或者需要用 `video/x-raw(memory:DMABuf)` 的 CAPTURE 端。

## 5. 下一步（要真正在播放器里用上）

1. **GStreamer 修通**：修好后 `clapper`/`totem`/Phosh 里的视频播放器自动受益，
   这是移动端最主要的路。
2. 或者给 mpv 打 `v4l2m2m` hwdec 支持（mpv 有 `--hwdec=v4l2m2m`，但当前构建没编进去）。
3. 编码也可以给 `umi-rec` 用上（现在录屏是 CPU x264）：
   `wf-recorder -c h264_v4l2m2m`（需确认 wf-recorder 的 ffmpeg 编码器名字）。

## 6. 快速自检

```sh
v4l2-ctl --list-devices                       # 期望 Qualcomm Venus video decoder/encoder
v4l2-ctl -d /dev/video0 --list-formats-out    # 期望 H264/HEVC/VP9/VP8/MPG2
cat /sys/kernel/debug/venus/fw_level          # 期望非 0
ffmpeg -c:v h264_v4l2m2m -i test.mp4 -f null - && echo 硬解可用
```
