# KDE Plasma Mobile on umi

状态（2026-10，镜像是 `boot-umi-plasma1.img` = GPU+触摸+WiFi 那一份 + 面板物理尺寸修复）：

```
plasmashell (Plasma Mobile 6.8.1) 在全屏 1080x2340 上跑着
kwin_wayland  drm 后端，持有 card1/renderD128 + event0..3（含触摸）
触摸可用（点得准），输出缩放 scale=2.5（逻辑 432x936）
GL 4.6 / GLES 3.2（freedreno FD650），Vulkan 1.3（turnip）
```

开机自动进桌面：`getty@tty1` 自动登录 `alarm` → `~/.bash_profile` 里
`exec startplasmamobile`。没有用 SDDM —— touch-only 的机器上少一个 greeter
就少一处会坏的地方。

## 1. 装

```sh
pacman -S --needed --disable-sandbox \
    plasma-mobile plasma-settings kscreen konsole
```

`plasma-mobile` 自己只有 20 MB，但会把 `plasma-workspace` / `kwin` /
`plasma-nano` / `plasma-keyboard` 一起拉下来（1 GB 量级）。它自带一个
wayland session：

```
/usr/share/wayland-sessions/plasma-mobile.desktop
    Exec=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
```

## 2. 桌面用户 + 自动登录 + 自动进桌面

桌面用户是 **`colorgarden`**（uid 1001），在 `wheel,input,video,render,audio` 组，
所以 sudo、读 `/dev/input/*`、用 DRM 都不缺权限：

```sh
useradd -m -s /bin/bash -G wheel,input,video,render,audio colorgarden
echo 'colorgarden:********' | chpasswd          # 密码只写进设备，不进仓库
printf '%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
```

原来的 `alarm` 保留着（uid 1000），只是不再自动登录；它的 `~/.config`
（里面是 `kwinoutputconfig.json` 的 scale=2.5）拷给了新用户。

`/etc/systemd/system/getty@tty1.service.d/autologin.conf`：

```ini
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin colorgarden --noclear %I linux
```

`/home/colorgarden/.bash_profile`：

```sh
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" = "1" ]; then
	exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile
fi
```

`systemctl disable sddm`（装了但不用）。

## 3. 触摸点不动：udev 的 `uaccess`（真正的坑）

现象：Plasma 起来了、界面在，但**点哪儿都没反应**；`/dev/input/event2`
权限是 `root:input 660`，登录用户打不开。

原因：

```
$ udevadm info --query=property --name=/dev/input/event2 | grep TAGS
TAGS=:power-switch:            <- 没有 uaccess
$ getfacl -p /dev/input/event2
user::rw-  group::rw-  other::---      <- 没有 user:alarm:rw 的 ACL
```

systemd 自带的 `70-uaccess.rules` 只给 **USB** 输入设备打 `uaccess` tag，
而 umi 的触摸是 **platform(i2c) 设备**（`platform:a94000.i2c`），所以 logind
从来不给登录会话发 ACL，KWin 的 libinput 自然打不开它。

修法（`/etc/udev/rules.d/71-umi-input-uaccess.rules`）：

```
SUBSYSTEM=="input", KERNEL=="event[0-9]*", TAG+="uaccess"
```

```sh
udevadm control --reload
udevadm trigger --action=change --subsystem-match=input
systemctl restart getty@tty1        # KWin 只在启动时枚举输入设备
```

兜底还可以 `usermod -aG input,video,render,audio alarm`。

修好之后：

```
$ ls -l /proc/$(pgrep -x kwin_wayland)/fd | grep input
 -> /dev/input/event0 (pm8941_pwrkey)
 -> /dev/input/event1 (pm8941_resin)
 -> /dev/input/event2 (fts)      <- 触摸
 -> /dev/input/event3 (gpio-keys)
```

## 4. “67 寸屏”：物理尺寸单位是 0.1 mm

