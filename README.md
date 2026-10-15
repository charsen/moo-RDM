# RDM-ARM

**让 macOS 显示器跑出它真正支持的任何分辨率。**

RDM-ARM 是 [avibrazil/RDM](https://github.com/avibrazil/RDM) 的原生 Apple 芯片重写版。原版已经停止维护，在新版 macOS 上只能"凑合能用"——分辨率能列出来，但刷新率和色彩深度是错的。这个重写版换掉了失效的实现方式，恢复完整功能，并补上了原版没有的快捷键、配置文件和屏幕热插拔记忆。

- 原生 **arm64**，不需要 Rosetta
- **不需要 Xcode**，只要装了 Command Line Tools 就能构建
- **不需要关闭 SIP**，不需要任何特殊权限
- 显示引擎**只用公开 API**，系统升级不会再次失效

---

## 为什么原版会失效

这是重写版存在的根本原因，也决定了它的架构。

原版通过 CoreGraphics 的私有 SPI 读取显示模式：`CGSGetNumberOfDisplayModes`、`CGSGetDisplayModeDescriptionOfLength`、`CGSConfigureDisplayMode`。这些函数在 macOS 27 上**依然存在**，所以原版还能启动——但原版硬编码的结构体长度已经对不上现在的真实内存布局。

具体地说，原版假定模式结构体长 `0xD4`（212 字节），并按固定偏移取字段。实测解码结果：

| 字段 | 原版偏移 | macOS 27 实际读出 | 结论 |
|---|---|---|---|
| `mode` | `0x00` | 与公开 API 的 id 一致 | 正确 |
| `width` / `height` | `0x08` / `0x0C` | 正确 | 正确 |
| `density` | `0xD0` | 1.00 / 2.00 | 正确 |
| `depth` | `0x10` | 恒为 `8` | **错误** |
| `freq` | `0xBC` | 恒为 `0` | **错误** |

所以菜单里分辨率是准的，但刷新率全都不显示、色深也不对。这不是"不支持 ARM"，而是**私有结构体布局过期**——去修私有偏移只能治一时，下次系统升级还会再坏一次。

## 解决方案：只用公开 API

重写版不再碰私有结构体，改用公开的 `CGDisplayCopyAllDisplayModes`，并打开一个关键选项：

```swift
CGDisplayCopyAllDisplayModes(display, [
    kCGDisplayShowDuplicateLowResolutionModes: true
] as CFDictionary)
```

这个选项会让 CoreGraphics 返回它平时隐藏的 HiDPI 模式——也就是 RDM 里那个 ⚡️ 标记的全部价值所在。

在你机器上（BenQ PD2705U，原生 3840 × 2160）实测：

| 取法 | 返回模式数 |
|---|---|
| 不带选项（macOS 默认可见） | 120 |
| **带选项** | **257**（其中 137 个 HiDPI） |
| 私有 API | 290 |

公开 API 覆盖了 257 个，和私有 API 只差约 33 个边缘低分模式——用这点差距换来"系统升级不再失效"，非常划算。

---

## 功能

### 菜单栏

- 每块屏幕一个子菜单，顶部显示当前模式与原生分辨率
- 分辨率列表：宽的在前，HiDPI 排在标准前面，**⚡️ 标记 HiDPI**
- 同一分辨率有多个刷新率时自动折叠成二级子菜单
- 当前模式打勾
- 自动去重——macOS 会为"看起来完全一样"的模式返回多个不同 mode ID，原版会把 `60 Hz` 重复列四遍，重写版每个几何 + 刷新率只出现一次

### 增强功能（原版没有）

| 功能 | 说明 |
|---|---|
| **全局快捷键** | 下一个 / 上一个分辨率、切换只看 HiDPI、按配置文件切换 |
| **每屏模式记忆** | 记住每块屏幕用的模式，重插后自动恢复 |
| **热插拔监听** | `CGDisplayRegisterReconfigurationCallback`，显示器插拔时菜单自动更新 |
| **配置文件** | 多屏布局存成 JSON，可导入导出 |
| **旋转** | 0° / 90° / 180° / 270°，能力探测驱动 |
| **亮度** | 仅在支持的显示器上出现 |

### 命令行

保留原版的 `-w` / `-h` / `-s` / `-d` / `-lm` / `-ld`，并扩展了旋转、JSON 输出和配置文件：

```bash
rdm-arm -ld                        # 列出已连接的显示器
rdm-arm -lm                        # 列出全部可用模式
rdm-arm -lm --json | jq .          # 机器可读输出
rdm-arm -w 1920 -h 1080 -s 2       # 切到 1920×1080 HiDPI
rdm-arm -w 2304 -h 1296 -s 2 -r 60 # 指定刷新率
rdm-arm --rotation 90              # 旋转 90°
rdm-arm --save desk                # 保存当前布局
rdm-arm --apply desk               # 恢复布局
rdm-arm --selftest                 # GUI 自检：菜单栏图标位置 + 菜单结构
```

`--selftest` 值得单独说一句：菜单栏图标是否真的显示出来，**无法从进程外部验证**——`CGWindowListCopyWindowInfo` 不枚举菜单栏项，截屏又需要录屏权限。所以自检从进程内部报告窗口服务器实际把图标放在了哪里，是唯一可靠的办法。

---

## 构建

只要装了 Command Line Tools：

```bash
xcode-select --install   # 如果还没装
git clone <this-repo> && cd moo-RDM
./build.sh
```

产物在 `build/RDM-ARM.app`。

```bash
./build.sh --universal   # arm64 + x86_64 通用二进制
./build.sh --install     # 构建并复制到 /Applications
./build.sh --run         # 构建并启动
./build.sh --clean       # 清理
```

构建脚本不依赖 Swift Package Manager、CocoaPods 或 Xcode.app——直接用 `swiftc` 编译，再手工组装 `.app` bundle 并做 ad-hoc 签名。

> **关于 SwiftUI**：项目**不使用 SwiftUI**。Command Line Tools 自带 `libSwiftMacros.dylib`，但**不带 SwiftUI 的宏插件**，所以 `@State` / `@Binding` 这类属性包装器在只有 CLT 的环境下无法编译。设置窗口因此用纯 AppKit 实现——这是为了让"不需要 Xcode"这个承诺真正成立。

---

## 能力矩阵

在你机器上（macOS 27.0.1 / arm64 / BenQ PD2705U）的实测结果：

| 功能 | 底层 API | 实测 | 性质 |
|---|---|---|---|
| 枚举模式（含 HiDPI） | `CGDisplayCopyAllDisplayModes` | 120 → **257** | 公开 |
| 应用模式 | `CGConfigureDisplayWithDisplayMode` | 返回 `kCGErrorSuccess` | 公开 |
| 热插拔监听 | `CGDisplayRegisterReconfigurationCallback` | 可用 | 公开 |
| 旋转读取 | `CGDisplayRotation` | 可用 | 公开 |
| **旋转设置** | `SLSSetDisplayRotation` | **90° 实测生效并还原** | **私有** |
| 亮度 | `DisplayServicesGet/SetBrightness` | 外接屏不支持，自动隐藏 | 私有 |

**关于旋转**：`SLSSetDisplayRotation` 是私有符号，但它是**运行时动态解析**的，签名经实测确认为 `SLSSetDisplayRotation(CGDirectDisplayID, uint32_t)`（两参数形式返回成功，三参数形式返回失败）。如果将来这个符号消失，旋转菜单会**自动隐藏**，其余功能不受影响——不会崩溃。

亮度同理：`DisplayServicesCanChangeBrightness` 在外接屏上返回 0，此时亮度菜单直接不出现，而不是显示一个点不动的死控件。

---

## 项目结构

```
Sources/
  Core/         显示引擎（纯公开 API）
    DisplayMode.swift        模式模型：几何、HiDPI 判定、标志位、去重、排序
    DisplayManager.swift     枚举屏幕与模式
    ModeController.swift     应用模式、分辨率步进
    DisplayIdentity.swift    稳定的屏幕标识（跨重插识别同一块屏）
    Localization.swift       中英双语字符串
    AppInfo.swift            版本信息与诊断输出
  Optional/     私有 API，全部隔离在这里
    PrivateSymbolLoader.swift        运行时符号解析
    DisplayRotationController.swift  旋转（能力探测）
    DisplayBrightnessController.swift 亮度（能力探测）
  Features/
    HotKeyCenter.swift            Carbon 全局快捷键
    HotKeyAction.swift            快捷键动作定义
    ModeMemoryController.swift    每屏记忆 + 热插拔恢复
    Preferences.swift             偏好设置持久化
    ProfileStore.swift            配置文件导入导出
  UI/
    AppDelegate.swift         菜单栏生命周期
    StatusMenuBuilder.swift   菜单构建
    MenuActionRouter.swift    菜单动作分发
    SettingsWindow.swift      设置窗口（AppKit）
    GUISelfTest.swift         --selftest 诊断
  CLI/
    CommandLineRunner.swift   命令行界面
Tools/
  MakeIcon.swift              用 CoreGraphics 程序化生成应用图标
```

设计上有一条清晰的边界：**私有 API 只存在于 `Sources/Optional/`**。删掉这个目录，其余代码依然能编译运行，只是少了旋转功能。这个边界是为了让"哪里可能随系统升级失效"这个问题有一个明确、可审计的答案。

---

## 已知限制

- **亮度控制**在外接显示器上不可用（需要 DDC/CI 通路，这台 BenQ 没有暴露）。内置屏应该正常。
- 比私有 API 少约 **33 个边缘低分模式**（290 → 257）。这是换取系统升级稳定性的代价。
- 只做了 **ad-hoc 签名**，没有 Apple 开发者签名和公证。首次打开可能需要在"系统设置 → 隐私与安全性"里放行。
- 部署目标 **macOS 13.0**。旋转依赖的私有符号在更早的系统上可能不存在，此时会自动隐藏旋转菜单。
- 多屏镜像（mirroring）状态下部分模式不可用，这是 macOS 本身的限制。

---

## 与上游的关系

RDM 由 [Avi Alkalay](https://github.com/avibrazil/RDM) 开发，是 macOS 分辨率解锁工具的经典实现。这个项目**不是 fork**——没有复用它的代码，而是重新实现的：原版是 Objective-C++ 加私有 SPI，重写版是 Swift 加公开 API。

上游仓库没有附任何正式许可证文件，README 中作者表示"作者们会乐意你自由使用"。本重写版按原样（as-is）提供，供个人使用。

`⚡️` 这个 HiDPI 标记沿用自原版，作为对它的致意。
