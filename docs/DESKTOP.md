# 桌面环境：Phosh（替代 KDE Plasma Mobile）

> 2026-11-01 换的。手机上现在跑的是 **Phosh 0.57 + phoc 0.57 + gnome-session**，
> 开机流程没有 display manager，靠 tty1 自动登录后 exec 会话脚本。

## 1. 开机是怎么进桌面的

```
systemd → phosh.service（系统单元 /etc/systemd/system/phosh.service）
        → pam_systemd 开 session（session-1.scope，seat0，Type=wayland）
        → ExecStart=/usr/local/bin/umi-session → exec /usr/bin/phosh-session
        → dbus-run-session → phoc -v -S -C /usr/share/phosh/phoc.ini \
                             -E "gnome-session --session=phosh"
        → gnome-session 起 phosh（真二进制在 /usr/lib/phosh/phosh，不在 /usr/bin）
```

- 单元：`Type=simple`、`User=colorgarden`、**`PAMName=login`**、`TTYPath=/dev/tty1`、
  `StandardInput=tty`、`Restart=always`、`RestartSec=3`、`TimeoutStopSec=5`、
  `KillMode=control-group`、`Conflicts=getty@tty1.service`
- tty1 上的 getty **必须 mask**（`systemctl mask getty@tty1`），否则它抢 TTY，单元起来即退
- 应急控制台在 **tty2**（`getty@tty2` 已启用）
- `systemctl restart phosh` 直接重启桌面；`phoc` 崩溃后 3 秒自动拉起（实测日志
  `Scheduled restart job, restart counter is at 1`）
- 安装脚本：`tools/systemd-phosh-session.sh`（幂等）

### 1.0 为什么必须是「系统单元 + PAMName=login」

两次踩坑之后的结论：

| 方案 | 结果 | 原因 |
|---|---|---|
| **systemd --user 单元** | 黑屏 + `Atomic commit failed` + 背光被关 + 电源键直接关机 | phoc 跑在 `user@1001.service/app.slice`，**不在任何 logind session 里**；libseat 的 logind 后端因此不给 DRM master，也没人 inhibit 电源键 → logind 按 `HandlePowerKey=poweroff` 关机 |
| **系统单元 + PAMName=login**（当前） | 正常 | `pam_systemd` 新建 session，phoc 落在 `session-1.scope`（seat0 / Type=wayland），seat ACL、DRM master、输入、电源键 inhibit 全正常 |

另外两点：

- **不能在旧会话还占着 tty1 时热启动**这个单元（会 1 秒 `Deactivated successfully`）：
  先 mask getty，再重启
- `/etc/systemd/logind.conf.d/umi.conf` 设了 `HandlePowerKey=ignore`，
  桌面没起来时按电源键不会变成直接关机（正常时由 phosh 自己处理）

### 1.1 背光陷阱（黑屏但系统其实正常）

`systemd-backlight` 会保存/恢复亮度，文件是
`/var/lib/systemd/backlight/platform-ae94000.dsi:backlight:umi-panel`，
它曾被保存成 `80/2047`（≈4%）——开机后**看着是黑屏，实际在正常渲染**：

```sh
cat /sys/class/backlight/umi-panel/brightness      # 80  <- 元凶
cat /sys/class/drm/card1/card1-DSI-1/dpms          # On
grim /tmp/s.png                                     # 能截到锁屏 -> 渲染没问题
```

判据顺序：**先看 `dpms` 和 `grim` 能否截图**，再怀疑背光。
修法：`tools/fix-backlight.sh`（写 60% 并修正保存值）。

### 1.2 `umi-session` 兜底（保留作应急）

```
/run/umi-session-fail 计数：Phosh 连崩 2 次 → 自动 exec Plasma Mobile
```
现在由 `Restart=always` 负责重启，`umi-session` 只作手动应急入口：
`/usr/local/bin/umi-session`。

排查完想回 Phosh：`rm -f /run/umi-session-fail` 再重启。

## 1.3 外观 / 体感调优（Android 向）

一键脚本：`tools/umi-ui-tweaks.sh`（幂等）。

