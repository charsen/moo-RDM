# 构建与产物

Cloud 发布与本仓身份见 [UPDATE-CHECK.md 的 Cloud 发布](UPDATE-CHECK.md#cloud-release)，统一后台步骤见 [软件发版手册](../../moo-scaffold-cloud/docs/RELEASE-PLAYBOOK.md#4-cloud-后台操作步骤)。本页保留构建命令、签名要求和实际产物记录；发版不自动递增任何版本或构建号。

## 1. 环境

- macOS + Xcode Command Line Tools / Swift
- 版本三处必须一致：
  - `build.sh` `VERSION` / `BUILD`
  - `Sources/Core/AppInfo.swift`
  - `Resources/Info.plist`

## 2. 构建

```bash
cd <repo-root>
./build.sh --universal
./build.sh --install
```

- universal 同时包含 arm64 / x86_64。
- 产物：`build/RDM-ARM-<version>-universal.dmg`、`build/RDM-ARM.app`。

## 反馈 Token

Token 来源：开发机 `/Volumes/dev/build_tokens` 中的 `RDM-ARM moo-RDM 反馈 token`。明文只用于构建，不提交、不复制到仓库。

云端反馈接口的 `feedback` Token 只在构建时注入，**不提交到仓库**：

```bash
RDM_FEEDBACK_TOKEN_FILE=/secure/path/rdm-feedback-token \
  MOO_RDM_NOTARIZE=1 MOO_RDM_NOTARY_PROFILE=moo ./build.sh --universal
```

也支持直接 `RDM_FEEDBACK_TOKEN=...`，但不要把 Token 写进脚本、README、Info.plist 模板或 Git。
没有注入 Token 的包只能用于 `feedback_token_required=false` 的过渡期；云端开启强制 Token 后必须重新构建。

## 3. 最近构建

- 日期：2026-11-04
- 版本：1.4.6（build 12）
- 文件：`build/RDM-ARM-1.4.6-universal.dmg`
- 大小：2,796,510 字节
- SHA-256：`4e8b3adc67e57eb94e7ea1f5afec0aa426ed261dd58e37d1b5bd76fd3be09cf6`
- 架构：x86_64 arm64

## 4. 验证

```bash
hdiutil verify build/RDM-ARM-1.4.6-universal.dmg
codesign --verify --deep --strict build/RDM-ARM.app
RDM_UPDATE_BASE_URL=https://c.mooeen.com \
  build/RDM-ARM.app/Contents/MacOS/RDM-ARM --check-update
```

## 5. 发布

- 上传 dmg 到 cloud，平台 `macos`、架构 `universal`、格式 `dmg`。
- 核对接口返回的版本、大小、SHA-256。

`spctl -a -vv -t install build/RDM-ARM-1.4.6-universal.dmg` 必须为 accepted，`xcrun stapler validate` 必须通过；未公证不得发布。
