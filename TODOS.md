# TODOS

- [ ] 预设记录主屏指定（排列位置已记录；macOS 27 的 CoreGraphics 没有公开的主屏设置 API，探测的 `SLSSetMainDisplay` / `CGSSetMainDisplay` / `CoreDisplay_Display_SetMain` 等私有符号也不存在）
- [ ] 虚拟屏支持（`CGVirtualDisplay` + 硬件镜像，是在 Apple 芯片上补尺寸的另一条路线；需要屏生命周期、镜像与清理逻辑，成本较高）