| 项 | 值 | 说明 |
|---|---|---|
| 界面字体 | `Noto Sans CJK SC 11` | 之前 UI 用的是**等宽**字体（像终端），现在是正常无衬线；等宽单独保留给终端 |
| 等宽字体 | `Noto Sans Mono CJK SC 10` | Alacritty 等 |
| 配色 | `prefer-dark` + `accent-color=blue` | Android 深色风格 |
| 图标 | `Papirus`（已装） | |
| 壁纸 | `/home/colorgarden/Pictures/wallpaper.png` | 现生成的径向渐变（深蓝→紫），不依赖网络 |
| 收藏夹 | 文件 / Clapper / Alacritty / 手机设置 | `sm.puri.phosh favorites` |
| 状态栏 | 显示电量百分比 | `show-battery-percentage true` |
| GPU | **min_freq = max_freq（587 MHz 锁定）** | `umi-gpu-perf.service`；见下 |

### 为什么锁 GPU 高频

本机**没有 cpufreq**，而且是刻意关的：`CONFIG_ARM_QCOM_CPUFREQ_HW` /
`_NVMEM` 都 `# not set`——它们会改写 CPU 电压/频率表，写错就是随机死机
（当年为稳定性的取舍）。所以 CPU 频率不可调，唯一能提升"跟手"的是 GPU：
`simple_ondemand` 在 UI 交互时会来不及升频，表现为掉帧；把 `min_freq`
提到 `max_freq` 后 GPU 常驻 587 MHz。

代价是功耗，回退：

```sh
systemctl stop umi-gpu-perf.service     # ExecStop 会把 min_freq 降回 305 MHz
systemctl disable umi-gpu-perf.service
```

### 还没做到"跟 Android 一样"的部分

| Android 行为 | Phosh 现状 |
|---|---|
| 底部上滑 = 回桌面 / 上滑停住 = 多任务 | Phosh 上滑进 overview（有，但不完全一样） |
| 左/右边缘内滑 = 返回 | **没有**。Wayland 下全局手势只能由合成器实现，Phosh/phoc 没提供 |
| 动画时长/曲线可调 | 没有开关，只有 `enable-animations` 全局开关 |
| 应用启动动效 | GNOME 应用自己的，跟 compositor 无关 |

要真正做到返回手势，需要在 `phoc` 里加边缘滑动 → 给焦点窗口发 Escape/Back，
属于改合成器（wlroots）的活，工作量中等，不影响其它功能。备选是换 Plasma
Mobile（KWin 有更完整的动画/手势框架，但历史上在这台机上更卡）。


现象（`journalctl -b _COMM=phosh`）：

```
phosh: Phosh ready after 1.37s
phosh: Error 71 (协议错误) dispatching to Wayland display.
phoc : [wayland] error in client communication (pid …)
```

用 `WAYLAND_DEBUG=1` 抓协议流，才看到 phoc 主动发给 phosh 的错误：

```
zwlr_layer_shell_v1#35.get_layer_surface(... wl_output#47, 2, "phosh home")
  set_size(0, 0)
  set_anchor(14)        ← BOTTOM|LEFT|RIGHT，没有 TOP
-> wl_display.error(zwlr_layer_surface_v1#77, 1,
     "height 0 requested without setting top and bottom anchors")
```

wlroots 上游 commit `8dec751a6d`（"layer-shell: error on 0 dimension without anchors"）
加了这个校验，而 **phosh 0.57 正是这样请求的**（它想"横向铺满、高度由合成器决定"）。
Debian / Alpine / Artix 都给 wlroots 打了 revert 补丁，**Arch 没打** —— 所以 Arch 的
phosh + phoc 在这台机器上必崩。

### 2.1 修法：自己编一个带 revert 的 `wlroots0.20` 包

**别用"替换 .so"的办法**：那个文件属于 `wlroots0.20` 包，`pacman -Syu`（甚至
`pacman -S wlroots0.20` 重装）会把它盖回 Arch 原版，phosh 就又崩。

正确做法（现在就是这么装的）：

```
contrib/pacman-hooks/wlroots0.20/PKGBUILD                              # Arch 官方 PKGBUILD + revert
contrib/pacman-hooks/wlroots0.20/Revert-layer-shell-*.patch
tools/build-wlroots-umi.sh      # 装构建依赖 + 以 colorgarden 身份 makepkg --skippgpcheck
tools/install-wlroots-pkg.sh    # pacman -U + 设 IgnorePkg + 重启会话
```

