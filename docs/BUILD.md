# 构建与产物

## 1. 环境

- macOS + Xcode Command Line Tools / Swift
- 版本三处必须一致：
  - `build.sh` `VERSION` / `BUILD`
  - `Sources/Core/AppInfo.swift`
  - `Resources/Info.plist`

## 2. 构建

```bash
cd /Volumes/dev/wwwroot/moo-RDM
./build.sh --universal
./build.sh --install
```

- universal 同时包含 arm64 / x86_64。
- 产物：`build/RDM-ARM-<version>-universal.dmg`、`build/RDM-ARM.app`。

## 3. 最近构建

- 日期：2026-11-04
- 版本：1.4.3（build 9）
- 文件：`build/RDM-ARM-1.4.3-universal.dmg`
- 大小：2,797,230 字节
- SHA-256：`3a4de370ad4a6a24b68974d11acab75da115ec21e7abeeeddecfc1423dc2533c`
- 架构：x86_64 arm64

## 4. 验证

```bash
hdiutil verify build/RDM-ARM-1.4.3-universal.dmg
codesign --verify --deep --strict build/RDM-ARM.app
RDM_UPDATE_BASE_URL=https://c.mooeen.com \
  build/RDM-ARM.app/Contents/MacOS/RDM-ARM --check-update
```

## 5. 发布

- 上传 dmg 到 cloud，平台 `macos`、架构 `universal`、格式 `dmg`。
- 核对接口返回的版本、大小、SHA-256。