现象：界面能点，但**小得离谱**（KWin 默认 scale=1）。

原因：下游 DT 里

```dts
xiaomi,physical-width-mm  = <0x2c6>;   /* 710 */
xiaomi,physical-height-mm = <0x601>;   /* 1537 */
```

单位是 **0.1 mm**，真机是 71.0 × 153.7 mm。驱动直接把它们喂给了
`connector->display_info.width_mm/height_mm`，于是 DRM 报 710×1537 mm，
`fastfetch` 里能看到 `1080x2340 in 67"`，KWin/kscreen 按这个算 DPI 就给了
scale 1.0。

修法：`patches/panel-xiaomi-umi.c` 里解析后除以 10（≥100 才除，防手写 DT 写
71 的情况）。修完 `fastfetch` 显示 `in 7"`。

## 5. 缩放：scale=2.5

KWin 在 Plasma 6 里不会按物理尺寸自动放大（kscreen 的自动缩放没生效），要显式设。
`~/.config/kwinoutputconfig.json`（KWin 自己的格式，是个数组）：

```json
[
  { "name": "outputs", "data": [ { "connectorName": "DSI-1", ..., "scale": 2.5 } ] },
  { "name": "setups",  "data": [ ... ] }
]
```

⚠️ **顺序**：KWin 退出时会把当前状态写回这个文件，所以必须

```
结束会话（等 kwin 真退出） → 改 scale → 起会话
```

否则刚改的值会被它覆盖（我踩过一次，白改）。

现用 **2.5** → 逻辑分辨率 432×936，接近普通手机。要更大就 3.0。

`kscreen-doctor` 在这台机器上会 **core dump**（`output.DSI-1.scale.2` →
`Aborted`），所以只能改文件；`kscreen` 的图形设置也一样不靠谱。

## 6. 会话挂了怎么救

```sh
systemctl restart getty@tty1
# 等 10~30 s；不行就看：
journalctl -b -u getty@tty1 --no-pager | tail
journalctl -b _UID=1000 --no-pager | tail -30
```

`loginctl terminate-session <id>` + `pkill -u alarm` 之后要靠 `getty@tty1`
重登才会再起 Plasma；重启 getty 本身不会杀掉已经在跑的会话进程，所以“重启
getty”要配合先结束会话。

## 7. 一键脚本

`scripts/umi-plasma.sh` 把第 1–3 步（装包、自动登录、udev、locale）固化了：

```sh
ssh root@PHONE 'sh /root/umi-plasma.sh --apply'
```

（不带 `--apply` 只打印要做什么。）

## 8. 中文界面：zh_CN + MiSans + 等宽终端

一键：`scripts/umi-zh.sh --apply`（幂等，可反复跑）。四个坑：

1. **只改 `LANG` 不够**。`zh_CN.UTF-8` 必须先在 `/etc/locale.gen` 里取消注释再
   `locale-gen` 真生成，否则 Qt 拿到的是 `C`，界面照样英文。验证：
   `locale -a | grep zh` → `zh_CN.utf8`。
2. **`/etc/locale.conf` 只对之后启动的单元生效**。已经跑着的 `getty@tty1` 不会重读，
   所以要么 `systemctl set-environment LANG=zh_CN.UTF-8`，要么在 `~/.bash_profile`
   里 `export LANG`。查会话环境：

   ```sh
   tr '\0' '\n' < /proc/$(pgrep -f /usr/bin/plasmashell | head -1)/environ | grep LANG
   ```

3. **缺 CJK 字体就是豆腐块**。`plasma-mobile` 的 340 个 `zh_CN/*.mo` 本来就在，
   缺的只有字体：`pacman -S noto-fonts-cjk`。
4. **MiSans 的权重元数据是错的**（`@fontpkg/mi-sans` 的 OTF：Regular=53、
   Medium=75）。不改的话 fontconfig 会把 Medium 当常规，整个界面变中黑字。
   用 `match target="scan"` 按 style 名重设 weight（`66-umi-misans-weight.conf`）。

