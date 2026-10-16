# RDM-ARM

[Gitee 主仓](https://gitee.com/charsen/moo-RDM) · [GitHub 镜像](https://github.com/charsen/moo-RDM)

**让 macOS 显示器跑出它真正支持的任何分辨率。**

RDM-ARM 是 [avibrazil/RDM](https://github.com/avibrazil/RDM) 的原生 Apple 芯片重写版。原版已经停止维护，在新版 macOS 上只能"凑合能用"——分辨率能列出来，但刷新率和色彩深度是错的。这个重写版换掉了失效的实现方式，恢复完整功能，并补上了原版没有的屏幕热插拔记忆。

- 原生 **arm64**，不需要 Rosetta
- **不需要 Xcode**，只要装了 Command Line Tools 就能构建
- **不需要关闭 SIP**，不需要任何特殊权限
- 显示引擎**以公开 API 为底**：默认功能全部走公开 API；只有旋转、亮度和「隐藏 HiDPI 模式」会碰私有接口，且都隔离在 `Sources/Optional/`，设置里可一键关闭

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

## 解决方案：以公开 API 为底

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
| **带选项** | **257** |
| 私有 API | 290 |

这 257 个是公开接口能拿到的全部，但**不等于"全部模式"**。那多出来的 33 个并不是低分边角料——它们是 macOS 自己生成的**超采样 HiDPI 模式**：在 2560 × 1600 的面板上，1920 × 1200 的 HiDPI 会用 3840 × 2400 渲染、再缩回面板。公开枚举**一个都不返回**，而这正是原版 RDM 能列出、重写版曾经列不出来的那些分辨率（详见下面的「隐藏 HiDPI 模式」）。

所以现在的口径是：**公开 API 打底，私有模式表按需补充**。设置里「启用旋转、亮度与隐藏 HiDPI」打开时，`Sources/Optional/PrivateModeTable.swift` 会把公开枚举拿不到的模式并进菜单；关掉它，显示引擎就严格只走公开 API。

---

## 功能

### 菜单栏

- 每块屏幕一个子菜单，顶部显示当前模式与原生分辨率
- **选中即切换，立即生效**，不弹确认框
- **分辨率与刷新率是两个并列的子菜单**，各自独立选择
- **默认只列 HiDPI 模式**（带 ⚡️ 的），并且默认不列 macOS 标记为**不可用于桌面 GUI** 的模式——菜单一打开就是能放心选的。两个开关（标准分辨率 / 被标记的模式）都在菜单和设置里，想要就打开
- 分辨率列表：宽的在前，HiDPI 排在标准前面，**⚡️ 标记 HiDPI**
- macOS 藏起来的**超采样 HiDPI** 也能列出来（可选模块，见下）
- 当前模式打勾
- 自动去重——macOS 会为"看起来完全一样"的模式返回多个不同 mode ID，原版会把 `60 Hz` 重复列四遍，重写版每个几何 + 刷新率只出现一次

**关于分辨率与刷新率分开选**：早先是把刷新率嵌在每个分辨率下面当二级菜单，结果同一个分辨率出现四行，列表很难扫；只想改刷新率还得再钻一层。现在拆成两个并列菜单：

- **分辨率**只列几何尺寸，每个只出现一次。切换时**尽量保留你当前的刷新率**——目标分辨率如果没有这个刷新率，才退回它支持的最高值。
- **刷新率**只列**当前这个分辨率**支持的档位。把所有分辨率的刷新率混在一起，它就变成第二个分辨率菜单了。就算这块屏只有一档（比如 ARZOPA 只有 60 Hz），菜单也照常出现、把那一档打勾——藏起来会让人以为功能坏了，而只有一个勾选项恰好说明"这屏就这样"。

### 增强功能（原版没有）

| 功能 | 说明 |
|---|---|
| **每屏模式记忆** | 记住每块屏幕用的模式，重插后自动恢复 |
| **热插拔监听** | `CGDisplayRegisterReconfigurationCallback`，显示器插拔时菜单自动更新 |
| **旋转** | 0° / 90° / 180° / 270°，能力探测驱动 |
| **亮度** | 仅在支持的显示器上出现 |

### 隐藏 HiDPI 模式

macOS 生成的模式比它对公开 API 承认的更多。被藏起来的那批是**超采样 HiDPI**——面板像素不够时，系统仍然用比面板更大的背板渲染，再缩回去：

> 别和菜单里那个「显示 macOS 隐藏的模式」搞混：那个指的是 macOS 标记为**不可用于桌面 GUI** 的模式（能枚举到，只是它不想给你用）；这里说的是 macOS **根本不返回**、只在私有表里的模式。

| 显示器 | 公开枚举 | 私有表 | 多出来的 |
|---|---|---|---|
| ARZOPA（2560 × 1600） | 46 | 55 | 9 个，全是 2× |
| BenQ PD2705U（4K） | 257 | 290 | 33 个，全是 2× |

ARZOPA 多出来的 9 个是 `1920 × 1200`、`2048 × 1280`、`2560 × 1600`、`1600 × 1200`、`1600 × 1000`…全部带 ⚡️。原版 RDM 读的正是这张私有表，所以它能列出来、还能切过去。

打开设置里的「启用旋转、亮度与隐藏 HiDPI」后，这些模式会一并出现在菜单里，选择和切换与其它模式完全一样；**关掉开关就整体消失**，显示引擎回到纯公开 API。

取舍要说清楚：这张表的**记录结构 Apple 从未公开**，而且已经在悄悄变——macOS 27 上 `depth` 和 `refreshRate` 两个字段读出来就是垃圾值（所以这些模式拿不到刷新率，只能沿用同尺寸公开模式的刷新率）。RDM-ARM 因此只在读到的 `宽 / 高 / 缩放` 全部合理时才采信这张表，否则当它不存在，不会拿垃圾数据去拼分辨率。

### 命令行

保留原版的 `-w` / `-h` / `-s` / `-d` / `-lm` / `-ld`，并扩展了旋转和 JSON 输出：

```bash
rdm-arm -ld                        # 列出已连接的显示器
rdm-arm -lm                        # 列出全部可用模式
rdm-arm -lm --json | jq .          # 机器可读输出
rdm-arm -w 1920 -h 1080 -s 2       # 切到 1920×1080 HiDPI
rdm-arm -w 2304 -h 1296 -s 2 -r 60 # 指定刷新率
rdm-arm --rotation 90              # 旋转 90°
rdm-arm --selftest                 # GUI 自检：菜单栏图标位置 + 菜单结构
rdm-arm --selftest --roundtrip     # 自检并真实跑一遍「切换 → 还原」
```

`--selftest` 值得单独说一句：菜单栏图标是否真的显示出来，**无法从进程外部验证**——`CGWindowListCopyWindowInfo` 不枚举菜单栏项，截屏又需要录屏权限。所以自检从进程内部报告窗口服务器实际把图标放在了哪里，是唯一可靠的办法。加上 `--roundtrip` 后会真的切换一次分辨率再还原，用来验证「切换 → 还原」这条链路确实通。

---

## 安装（直接下载）

不想自己编译的话，从 [Releases](../../releases) 下载 `RDM-ARM-<版本>-universal.zip`，
解压后把 `RDM-ARM.app` 拖进「应用程序」。

**首次打开前必须做一件事。** 本应用只有 ad-hoc 签名（没有 Apple 开发者签名与公证），
macOS 会拦下它并提示「已损坏」或「无法验证开发者」——这是预期的，不是文件真的坏了。
在「终端」里执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/RDM-ARM.app
```

**它是菜单栏应用，没有主窗口。** 打开后请看屏幕**顶部菜单栏**，会多出一个显示器图标。
如果菜单栏图标太多看不到，在菜单栏空白处按住 Command 再拖动可以调整顺序。

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

./Tools/package-release.sh          # 构建并打包成可发布的 zip（含安装说明 + SHA-256）
./Tools/package-release.sh --no-build   # 复用已有产物重新打包
```

构建脚本不依赖 Swift Package Manager、CocoaPods 或 Xcode.app——直接用 `swiftc` 编译，再手工组装 `.app` bundle 并做 ad-hoc 签名。

CI（`.github/workflows/build.yml`）在干净的 macOS runner 上验证通用构建、bundle 结构、
两个架构切片都在、版本号与 `AppInfo.swift` 一致、CLI 冒烟，并产出 zip。
**它不跑 GUI** —— 菜单栏图标无法从进程外验证，runner 也没有显示器；GUI 用 `--selftest` 手工验。

> 注意 `build.sh` 的 `VERSION` 与 `Sources/Core/AppInfo.swift` 的 `version` 必须一致，
> 构建脚本会核对，不一致直接报错退出。

> **关于 SwiftUI**：项目**不使用 SwiftUI**。Command Line Tools 自带 `libSwiftMacros.dylib`，但**不带 SwiftUI 的宏插件**，所以 `@State` / `@Binding` 这类属性包装器在只有 CLT 的环境下无法编译。设置窗口因此用纯 AppKit 实现——这是为了让"不需要 Xcode"这个承诺真正成立。

---

## 能力矩阵

在你机器上（macOS 27.0.1 / arm64 / BenQ PD2705U）的实测结果：

| 功能 | 底层 API | 实测 | 性质 |
|---|---|---|---|
| 枚举模式（含 HiDPI） | `CGDisplayCopyAllDisplayModes` | 120 → **257** | 公开 |
| 应用模式 | `CGConfigureDisplayWithDisplayMode` | 返回 `kCGErrorSuccess` | 公开 |
| **隐藏 HiDPI 模式** | `CGSGetNumberOfDisplayModes` / `CGSConfigureDisplayMode` | ARZOPA 公开 46 → **55**；`1920 × 1200 ⚡️` 实测生效并还原 | **私有**（可选模块） |
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
  Core/         显示引擎（公开 API 为主）
    DisplayMode.swift        模式模型：几何、HiDPI 判定、标志位、去重、排序
    DisplayManager.swift     枚举屏幕与模式（并入隐藏 HiDPI）
    ModeController.swift     应用模式（公开路径；隐藏模式走私有调用）
    DisplayIdentity.swift    稳定的屏幕标识（跨重插识别同一块屏）
    Localization.swift       中英双语字符串
    AppInfo.swift            版本信息与诊断输出
  Optional/     私有 API，全部隔离在这里
    PrivateSymbolLoader.swift        运行时符号解析
    PrivateModeTable.swift           隐藏 HiDPI 模式（私有模式表）
    DisplayRotationController.swift  旋转（能力探测）
    DisplayBrightnessController.swift 亮度（能力探测）
  Features/
    ModeMemoryController.swift    每屏记忆 + 热插拔恢复
    Preferences.swift             偏好设置持久化
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

设计上有一条清晰的边界：**私有 API 只存在于 `Sources/Optional/`**。Core 引用私有的地方只有两处，而且都是显式的：`DisplayManager` 取隐藏模式、`ModeController` 应用隐藏模式，两边都会先确认符号存在、开关打开。想知道"哪里可能随系统升级失效"，只看这个目录就够了。

---

## 已知限制

- **亮度控制**在外接显示器上不可用（需要 DDC/CI 通路，这台 BenQ 没有暴露）。内置屏应该正常。
- **隐藏 HiDPI 模式依赖私有模式表**：这张表的记录结构 Apple 从未公开，而且在变——macOS 27 上 `depth` / `refreshRate` 字段已经读不出正确值（所以这些模式没有独立刷新率，沿用同尺寸公开模式的值）。一旦偏移再变，`PrivateModeTable` 的自检会失败并整体停用，菜单里就只剩公开模式。
- 只做了 **ad-hoc 签名**，没有 Apple 开发者签名和公证。首次打开可能需要在"系统设置 → 隐私与安全性"里放行。
- 部署目标 **macOS 13.0**。旋转依赖的私有符号在更早的系统上可能不存在，此时会自动隐藏旋转菜单。
- 构建工具链**最低已验证到 Xcode 15.4 / Swift 5.10**（CI runner）。早期版本用过会失败的写法
  （`CGRect` 的 `Hashable` 合成）已修掉，但更老的工具链未做验证。
- **切换立即生效，没有确认框、也没有自动还原**。RDM 列出的模式里有一部分被 macOS 标记为不适合桌面 GUI；如果选中的模式显示器显示不出来，画面会变黑，而菜单栏恰好就在这块屏上。此时可以用键盘盲操作菜单退回安全模式（菜单里始终有「恢复系统默认」），或在终端用命令行改回来。
- 多屏镜像（mirroring）状态下部分模式不可用，这是 macOS 本身的限制。

---

## 与上游的关系

RDM 由 [Avi Alkalay](https://github.com/avibrazil/RDM) 开发，是 macOS 分辨率解锁工具的经典实现。这个项目**不是 fork**——没有复用它的代码，而是重新实现的：原版是 Objective-C++ 加私有 SPI，重写版是 Swift，以公开 API 为底，只把公开接口拿不到的那三件（旋转、亮度、隐藏 HiDPI 模式）交给可关闭的私有模块。

上游仓库没有附任何正式许可证文件，README 中作者表示"作者们会乐意你自由使用"。本重写版按原样（as-is）提供，供个人使用。

`⚡️` 这个 HiDPI 标记沿用自原版，作为对它的致意。
