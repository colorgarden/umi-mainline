# 桌面环境：Phosh（替代 KDE Plasma Mobile）

> 2026-11-01 换的。手机上现在跑的是 **Phosh 0.57 + phoc 0.57 + gnome-session**，
> 开机流程没有 display manager，靠 tty1 自动登录后 exec 会话脚本。

## 1. 开机是怎么进桌面的

```
systemd → getty@tty1（autologin colorgarden）
        → zsh 读 ~/.zprofile
        → systemctl --user start phosh.service   ← 桌面由 systemd --user 管
        → exec sleep infinity                    ← 保住 logind session（seat/RUNTIME_DIR）

phosh.service（user unit，/etc/systemd/user/）
        → /usr/bin/phosh-session
        → dbus-run-session → phoc -v -S -C /usr/share/phosh/phoc.ini \
                             -E "gnome-session --session=phosh"
        → gnome-session 起 phosh（真二进制在 /usr/lib/phosh/phosh，不在 /usr/bin）
```

- 会话本体在 systemd 里可见：`/user.slice/user-1001.slice/user@1001.service/app.slice/phosh.service`
- `systemctl --user restart phosh`（以 colorgarden 身份）即可重启桌面
- `phoc` 崩溃后 5 秒自动拉起（`Restart=always`、`RestartSec=5`、无启动次数上限）
- 安装脚本：`tools/systemd-user-phosh.sh`（幂等）

### 1.0 为什么用 systemd --user，而不是系统级 unit

试过系统级 `phosh.service` + `PAMName=login`（pmOS 的做法），在这台机上**起不来**：
单元 1 秒就 `Deactivated successfully` —— 旧会话和 seat 还挂在 tty1 上，systemd
抢不到干净的会话。改成 user unit 后保留 getty（它才是正确创建 logind session /
seat / `XDG_RUNTIME_DIR` 的那层），只把"谁来监督 phosh"交给 systemd。

两个必须避开的坑（都实测踩过）：

| 坑 | 现象 | 解法 |
|---|---|---|
| `PartOf=graphical-session.target` | 主进程一死，systemd 当成"被 stop"，`Restart` 永不触发（日志只有 `Stopped`，没有 `Scheduled restart`） | 去掉 `PartOf=` |
| phoc 不响应 SIGTERM | 退出时做 DRM atomic commit 失败（`Atomic commit failed`）就卡住，默认 15 秒才被强杀 | `TimeoutStopSec=5` + `KillMode=control-group` |

- `getty@tty1` 的自动登录在 `/etc/systemd/system/getty@tty1.service.d/autologin.conf`
- **没有 sddm/lightdm**（`sddm` 是 disabled 状态，装 KDE 时留下的）
- `.zprofile` 才是生效的那个（登录 shell 是 **zsh**；只写 `.bash_profile` 桌面不会起来）

### 1.1 `umi-session` 兜底（已不在启动路径上，保留作应急）

```
/run/umi-session-fail 计数：Phosh 连崩 2 次 → 自动 exec Plasma Mobile
```
这是 systemd 接管之前的兜底（当时 getty 会把崩溃的会话反复拉起，形成
无限重启）。现在由 `Restart=always` 负责重启，`umi-session` 仅作为手动
应急入口保留：`/usr/local/bin/umi-session`。

排查完想回 Phosh：`rm -f /run/umi-session-fail` 再重启。

## 2. ★ Phosh 起不来的真正原因：wlroots 的 layer-shell 检查

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
