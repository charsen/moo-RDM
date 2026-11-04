# moo-RDM 检查更新

## 1. 身份

- 产品：`moo-rdm`
- 仓库：moo-RDM（Swift/AppKit，仅 macOS）
- 当前版本来源：`Resources/Info.plist` 的 `CFBundleShortVersionString`
- 客户端入口：`Sources/Core/UpdateChecker.swift`；展示：`Sources/UI/UpdatePresenter.swift`

## 2. 支持矩阵

| 平台 | 架构 | 格式 | 发行方式 | 当前状态 |
| --- | --- | --- | --- | --- |
| macOS | universal（覆盖 arm64/x64） | dmg | 直装 | 1.4.3 已发布 |
| Windows | — | — | — | 不支持 |
| Linux | — | — | — | 不支持 |

客户端实际发送 `platform=macos`、`arch=AppInfo.architecture`（arm64 或 x64）。服务端命中的是 `macos/universal/dmg`，精确架构会回退到 universal。

## 3. 手动检查

三个入口共用 `UpdatePresenter.present()`：

- 设置窗口「更新」Tab；
- 状态栏菜单「检查更新」；
- 应用菜单「检查更新」。

## 4. 自动检查

- 触发：应用启动 5 秒后；
- 间隔：3 天（`UpdatePresenter.UpdateCheckStore.interval`）；
- 时间存储：UserDefaults `lastUpdateCheckAt`；
- 只在发现新版本时提示；已最新/失败静默；
- 检查失败不写时间，下次启动重试。

## 5. install_id

- 存储：UserDefaults `installId`；
- 首次启动生成 UUID；
- 只用于测试组、检查日志和后台备注。

## 6. 版本与发布

- 发布 universal dmg；不拆分 arm64/x64 两个包。
- 版本号取 `Resources/Info.plist`，发布时同步 `build.sh` 的 `VERSION`。
- 后台版本只挂 `macos/universal/dmg`，不要挂 Windows/Linux 包。

## 7. 已知边界

- 本应用只支持 macOS，不因后台矩阵缺 Windows/Linux 而报缺陷。
- 状态菜单、应用菜单、设置页三处入口必须同时保留同一 presenter，避免行为分叉。

## 8. 验证

```bash
./build.sh
RDM_UPDATE_BASE_URL=https://c.mooeen.com \
  ./build/RDM-ARM.app/Contents/MacOS/RDM-ARM --check-update
```

期望当前 1.4.3 输出 `up to date: 1.4.3`。
