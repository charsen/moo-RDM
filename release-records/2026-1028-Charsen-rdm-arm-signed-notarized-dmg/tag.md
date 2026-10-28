# RDM-ARM 1.2.2 —— 首个签名并公证的版本，交付物改为 DMG

状态：**双源已发布**。`origin`（Gitee）与 `github` 的分支、tag、Release 与附件一致。

## 起因

1.2.1 已经发布过，但它的产物是 **ad-hoc 签名 + 未公证** 的 zip。别人下载后第一次打开会被
Gatekeeper 拦下，提示「已损坏」或「无法验证开发者」，安装说明里还得教用户跑一句
`xattr -dr com.apple.quarantine`——一个显示器工具不该要求用户先绕过系统安全机制才能用。

这一版把三件事一次做完：**Developer ID 签名、Apple 公证、交付物换成 DMG**。

版本号必须换：1.2.1 的包已经发出去了，重新签名后同名不同字节会让老 release 的校验和失效。

## 改了什么

| 位置 | 变化 |
| --- | --- |
| `build.sh` | 新增磁盘映像步骤：stage（App + `应用程序` 软链 + 安装说明）→ `hdiutil` UDZO → 签 DMG → 公证 → staple → `SHA256SUMS` |
| `build.sh` | 版本 1.2.1 → 1.2.2；`CFBundleVersion` 同步递增 |
| `build.sh` | `--help` 的注释区间从写死的 `2,21p` 改成按 `set -euo pipefail` 定位，加注释不会再被静默截断 |
| `Tools/package-release.sh` | 从「打 zip」改成薄封装：调 `build.sh`、断言 universal 与版本一致、报告 sha256。原来那份 stage/zip 逻辑与 `build.sh` 重复，删掉 |
| `.github/workflows/build.yml` | 产物上传路径与 artifact 名改 `.dmg` |
| `Sources/Core/AppInfo.swift` | `version` → 1.2.2；`bundleIdentifier` 从 `io.rdmarm.RDM-ARM` 改为 `com.mooeen.rdm`（改包名那轮漏了它） |
| `Resources/Info.plist` | 版本 1.2.2；键被 PlistBuddy 按字母重排，内容等价 |

### 为什么 DMG 的公证顺序不能反

先公证并 staple `.app`，再打 DMG，最后对 DMG 自己再签一次、再公证一次。

Gatekeeper 评估 DMG 是在**用户双击映像那一刻**发生的。一个装在未公证映像里的、
本身已经 staple 过的 app，在那一步照样会弹「无法验证开发者」。反过来只公证 App 不公证 DMG，
用户会以为包坏了。

### 安装说明为什么跟着搬进 DMG

原来它躺在 zip 里。zip 被去掉后，那段说明会一起消失——而其中「本应用没有主窗口，
它是菜单栏应用，打开后请看屏幕顶部菜单栏」是「装了没反应」这类反馈的唯一解释。
所以它搬进了 DMG，同时把「没有签名与公证、请跑 xattr」那段改成按是否公证条件输出：
对已公证的包教用户绕过 Gatekeeper 是有害的。

清理偏好设置那条命令也顺手修了，之前还写着 `io.rdmarm.RDM-ARM`。

## 验证

- `codesign --verify --strict` 通过；`stapler validate` 对 DMG 与包内 `.app` 都通过
  （挂载后验的是包内副本，证明票据随包走）。
- `spctl -a -vv -t open --context context:primary-signature` → `source=Notarized Developer ID`。
- 包内 `Info.plist`：1.2.2 / build 1.2.2 / `com.mooeen.rdm`；`lipo` 确认 `x86_64 arm64`。
- 硬化运行时下实跑 `--version` 与 `-ld`（走 DisplayServices 私有路径读真实显示器），均正常。
  Apple 自己签的私有框架不受库校验限制，不需要额外 entitlement。
- `Tools/package-release.sh --no-build` 对已出产物复验通过：universal + 版本一致 + sha256。

## 未验证 / 已知边界

- **没有跨机验收。** 构建机的 Gatekeeper 评估是关闭的（`spctl` 输出里
  `override=security disabled`），本机 `accepted` 只能证明票据存在。
- Developer ID 证书有效期到 **2027-02-01**（被 Apple 的 Developer ID CA 根证书卡住，
  不是一年）。到期前要换证书并重新公证。

## 发布物

| 项 | 值 |
| --- | --- |
| 文件 | `RDM-ARM-1.2.2-universal.dmg` |
| 大小 | 2,409,658 B |
| sha256 | `7c02f47cb87e5041ad6004abe74637513c797f3682a06c390dcccce05063bc86` |
| 架构 | x86_64 + arm64 |
| 签名 | Developer ID Application: Charsen Fung (S967RUU99W) |
| 公证 | 已公证，App 与 DMG 均已 staple |

包内：`RDM-ARM.app`、`应用程序`（软链）、`安装说明.txt`。

> Gitee 侧每个 Release 还会自动附带源码包（`1.2.2.zip` / `1.2.2.tar.gz`），
> 那是平台行为，不是我们传的，比对哈希时不算进来。