- 版本是 `0.20.2-2`（仓库是 `0.20.2-1`）：本地更高，`-Syu` 不会降级覆盖；
- `pkgrel` 只能是 `整数[.整数]`，写成 `1.umi1` 会被 makepkg 直接拒绝（踩过）；
- 另加 `IgnorePkg = wlroots0.20`（`/etc/pacman.conf`）双保险：
  上游涨版本时不会偷偷换回没打补丁的版本，需要时手工重编。
- 验证：`pacman -Qo /usr/lib/libwlroots-0.20.so` 应显示 `wlroots0.20 0.20.2-2`。

> 副作用提醒：IgnorePkg 意味着 `wlroots0.20` 不再随系统升级。
> 当 `phoc` 升到需要更新 wlroots 时，pacman 会因依赖版本不足而报错，
> 那时把 PKGBUILD 的 `pkgver` 改成新版、把 revert 补丁重新 rebase，再编一次。

> ⚠ 不要用 Debian 编好的 `libwlroots-0.20.so` 顶替：ABI 虽然一样，但构建选项不同，
> 表现为**应用窗口"起了但不显示"，切后台再切回来才出现**（phosh 日志里
> `Startup of app ... timed out`）。我们自编的包用 Arch 自己的 meson 选项，没有这个问题。

## 3. 组件清单（Arch ARM）

| 包 | 作用 |
|----|------|
| `phosh` | 手机外壳（GTK4/GTK3 桌面），二进制在 `/usr/lib/phosh/phosh` |
| `phoc` | wlroots 合成器（DSI-1 直接 KMS，90 Hz 已验证） |
| `gnome-session` | phosh 的会话框架（`phosh-session` 用它） |
| `squeekboard` | 屏幕键盘（OSK provider `sm.puri.OSK0`） |
| `phosh-mobile-settings` | Phosh 设置 |
| `gnome-backgrounds` | 壁纸（缺了 phosh 会刷 "Failed to load background image"） |
| `iio-sensor-proxy` | 自动旋转用（等传感器做完才有数据） |

## 4. 已知噪声（无害）

- `phosh: Failed to claim ambient sensor` —— 传感器还没做（SLPI 未启用）
- `phosh: Failed to set gamma for DSI-1` —— msm 没有 gamma LUT
- `phoc: Stacked surface ... not in same layer` —— phoc 的 layer effects 提示
- `phoc: connector DSI-1: Atomic commit failed`（开机时 1~2 次）—— 和面板 repower 时序有关，
  之后正常；显示、触摸、90 Hz 都不受影响

## 5. 想换回 Plasma Mobile

```sh
# 临时：改 /usr/local/bin/umi-session 最后一行
exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
# 或者直接把 ~/.bash_profile 换成 .bash_profile.before-phosh
```

## 6. 截屏 / 录屏

Phosh 跑在 phoc（wlroots）上，phoc 提供 zwlr_screencopy_manager_v1，
所以直接用 wlroots 那套工具（	ools/install-umi-shot-rec.sh 一次装好）：

| 操作 | 命令 | 结果 |
|------|------|------|
| 截屏 | umi-shot | ~/Pictures/Screenshots/shot-YYYYmmdd-HHMMSS.png（1080x2340） |
| 录屏 | umi-rec 第一次 = 开始，第二次 = 停止 | ~/Videos/Recordings/rec-*.mp4 |

应用网格里也放了「截屏」「录屏」两个图标（/usr/share/applications/umi-{shot,rec}.desktop）。

底层指令（想自己调参时）：

`sh
grim -o DSI-1 out.png                                  # 截屏
wf-recorder -o DSI-1 -D -f out.mp4 -c libx264 \
    -p preset=ultrafast -p crf=28 -r 30                # 录屏
`

★ **一定要 -D**：不加它 wf-recorder 只在画面变化时向合成器要帧，
手机屏幕经常是静态的 → 录出来可能只有几百字节。
★ 没有硬件编码：Adreno 650 没有 VAAPI 编码器（v4l2 那条主线还没接），
只能 CPU x264；ultrafast + crf28 + 30fps 在 SD865 上实测够用（约 33 KB/s 静态画面）。

### 1.3.1 桌面外观（2026-11-14）

