# 桌面环境：Phosh（替代 KDE Plasma Mobile）

> 2026-11-01 换的。手机上现在跑的是 **Phosh 0.57 + phoc 0.57 + gnome-session**，
> 开机流程没有 display manager，靠 tty1 自动登录后 exec 会话脚本。

## 1. 开机是怎么进桌面的

```
systemd → getty@tty1（autologin colorgarden）
        → login shell 读 ~/.bash_profile
        → exec /usr/local/bin/umi-session      ← 会话入口（带兜底）
        → exec /usr/bin/phosh-session
        → phosh-session: dbus-run-session → phoc -v -S -C /usr/share/phosh/phoc.ini \
                                              -E "gnome-session --session=phosh"
        → gnome-session 起 phosh（真二进制在 /usr/lib/phosh/phosh，不在 /usr/bin）
```

- `getty@tty1` 的自动登录在 `/etc/systemd/system/getty@tty1.service.d/autologin.conf`
- **没有 sddm/lightdm**（`sddm` 是 disabled 状态，装 KDE 时留下的）
- `.bash_profile` 里还留着 Plasma 的注释行，随时可以切回去

### 1.1 `umi-session` 兜底（很重要）

```
/run/umi-session-fail 计数：Phosh 连崩 2 次 → 自动 exec Plasma Mobile
```
没有这个兜底，Phosh 启动即崩时 getty 会把它当普通登录反复拉起，
形成**无限重启**（踩过：屏幕每 3 秒闪一次，SSH 都难连）。

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

### 2.1 修法：换掉 libwlroots

Arch 的 `wlroots0.20` 与 Debian 的 `libwlroots-0.20` 是同一版本（0.20.2），
ABI 一致，可以直接换 `.so`：

```sh
# 1) 取 Debian 的 arm64 包并解出 .so（tools/wlroots-revert-layershell.sh）
sh tools/wlroots-revert-layershell.sh          # → /tmp/wlrdeb/libwlroots-0.20.so
# 2) 备份原库 + 替换 + ldconfig（tools/install-phosh-session.sh 里也做了）
cp -a /usr/lib/libwlroots-0.20.so /root/lib-backup/libwlroots-0.20.so.arch-bak
cp -f /tmp/wlrdeb/libwlroots-0.20.so /usr/lib/libwlroots-0.20.so
ldconfig
```

验证：`ldd /usr/bin/phoc | grep wlroots` 指向 `/usr/lib/libwlroots-0.20.so`；
headless 试跑 12 秒不退出即成功：

```sh
XDG_RUNTIME_DIR=/run/user/0 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	dbus-run-session -- phoc -S -E /usr/lib/phosh/phosh
```

> ⚠ 注意：`pacman -Syu` 一旦更新 `wlroots0.20` 就会把这个补丁覆盖回去。
> 更新后要么重跑上面的替换，要么自己用 ABS/AUR 重编带 revert 的 wlroots。
> 备份在 `/root/lib-backup/`，随时可回滚。

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
