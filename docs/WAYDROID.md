# Waydroid on umi（mainline 6.12）

## 已完成

1. **内核**：`CONFIG_ANDROID_BINDER_IPC=y`、`CONFIG_ANDROID_BINDERFS=y`、
   `CONFIG_ANDROID_BINDER_DEVICES=""`（空：设备由 binderfs 动态创建）。
   binder 是 bool，不能编成模块，只能内建。

   两次刷入后“卡一屏”的失败，根因不是 binder，而是**从脏构建树 / 错误配置里编出来的内核**：
   一次是把 ARM64 VA/PA bits 误改成 52，另一次是链接阶段残留了 0 字节的
   `usr/initramfs_data.o`。最终做法是 **拿手机上 `/proc/config.gz` 当基线**、
   用独立输出目录 `O=out-wd` 干净重编，刷入后正常启动（约 110 秒进 SSH）。

2. **binderfs**：`mount -t binder binder /dev/binderfs` 成功，
   `/dev/binderfs/binder-control`、`features` 都在；dmesg 里有 binder transaction 记录。

3. **软件**：`waydroid` 1.6.3 + `waydroid-image`（LineageOS：system.img 1.9G / vendor.img 403M）
   + `waydroid-helper`；`waydroid init -f -i /usr/share/waydroid-extra/images` 完成，
   `/var/lib/waydroid/waydroid.cfg` 的 `images_path` 指向该目录。

4. **容器**：`waydroid-container.service` active；手工 `lxc-start -F` 能看到 Android
   `/init` 被 exec 起来（说明镜像与 LXC 配置本身可用）。

5. **Plasma Mobile 自带集成**：`plasma-mobile` 提供
   `waydroidintegrationplugin`（应用抽屉显示 Android 应用）、
   `kcm_waydroidintegration`（系统设置里的 KCM）、`waydroidhelper`（kauth helper）。

## 未完成 / 卡点

`waydroid session start` 显示 RUNNING，但 Android 用户态没起来：

```
waydroid app list  -> Failed to get service waydroidplatform（持续重试）
waydroid status    -> Container: STOPPED / IP address: UNKNOWN
```

即 Android 的 `servicemanager` 未就绪。下一步：

- `lxc-attach` 进容器 `ps -A`，看 servicemanager / zygote 是否在跑
- 检查 `/var/lib/waydroid/lxc/waydroid/config_nodes` 里的 binder 节点
  （anbox-binder / hwbinder / vndbinder）是否创建、容器内 `/dev/binder*` 能否打开
- `lxc-start -F -l TRACE` 抓 Android init 的早期输出
- 确认 archlinuxcn 的镜像（2026-09-27）与 `waydroid` 1.6.3 匹配

## 注意

`lxc.hook.post-stop = /dev/null` 会让 LXC 每次收尾报
`Script exited with status 126`，这是 waydroid 的已知噪音，不代表容器启动失败。