字体落地（官方整包 `MiSans_Global_ALL.zip` 太大，unpkg 上这套单字重 OTF 够用）：

```sh
mkdir -p /usr/share/fonts/misans
curl -L https://unpkg.com/@fontpkg/mi-sans@4.3.0/MiSans-Regular.otf \
	-o /usr/share/fonts/misans/MiSans-Regular.otf
fc-cache -f
fc-match 'sans-serif:lang=zh-cn'    # 期望 MiSans-Regular.otf
```

`/etc/fonts/conf.d/65-umi-misans.conf`：`zh` 的 `sans-serif` 前置 `MiSans`，再弱回落
`Noto Sans CJK SC`（MiSans 缺的生僻字）。

### 终端（Konsole）

- MiSans **不是等宽字体**，设成 `fixed` 后终端里英文间距会拉得很开。等宽必须真等宽：
  `kdeglobals` 的 `fixed=Hack,9`，Konsole 自己的 profile 用 `Font=Hack,8`
  （8pt，一屏行数更多），中文照样回落 MiSans。
- 想再小/再大：Konsole 里 `Ctrl+-` 缩小、`Ctrl+0` 复位，或直接改
  `~/.local/share/konsole/Mobile.profile` 的 `Font=`。
- **终端单独切语言**：Konsole 没有独立语言开关，但可以只给它的启动项套环境 ——
  `~/.local/share/applications/org.kde.konsole.desktop` 里写
  `Exec=env LANG=en_US.UTF-8 LANGUAGE=en konsole`，桌面其它部分仍然是中文。

### 虚拟键盘（plasma-keyboard）

键盘语言不是跟着 `LANG` 走的：`~/.config/plasmakeyboardrc`

```ini
[General]
enabledLocales=en_US
```

`plasma-keyboard` 里的逻辑是「`enabledLocales` 空 → `activeLocales = [当前系统语言]`」，
所以中文机器上默认只有拼音键盘、没有英文。

**别图省事写成 `en_US,zh_CN`**：Qt Virtual Keyboard 的拼音插件
（`Plugins/Pinyin/libqtvkbpinyinplugin.so`）是有的，但 `/usr/share/qt6/virtualkeyboard`
那套词典数据没装，`zh_CN` 会被判成不可用 locale，结果是**键盘整个不显示**
（journal 里只有一句 `Input method is trying to show itself but without a context`）。
真要中文输入得先补词典，或者走 fcitx5 + qt6 IM module。

配套：

- `pacman -S hunspell-en_US`：英文候选词/纠错，缺了只 warning，不影响出键盘
- `kwinrc` 里 `[Wayland] InputMethod=/usr/bin/plasma-keyboard`：让 KWin 自己拉起键盘面板
- 键盘是按需启动的；改了配置要么重开一次会话，要么点一个输入框让它重启

### 锁屏 PIN

Plasma Mobile 的锁屏走 `kscreenlocker` + PAM，**认的就是账户密码**，没有单独的 PIN
（`/etc/pam.d/` 下没有 `kscreenlocker` 条目 → 用默认 `system-login`）。所以：

- PIN = `colorgarden` 的登录密码（本机是纯数字，正好能打在数字键盘上）
- 想改：`passwd colorgarden`；改完锁屏、sudo、SSH 一起变

## 9. 还没做的

- 没有虚拟键盘自动弹出（`plasma-keyboard` 已装，但 Plasma Mobile 的输入法面板
  要在设置里挑一次；触摸-only 时建议先开“显示虚拟键盘”）
- 没有 GPU 过热降频（内核没接 cooling device，见 `docs/GPU.md`）
- 没有音频（`va_macro` 还缺 clock，见 `deferred` 列表）
- 没有重力/自动旋转（`qcom,sm8250` 的 imu 还没接）
- WiFi 能用但 `iwd` 需手动 `iwctl station wlan0 connect`
