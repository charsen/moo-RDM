# TODOS

## 检查更新 / 构建待办（2026-11-04）

- [ ] 在 Intel Mac 上安装 1.4.3 universal dmg，验证更新检查、下载和安装链路；本机只在 arm64 上验证过。


- [ ] 重新放出自定义缩放分辨率（菜单与 CLI 入口暂时隐藏；实现保留在 `CustomResolutionWindow` / `ScaleResolutionStore` / `DisplayOverrideInstaller`；重放前补管理员写入的真机验证与文档）
- [ ] 预设记录主屏指定（排列位置已记录；macOS 27 的 CoreGraphics 没有公开的主屏设置 API，探测的 `SLSSetMainDisplay` / `CGSSetMainDisplay` / `CoreDisplay_Display_SetMain` 等私有符号也不存在）
- [ ] 虚拟屏支持（`CGVirtualDisplay` + 硬件镜像，是在 Apple 芯片上补尺寸的另一条路线；需要屏生命周期、镜像与清理逻辑，成本较高）
