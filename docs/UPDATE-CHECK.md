# moo-RDM 检查更新

> 本文保留客户端行为与历史联调记录；旧版本数字不代表当前线上版本。实际版本、构建号和产物以本仓 manifest、[BUILD.md](BUILD.md) 及 Cloud 回读为准。

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

<a id="cloud-release"></a>

## Cloud 发布与仓库身份

- 本仓身份见 [`.moo-cloud.json`](../.moo-cloud.json)：项目 `moo-projects`，软件 `moo-rdm`。
- App marker 仅保留 `role`、`project`、`product`、`platforms`、`verify`。它供 CLI `preflight` 校验归属与本地指纹，不是构建清单、发布凭证或 MCP 连接配置；不在其中填写版本、包哈希或 Token。配置解释见 [CLI 文档](../../moo-cloud-cli/README.md#73-软件仓库-markerapp--桌面--web)。
- 构建入口和签名要求见 [BUILD.md](BUILD.md)；Cloud 创建软件、发布版本、安装包来源、首选包及回滚统一按 [软件发版手册](../../moo-scaffold-cloud/docs/RELEASE-PLAYBOOK.md#4-cloud-后台操作步骤)。
- 本仓只发布 `macos / universal / dmg`；客户端上报 arm64 或 x64，由服务端回退到 universal。
- 保持已批准的版本与构建号；Cloud 填安装包实际值。若分发平台要求提高 build 号，先取得用户对具体值的同意，不能由发版动作自动递增。
- 平台管理员一次配置默认安装包存储，发布者沿用「上传文件」。默认七牛时浏览器直接上传到七牛，Cloud 核验大小和 SHA-256；看到「上传与校验完成」后才保存草稿。客户端和 `.moo-cloud.json` 不增加七牛 AK/SK 或存储字段。
- 上传完成但确认失败时先点重试确认，不必重复上传；取消后可重新选择同一文件续传，凭证过期则按提示重新选文件。具体步骤见统一手册第 4.2 节。
- 保存草稿并逐行核对后再发布，按本仓实际平台/架构调用更新接口。下载使用响应中原样返回的 `download.url`：七牛包为 Cloud 固定入口 `/downloads/releases/...`，既有本地包仍可为 `/storage/releases/...`；不要拼接路径或持久保存临时七牛签名地址。实际下载需跟随重定向（如 `curl -fL`），将下载文件的字节数与 SHA-256 同时对照本地产物和接口字段。