| 项 | 值 |
|---|---|
| GTK 主题 | `adw-gtk3-dark`（`extra/adw-gtk-theme`，让 GTK3 应用也跟 libadwaita 一致） |
| 图标 | `Papirus-Dark` |
| 配色 | `prefer-dark` |
| 壁纸 | `~/Pictures/amber-d.jpg`（从 `gnome-backgrounds` 的 JXL 转成 1080x2340 JPEG） |
| 应用网格 | 关闭自适应过滤（`sm.puri.phosh app-filter-mode=[]`），改用手动隐藏开发工具：在 `~/.local/share/applications/` 里给 btop++/Htop/CMake/Qt V4L2 加 `NoDisplay=true` |
| 字体 | `Noto Sans CJK SC 11`，等宽 `Noto Sans Mono CJK SC 10` |

壁纸转换命令（JXL → 手机尺寸 JPEG）：

```sh
ffmpeg -i /usr/share/backgrounds/gnome/amber-d.jxl \
  -vf "scale=1080:2340:force_original_aspect_ratio=increase,crop=1080:2340" \
  -frames:v 1 -q:v 3 ~/Pictures/amber-d.jpg
```

想换别的：`gnome-backgrounds` 里还有 `adwaita-d`（深蓝）、`curvaturingster-d`（撞色）、
`balls-d`、`blendpills-d` 等，同样转一下再 `gsettings set org.gnome.desktop.background picture-uri`。

## 2. Plasma Mobile（2026-11-14 起，替代 Phosh）

桌面从 Phosh 换成了 **Plasma Mobile 6.8.2**，仍由 systemd 管理。

### 2.1 systemd 单元

`tools/systemd-plasma-mobile.sh` 安装 `/etc/systemd/system/plasmamobile.service`：

```ini
[Unit]
After=systemd-user-sessions.service
Conflicts=getty@tty1.service phosh.service
[Service]
User=colorgarden
PAMName=login            # 没有它 pam_systemd 不建 session -> 无 DRM master / 无输入
TTYPath=/dev/tty1
StandardInput=tty
ExecStart=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
ExecStartPost=-... systemctl --user import-environment WAYLAND_DISPLAY
Restart=always
```

`startplasmamobile` 会 `export PLASMA_DEFAULT_SHELL=org.kde.plasma.mobileshell`，
所以走的确实是移动 shell；`plasma-keyboard` 提供虚拟键盘。

### 2.2 踩过的坑（都会表现为“掉回 tty”）

| 现象 | 原因 | 处理 |
|---|---|---|
| `Could not create wayland socket` | 被杀掉的会话在 `/run/user/1001/` 留下 `wayland-1(.lock)` | `rm -f /run/user/1001/wayland-*` 后再启动 |
| `pam_systemd: VirtualTerminalAlreadyTaken` | 旧会话进程还占着 tty1 | `pkill -9 -u colorgarden -f startplasma`、`dbus-run-session`，再 `systemctl stop/start plasmamobile` |
| `plasmashell` 崩溃后整会话退出 | systemd --user 重启 plasmashell 时丢 `WAYLAND_DISPLAY` → 回退 xcb → abort → start-limit | 单元里 `ExecStartPost` 把 `WAYLAND_DISPLAY` 导入用户管理器 |
| 套用 `org.kde.breezedark.desktop` 后崩溃 | 那是**桌面版** look-and-feel，移动 shell 组件不全 | 用 `org.kde.breeze.mobile` + `plasma-apply-colorscheme BreezeDark` |

### 2.3 主题

```sh
plasma-apply-lookandfeel -a org.kde.breeze.mobile
plasma-apply-colorscheme BreezeDark
plasma-apply-wallpaperimage ~/Pictures/amber-d.jpg
```

截图（KWin 不支持 wlr-screencopy，grim 不可用）：

```sh
spectacle --fullscreen --background --nonotify --output /tmp/x.png
# 需要会话活着；会话刚崩过时 KWin 的 ScreenShot2 会拒绝请求
```

### 2.4 旧图形栈

Phosh/phoc/phosh-mobile-settings 已用 `pacman -Rs` 删除，旧 `phosh.service`、
`umi-session` 包装脚本一并清理。要回退需重装 phosh/phoc 并恢复单元（见 git 历史）。
