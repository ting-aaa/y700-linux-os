# 浏览器相机方向更新

`y700-camera-pipewire 1.4.2-1+y700.5` 随内屏的实际方向更新浏览器摄像头帧的旋转信息。桌面登录时，Xfce 自动启动 `y700-camera-orientation` 读取内屏 DSI-1 的 RandR 方向。相机权限继续由站点和桌面门户控制。完整浏览器自动化使用虚拟镜头。机主已确认日用机的真实后置主摄在独立的 Y700 相机应用中方向正常。[浏览器测试](../tests/camera-browser-orientation/session.sh) · [相机应用方向](CAMERA-ORIENTATION.md)

## 日用机

日用 dev12.11 已从 `.4` 升至 `.5`。1,241 个软件包中只有 `y700-camera-pipewire` 发生变化，完整元组摘要为 `a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb`。方向监听器读到内屏向左横放，8 字节的状态文件归桌面用户所有，权限为 `0600`。在所有音视频节点和链接均空闲时重新启动 WirePlumber，三路摄像头均重新出现。前后核对了原有客户端、门户权限、桌面、网络和服务。扬声器左右声道均为 22282（34%），静音保持关闭。安装与状态记录位于 `out/browser-camera-orientation/{physical-install,physical-runtime,physical-source-owner}.log`。

安装当时，旧 PipeWire 核心仍映射 `.4`。11 月 22 日，平板重启并回到机主的正常 Xfce 会话后，再次核对两个服务的进程映射。PipeWire、WirePlumber 均已使用安装包中的 `.5` 库，库文件 SHA-256 为 `a7eab16363e28fd191944dd75e2aa6b37e0520ba2c05a47699b800ac83ae28d0`。三个物理摄像头源均由 `spa-node-factory` 提供，检查期间全部空闲。日用会话已启用修复；浏览器中实景画面的方向仍待验证。精简收据为 `out/browser-camera-orientation/physical-daily-relogin.log`。[日用会话检查](../tests/browser-camera-update/check-daily-owner.sh) · [PipeWire 节点工厂](https://github.com/PipeWire/pipewire/blob/1.4.2/src/modules/module-spa-node-factory.c)

板上另起的普通账户媒体会话直接使用已安装的插件。新建的 PipeWire 核心和 WirePlumber 均映射了 `.5`，并通过同一 `spa-node-factory` 建立了三个虚拟相机源。该验证使用隔离的进程、网络、IPC 和挂载命名空间，以及独立的总线与运行目录。三个源一直空闲，硬件设备没有传入。完整日志为 `out/browser-camera-orientation/physical-new-session.log`。[实板新会话验收](../tests/browser-camera-update/isolated-session.sh)

## 离线安装与回退

在参考机运行以下命令可检查已安装版本。要恢复原版，将最后的 `check` 换成 `rollback`。保存工作后完整退出并重新登录，以便让所选版本接管摄像头。更新程序保留本地配置改动。降级只清理内容与发行版匹配的过时自启动文件。

```sh
sudo bash /var/lib/y700/updates/browser-camera-orientation-y7005/update.sh check
```

用于其他兼容开发安装的离线包为 `y700-browser-camera-offline.tar`，122,880 字节，SHA-256 为 `7940b09dca5368da485310ca82a836fb02c0ad3c6a743160e2d6b06c1e541586`。解包后保留整个目录。运行 `sudo bash browser-camera-orientation-y7005/update.sh install` 升级，运行 `sudo bash browser-camera-orientation-y7005/update.sh rollback` 降级。新包的 SHA-256 为 `73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc`，原版为 `9de518b05da6d4fafc26a6a284dd30d484eb47801c947c814bcfa3fe772b3e52`。[组包脚本](../scripts/package-browser-camera.sh) · [离线更新脚本](../scripts/update-browser-camera.sh)
