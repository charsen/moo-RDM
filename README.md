# RDM-ARM

[Gitee 主仓](https://gitee.com/charsen/moo-RDM) · [GitHub 镜像](https://github.com/charsen/moo-RDM)

**让 macOS 显示器跑出它真正支持的任何分辨率。**

RDM-ARM 是 [avibrazil/RDM](https://github.com/avibrazil/RDM) 的原生 Apple 芯片重写版。原版已经停止维护，在新版 macOS 上只能"凑合能用"——分辨率能列出来，但刷新率和色彩深度是错的。这个重写版换掉了失效的实现方式，恢复完整功能，并补上了原版没有的屏幕热插拔记忆。

- 原生 **arm64**，不需要 Rosetta
- **不需要 Xcode**，只要装了 Command Line Tools 就能构建
- **不需要关闭 SIP**，不需要任何特殊权限
- 显示引擎**以公开 API 为底**：默认功能全部走公开 API；只有旋转、亮度、「隐藏 HiDPI 模式」和链路预算读取会碰私有接口，且都隔离在 `Sources/Optional/`，设置里可一键关闭；override 写入走公开文件路径，只需要一次管理员授权

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
- **默认只列 HiDPI 模式**（带 ⚡️ 的），并且默认不列 macOS 标记为**不可用于桌面 GUI** 的模式——菜单一打开就是能放心选的。两个开关（「仅显示 HiDPI 模式」/「显示 macOS 隐藏的模式」）都在菜单和设置里；前者并不让标准模式消失，只是把它们收进下一个子菜单
  - 标准模式**单独收在「标准分辨率（非 HiDPI）」子菜单里**，不混在主列表。它们和 HiDPI 条目只差一个 ⚡️，但一个是自己渲染、一个是显示器放大，混排时很难分辨。这个子菜单**始终存在**，不随当前刷新率变化——它一度只在"某个标准模式比同尺寸 HiDPI 更快"时才出现，结果用户在 30 Hz 下找到的 60 Hz 分组，一改成 60 Hz 就消失了（同尺寸 HiDPI 此时也有 60，标准不再"更快"）。要不要显示是显示器的属性，能不能更快是当前时序的属性，两者不该绑在一起。当前如果就停在某个标准模式上，打勾会落在这个子菜单标题上（主列表里没有任何一条是当前）
  - **模式表本身会随当前时序变化**：同一台电视在 30 Hz 下只报 30/25/24 的 HiDPI 模式，切到 60 Hz 后才多出一批 60 Hz HiDPI 小尺寸。所以菜单每次打开都重新读表，不能缓存——缓存下来的列表会和实际能设的模式对不上
  - **当前尺寸缺一档更高刷新率时，刷新率菜单底部会出现一条可直接点的跨界条目**，形如 `60 Hz @ 1920 × 1080`。点它会连分辨率一起切过去——刷新率和时序本来就是绑在一起的，把代价说在标题里比让用户自己去找更直接。只在目标尺寸不比当前小时才出现：拿 2304 × 1296 换 1024 × 768 的 75 Hz 不算"同一块屏更快"，那条留在标准子菜单里，不来刷屏
- 分辨率列表：宽的在前，HiDPI 排在标准前面，**⚡️ 标记 HiDPI**，每行后面跟着该尺寸**最快的刷新率**（`1920 × 1080 ⚡️ · 30 Hz`）。两个并列菜单的代价是：挑分辨率时刷新率不在视野里，于是很容易落到一个只有 30 Hz 的尺寸上，还以为面板做不到 60。把这个上限印在行内，哪条能 60 一眼就看得到；点这条也**一定落到行上写的那个刷新率**，否则标签就在骗人
- macOS 藏起来的**超采样 HiDPI** 也能列出来（可选模块，见下）
- 当前模式打勾
- 自动去重——macOS 会为"看起来完全一样"的模式返回多个不同 mode ID，原版会把 `60 Hz` 重复列四遍，重写版每个几何 + 刷新率只出现一次

**关于分辨率与刷新率分开选**：早先是把刷新率嵌在每个分辨率下面当二级菜单，结果同一个分辨率出现四行，列表很难扫；只想改刷新率还得再钻一层。现在拆成两个并列菜单：

- **分辨率**只列几何尺寸，每个只出现一次。切换时**尽量保留你当前的刷新率**——目标分辨率如果没有这个刷新率，才退回它支持的最高值。
- **刷新率**只列**当前这个分辨率**支持的档位。把所有分辨率的刷新率混在一起，它就变成第二个分辨率菜单了。就算这块屏只有一档（比如 ARZOPA 只有 60 Hz），菜单也照常出现、把那一档打勾——藏起来会让人以为功能坏了，而只有一个勾选项恰好说明"这屏就这样"。

### 增强功能（原版没有）

| 功能 | 说明 |
|---|---|
| **每屏模式记忆** | 记住每块屏幕用的模式，重插后自动恢复（现在连旋转一起恢复，启动时也会兑现；记错了可逐屏忘掉或清空全部；命令行切换同样写入记忆） |
| **热插拔监听** | `CGDisplayRegisterReconfigurationCallback`，显示器插拔时菜单自动更新 |
| **旋转** | 0° / 90° / 180° / 270°，能力探测驱动 |
| **亮度** | 仅在支持的显示器上出现 |
| **自定义缩放分辨率** | 菜单里给面板补 macOS 没列出的尺寸，写入 `/Library` override，重插后生效 |
| **所有显示器** | 同分辨率、与主屏一致、镜像/停止镜像，一次事务提交 |
| **显示配置预设** | 保存/一键应用整套分辨率、旋转、镜像与亮度；缺失显示器点名跳过 |

### 隐藏 HiDPI 模式

macOS 生成的模式比它对公开 API 承认的更多。被藏起来的那批是**超采样 HiDPI**——面板像素不够时，系统仍然用比面板更大的背板渲染，再缩回去：

> 别和菜单里那个「显示 macOS 隐藏的模式」搞混来源：那个开关放出来的是 macOS 标记为**不可用于桌面 GUI** 的模式（能枚举到，只是它不想给你用）；这里说的是 macOS **根本不返回**、只在私有表里的模式。两者都不在默认菜单里，由同一个开关把关——私有表的记录没有经过 CoreGraphics，也就没有可用性判定，默认混进菜单会给出点不动的行。

| 显示器 | 公开枚举 | 私有表 | 多出来的 |
|---|---|---|---|
| ARZOPA（2560 × 1600） | 46 | 55 | 9 个，全是 2× |
| BenQ PD2705U（4K） | 257 | 290 | 33 个，全是 2× |

ARZOPA 多出来的 9 个是 `1920 × 1200`、`2048 × 1280`、`2560 × 1600`、`1600 × 1200`、`1600 × 1000`…全部带 ⚡️。原版 RDM 读的正是这张私有表，所以它能列出来、还能切过去。

打开设置里的「启用旋转、亮度与隐藏 HiDPI」后，这些模式才读得到，选择和切换与其它模式完全一样；**关掉开关就整体消失**，显示引擎回到纯公开 API。读到了还要菜单愿意列：「显示 macOS 隐藏的模式」同时控制这一批和 macOS 标为不可用的那批，两个开关都开才看得到。这是刻意的——私有表不提供可用性判定，默认列出来就会出现「点下去报 CoreGraphics 1001」的行，用户分不清是显示器不支持还是软件坏了。

取舍要说清楚：这张表的**记录结构 Apple 从未公开**，而且已经在悄悄变——macOS 27 上 `depth` 和 `refreshRate` 两个字段读出来就是垃圾值（所以这些模式拿不到刷新率，只能沿用同尺寸公开模式的刷新率）。RDM-ARM 因此只在读到的 `宽 / 高 / 缩放` 全部合理时才采信这张表，否则当它不存在，不会拿垃圾数据去拼分辨率。

### 显示器之外的刷新率

菜单里的刷新率来自 macOS 的模式表。表里没有的档位，只有两条路能造出来：

| 路线 | 做法 | 在 Apple 芯片上 |
|---|---|---|
| 按属性合成模式 | 未声明但导出的 `CGDisplayModeCreate` + 公开的 `Width` / `Height` / `RefreshRate` 键 | **已废**：实测连"原样重建当前模式"都返回 `NULL` |
| 改写 EDID | 给面板的 EDID 塞一个 18 字节 detailed timing，写进系统 override 目录 | **`IODisplayEDID` 写入可用、读取不生效**：真机实测 macOS 27 在 Apple 芯片上仍枚举面板原厂 EDID。同一目录下的 `scale-resolutions` 会被读取，见下面的「自定义缩放分辨率」 |
| 私有实时注入 | 不落文件，直接把 EDID 推进显示管线 | BetterDisplay 在 Apple 芯片上用的就是这条；本机没有可用入口（详见下文） |

RDM-ARM 走第二条，但先把"能不能"算清楚再动手：

- `--edid` 输出面板自己声明的全部时序（基准 DTD + CEA 短格式）
- `--capabilities` 对三件事：EDID 声明了什么、系统给了什么、链路上限是多少
- `--refresh-audit` 指定一个刷新率，逐分辨率回答「这根线为什么拿不到」
- `--custom-timing` 合成时序，不加 `--write` 只算不写

#### 一个刷新率为什么拿不到：三种原因，只有两种能靠软件解决

「显示器之外的刷新率」经常被当成一个笼统的问题，实际有三种成因，修法完全不同：

| 现象 | 判定 | 能不能解决 |
|---|---|---|
| 面板在 EDID 里写了，macOS 没列出来 | `hidden by macOS` | 能，直接切（私有模式表已有该档位） |
| 面板没写，但链路带宽够 | `not declared` | 要合成新时序，Apple 芯片上做不到（见下文） |
| 链路带宽本来就不够 | `beyond link` | 不能。只能降分辨率或换线 |
| 链路预算读不到（非 Apple 面板、或可选模块关闭） | `unknown` | 判断不了。表格里那一行不会印 `ceiling`，只能看实际切换结果 |

`--refresh-audit` 就是对这三层做交叉比对。不指定 `-r` 时，默认审的是「面板声明的最高刷新率」——因为那才是大家真正想问的问题：

```
$ rdm-arm --refresh-audit
Display 0: BenQ PD2705U
    target         60 Hz — highest rate the panel declares
    budget         link 594 MHz · vendor range 50–76 Hz

    geometry      offered / declared / ceiling
    order         native → EDID-declared → area, largest first
    3840 × 2160   offered 60 50 30 25 24 · declared 60 50 29.97 25 24 · ceiling 67 Hz · → 60 Hz offered
      HiDPI   1600 × 1200 … 3840 × 2160 (9 point sizes) — all drive this timing
    1920 × 1080   offered 60 50 30 25 24 · declared 59.94 50 29.97 25 24 · ceiling 76 Hz · → 60 Hz offered

    verdict        available now at 3840 × 2160
```

指定一个够不着的档位，结论会直接点出卡在哪一层：

```
$ rdm-arm --refresh-audit -r 74
    verdict        within the link budget at 1920 × 1080, but the panel never declared it
                   rdm-arm --custom-timing 1920x1080@74 -d 0
                   (computes only — Apple silicon ignores an EDID override)

$ rdm-arm --refresh-audit -r 120
    verdict        no geometry reaches 120 Hz — the link tops out below it
                   best case 1920 × 1080 at about 76 Hz
```

**结论行永远先给「不用折腾」的那条。** 同一台机器 `-r 75` 的回答是：

```
    verdict        available now at 2048 × 1536
```

而不是「1920 × 1080 得合成时序」。因为 2048 × 1536（菜单里显示为 `1024 × 768 ⚡️`）本来就带着 75 Hz，只是不点 HiDPI 的人碰不到它。表格是按「面板支持程度」排的（原生 → 面板声明 → 面积），不是按尺寸，所以最省事的那行完全可能排在中段——结论行必须自己在「已经可用」的那些行里挑面积最大的，而不是拿表格第一行。

`--json` 给的是同一份结论，只是写给脚本看：

```json
{
  "target": 75,
  "targetSource": "requested",
  "verdict": "offered",
  "recommendation": {
    "kind": "available-now",
    "width": 2048, "height": 1536,
    "pointWidth": 1024, "pointHeight": 768
  },
  "budget": { "linkMaxPixelRate": 594000000, "minRefreshRate": 50, "maxRefreshRate": 76 }
}
```

（上面省略了 `version` / `architecture` / `display` 和完整的 `geometries` 数组；每行是 `width` / `height` / `pointSizes` / `offeredRates` / `declaredRates` / `ceiling` / `verdict`。）

字段口径：`verdict` ∈ `offered` / `hidden` / `synthesizable` / `unreachable` / `unknown`；`recommendation.kind` ∈ `available-now` / `mode-switch` / `custom-timing`（后两者带 `command`）；`computesOnly: true` 表示这条命令只算不写（Apple 芯片），脚本可以据此跳过。`geometries` 不截断——文本只印 8 行是终端可读性限制，不是数据限制。不适用于当前情形的键直接省略，不出现 `null`。

`--capabilities` 有同样的一份：`display` / `edid` / `nativeTiming` / `nativeCeiling` / `link` / `hiddenRates` / `override`（`installed`、`writable`，以及 `scaledResolutions` 字符串数组；`writable` 在 Apple 芯片上只对 `IODisplayEDID` 为 `false`）。`--edid` 则**没有** JSON 形式——EDID 本身是二进制，硬套 JSON 只是把 256 个字节写得更难用；带 `--json` 会直接报错并指向 `--emit-edid`，而不是假装接受然后照常打印文本表。

`unknown` 和 `unreachable` 是两件事，代码里分开：前者是**没量到**（面板不公布链路预算，一行都判不了），后者是**量到了，确实不够**。把前者说成「链路只到这儿」等于替面板编了一个它没给的数字。链路算出来的上限如果低于厂商自己声明的最低刷新率，也会如实报告为该上限，不会为了「看起来在范围内」抬到下限。


顺带解释一个几乎人人踩过的坑：**「我把分辨率调到 1080p 了，怎么还是 30 Hz」**。因为 HiDPI 的 `pixelWidth` 是显存里的 backing store，不是输出时序——1920 × 1080 的 HiDPI 模式实际是按 3840 × 2160 在输出，带宽也按 4K 算。审计表里每个分辨率下面那行 `HiDPI … — all drive this timing` 就是在说这件事：点尺寸换了，时序没换。

这也顺带说明为什么电视「30 帧 → 60 帧」要分情况看：能变 60 的，是链路本来够、只是描述或分辨率识别被卡住（4K60 8bit 4:2:0 与 4K30 4:4:4 的像素时钟几乎一样，HDMI 1.4 就够）；真变不了的，是面板或链路本身只到 30。至于虚拟屏镜像出来的「60 Hz」，改的是合成器的节奏，面板一秒还是只收到 30 个不同画面。

本机实测（BenQ PD2705U / M4 Max / macOS 27.0.1）：

| 项目 | 值 | 来源 |
|---|---|---|
| 原生时序 | 3840 × 2160 @ 59.997 Hz，533.25 MHz，totals 4000 × 2222 | EDID 基准 DTD |
| 链路上限 | 594 MHz 像素率 | `DisplayHints.MaxTotalPixelRate` |
| 厂商刷新范围 | 50–76 Hz | `DisplayAttributes.MaximumRefreshRate` |
| 4K 天花板 | **≈ 67 Hz** | 594 MHz ÷ (4000 × 2222) |

所以 4K@75 会被拒绝，理由不是"做不到"，而是"这条链路只够 67 Hz"，且报错里带数字：

```
$ rdm-arm --custom-timing 3840x2160@75
75 Hz 超出链路能力（约 67 Hz）
```

同一套算法下 4K@65 是可行的（577.72 MHz，仍在 594 MHz 预算内）。

写入是显式动作，并且**默认自己回滚**：

```bash
rdm-arm --custom-timing 3840x2160@65 --write          # 写 override，20 秒后自动回滚
rdm-arm --custom-timing 3840x2160@65 --write --keep   # 看着没问题，保留
rdm-arm --revert                                      # 随时撤掉
```

写入目标是 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9d1/DisplayProductID-8039`，内容就是系统自己那种三键 plist（`DisplayVendorID` / `DisplayProductID` / `IODisplayEDID`）。改 `/Library` 而不是 `/System`，所以**不需要关 SIP**，只要一次管理员授权。

**但在 Apple 芯片上这条 EDID 时序路线不成立。**这是真机测出来的，不是推测（注意范围：被忽略的是 `IODisplayEDID`；同一目录下的 `scale-resolutions` 仍然有效，见下一节）：

- override 写得进去，位置、权限、三键 plist、256 字节 EDID、块校验和全部正确；
- 系统读不到它——`ioreg` 里的实时 `EDID` 仍是面板原厂值，被改写的那一槽读回来是 `0.00 MHz`（写入值是 166.65 MHz）；
- 「文档里说要重载显示数据库」的三种触发全试过：拔插线缆、显示器休眠唤醒、整机睡眠唤醒（M4 Max 上确实睡满 12 秒）。模式表**始终 290 条，一条没变**。

所以 `--write` 在 Apple 芯片上会**直接拒绝**（退出码 3），不再弹管理员密码、不再假装写入后可能生效。时序仍然可算、可 `--emit-edid` 导出，只是交不到系统手里。想在将来某个系统版本上复验，设 `RDM_ALLOW_EDID_OVERRIDE=1` 即可绕过这道闸。

Apple 芯片上真正可行的是私有实时注入（BetterDisplay 走的那条），本机没有可用入口：`CoreDisplay_Display_SetEDID`、`SLSDisplaySetEDID`、`CGSDisplaySetEDID`、`DisplayServicesSetEDID` 都不存在；`IOAVService*` 有符号但没有实例可挂。Intel 机器上这条文件路线仍然成立，行为保持原样。

时序怎么来的：**沿用面板已经在用的 blanking，只改像素时钟**。原描述符里的前后肩、同步宽度、图像尺寸、标志位一个字节都不动——面板既然锁得上原生时序，这些数字就已经被证明可用。自己重算一套 CVT 等于同时改两个变量，失败时说不清是谁的问题。

如果目标分辨率根本没有描述符（4K 面板只用一字节 CEA 码描述 1080p），才退回按原生时序的 blanking 比例缩放，并在输出里标注 `no descriptor at this geometry`——那是近似，不是原厂值。

### 自定义缩放分辨率

面板没有、但 macOS 又能渲染的尺寸，可以从菜单里直接加：

> 菜单栏 → 某块屏 → **分辨率 → 添加缩放分辨率…**

填「宽 / 高（点）」，窗口会实时显示对应的渲染尺寸（2× backing）。常用尺寸可以直接从预设下拉里选；已经在列表里的尺寸会标「已可用」并禁用，避免白写一次。写入的是
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<厂商>/DisplayProductID-<型号>`
里的 `scale-resolutions` 数组，一条 8 字节 big-endian `(渲染宽, 渲染高)`：

```
2304 × 1296  →  00 00 12 00 00 00 0A 20   (4608 × 2592)
```

几件必须知道的事：

- **需要一次管理员密码。** 文件写在 `/Library`，不关 SIP。写入前会把原文件备份到
  `~/Library/Application Support/RDM-ARM/overrides/`，删条目不会丢别的键。
- **不会立即生效。** macOS 只在显示器重新挂载时读取这张表：拔插一次线缆或重启后，
  新尺寸才会出现在分辨率菜单里。应用不会假称已经生效，窗口里写得很清楚。
- **这是 Apple 芯片上唯一能加尺寸的路线。** 5K 面板的时序超过 EDID 描述符 655.35 MHz
  的像素时钟上限，`--custom-timing` 根本编不进去；`scale-resolutions` 不新增时序，
  只在现有原生时序上叠一个 backing 尺寸，所以 5K 也能用。
- **会多出一条 1× 条目。** 一条 4608 × 2592 会同时生成 `2304 × 1296 ⚡️` 和 1×
  `4608 × 2592`。后者没有面板声明过的输出时序，菜单会把它隐藏；命令行仍然如实列出。
- **移除**：分辨率 → 移除缩放分辨率 → 选条目。删除后再拔插/重启，尺寸从菜单消失。

本机实测（M4 Max / macOS 27.0.1 / Studio Display）：加入 4608 × 2592 并重新插拔后，
模式表从 26 档变成 28 档，`2304 × 1296 ⚡️` 可直接切换；`IOServiceRequestProbe`
返回 `kIOReturnUnsupported`，重配当前模式也不会重读，所以「拔插或重启」不是提示，
是这个机制本身。

### 所有显示器：同分辨率与镜像

两块屏想显示同一套布局时，不必逐屏钻菜单：

- **所有显示器 → 相同分辨率**：列出每一块屏都支持的几何尺寸（键 = 点尺寸 + 是否 HiDPI），
  刷新率取各屏都有的最高档。点击后所有屏幕在**一个** CoreGraphics 事务里一起切换，
  中途失败整体回滚，不会留下切了一半的桌面。
- **与主显示器一致**：把主屏当前尺寸应用到其他屏；某块屏缺这个尺寸时条目禁用，
  tooltip 直接点名是哪块。
- **镜像所有显示器到主屏 / 停止镜像**：镜像与模式切换在同一个事务里提交。
  主屏当前的时序必须在每块从屏上都存在，否则不会让点下去才失败。
- 「相同分辨率」只考虑公开模式；私有模式表里的条目没有 `CGDisplayMode`，
  无法与镜像/批量事务共存，因此不进入这一层。

顺带修掉了同型号显示器的身份冲突：记忆键里加入了 `CGDisplayUnitNumber`，
两块序列号都为 0 的同型号屏不再互相覆盖。旧格式的键仍会回退读取一次，升级不会丢记忆。

### 显示配置预设

菜单栏 → **预设 → 保存当前配置…** 会把整套状态存下来：每块屏的分辨率、旋转、
镜像关系和亮度（支持的屏）。之后点预设名即可一键切回。

- **应用顺序**：先旋转（旋转会改变可选模式），再把模式与镜像放在一个
  CoreGraphics 事务里提交，最后应用亮度。模式/镜像失败整体回滚；旋转与亮度是
  独立调用，失败会逐条报告，但不会撤销已经成功的部分。
- **按显示器身份保存**，不依赖当前端口号。没接的屏会点名跳过，不会拿另一块屏
  顶替；其余部分照常应用，并在有缺失/失败时弹出一次提示。
- **不在预设里的新显示器保持原样**，不会被解除镜像。
- **删除**：预设 → 删除预设 → 选名字。
- 目前不记录主屏指定与相对排列位置，这两项仍由系统维护。

### 命令行

保留原版的 `-w` / `-h` / `-s` / `-d` / `-lm` / `-ld`，并扩展了旋转和 JSON 输出：

```bash
rdm-arm -ld                        # 列出已连接的显示器
rdm-arm -lm                        # 列出全部可用模式
rdm-arm -lm --json | jq .          # 机器可读输出
rdm-arm -w 1920 -h 1080 -s 2       # 切到 1920×1080 HiDPI
rdm-arm -w 2304 -h 1296 -s 2 -r 60 # 指定刷新率
rdm-arm --rotation 90              # 旋转 90°
rdm-arm --edid                     # 面板自己声明的时序、带宽、刷新范围
rdm-arm --capabilities             # 隐藏档位 + 硬件天花板
rdm-arm --capabilities --json | jq .nativeCeiling   # 同上，机器可读
rdm-arm --refresh-audit            # 某个刷新率为什么拿不到，逐分辨率说明
rdm-arm --refresh-audit -r 75      # 指定目标刷新率
rdm-arm --refresh-audit -r 75 --json | jq .verdict   # 同一份结论，机器可读
rdm-arm --custom-timing 3840x2160@65 --write   # 合成 4K@65 并试写，20 秒自动回滚
rdm-arm --selftest-timing          # EDID/时序纯逻辑自检，不碰系统，无显示器也能跑
rdm-arm --selftest                 # GUI 自检：菜单栏图标位置 + 菜单结构
rdm-arm --selftest --roundtrip     # 自检并真实跑一遍「切换 → 还原」
```

`--selftest-timing` 分成两半：合成出来的替身面板（4K60 首选 + 1080p@75 次要描述符）走完 EDID 编解码、重定时、打补丁、以及**整条审计装配链**，这部分不需要任何硬件，CI 的无显示器 runner 上照样跑；真机那半（读 IOKit EDID、查 CEA 短格式、和实时模式表比对）只在接了显示器时执行，没有显示器就报 `SKIP` 而不是 `FAIL`——没有显示器是环境，不是缺陷，但接了显示器却读不到 EDID 仍然是失败。

命令行切换时如果指定的刷新率在该尺寸上不存在，不会静默替换：会打印实际使用的刷新率和该尺寸可用的档位。切换成功后也会更新按屏记忆，重新插拔或下次启动不会回退到旧模式。

5K 面板还有一条单独的诊断：合成时序需要约 862 MHz，而 EDID 描述符的像素时钟字段上限是 655.35 MHz，`--custom-timing` 会直接说明「卡在描述符，不是显示器」，并指向菜单里的自定义缩放分辨率。

`--selftest` 值得单独说一句：菜单栏图标是否真的显示出来，**无法从进程外部验证**——`CGWindowListCopyWindowInfo` 不枚举菜单栏项，截屏又需要录屏权限。所以自检从进程内部报告窗口服务器实际把图标放在了哪里，是唯一可靠的办法。加上 `--roundtrip` 后会真的切换一次分辨率再还原，用来验证「切换 → 还原」这条链路确实通。

---

## 安装（直接下载）

不想自己编译的话，从 [Releases](../../releases) 下载 `RDM-ARM-<版本>-universal.dmg`，
打开后把 `RDM-ARM.app` 拖进「应用程序」。

包内有 `安装说明.txt`。发行包用 Developer ID 签名并通过 Apple 公证，首次打开不需要
任何额外操作，也不会提示「无法验证开发者」。只有自己从源码构建、且本机没有
Developer ID 证书时（ad-hoc 签名）才需要放行：

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

./Tools/package-release.sh              # 构建、公证并校验发布包（universal + SHA-256）
./Tools/package-release.sh --no-build   # 复用已有产物只做校验与报告
```

构建脚本不依赖 Swift Package Manager、CocoaPods 或 Xcode.app——直接用 `swiftc` 编译，再手工组装 `.app` bundle 并签名。

### 签名与公证

签名分两档：钥匙串里有 `Developer ID Application` 就用它（硬运行时 + 安全时间戳），
没有就回退 ad-hoc（只能在本机跑）。身份会自动探测，也可以用环境变量显式指定。
要出能公开分发的包还得公证（用户双击就能打开、不出现「无法验证开发者」），
公证凭据是 notarytool 的钥匙串 profile，三个 macOS 项目统一叫 `moo`：

```bash
xcrun notarytool store-credentials moo \
  --apple-id '<Apple ID>' --team-id '<Team ID>' --password '<App 专用密码>'

MOO_RDM_NOTARIZE=1 MOO_RDM_NOTARY_PROFILE=moo ./Tools/package-release.sh
```

`package-release.sh` 默认就带 `--notarize`；`build.sh` 单独跑时同样认这两个变量。
凭据存在**当前用户的数据保护钥匙串**里，`security dump-keychain` 枚举不到，
只有 `xcrun notarytool history --keychain-profile moo` 能确认它还在。凭据是机器本地的，
换机后要重新 `store-credentials`。

签名私钥同样不在仓库里，也不只剩在这台机器的钥匙串里。三个 macOS 项目（本仓、Moo Fleet、
桌宠）共用一份备份，放在 iCloud 云盘的 `backups/certs/`——访达里是「iCloud 云盘 ›
backups › certs」，shell 路径：

```bash
CERTS="$HOME/Library/Mobile Documents/com~apple~CloudDocs/backups/certs"
```

里面是加密的 `.p12`（三条身份的证书 + 私钥）、证书链与叶证书两份 PEM，以及恢复步骤
说明。`.p12` 的密码**不落任何文件**，只存在密码管理器里；忘了密码这份备份就等于没备份。

从云盘拉回本机后先收权限再导入——同步不保证保留 600，落到别的设备上这些文件是明文可读的：

```bash
chmod 700 "$CERTS" && chmod 600 "$CERTS"/*.p12 "$CERTS"/*.pem

security import "$CERTS/signing-identities-2026-10-28.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" -P '<p12 密码>' -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s \
  -k '<登录密码>' "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning   # 应恢复出 3 个 valid identities
```

云盘只解决「换机能拿到」，它不是离线介质：第二份副本仍建议放密码管理器附件或一个不常插的
U 盘，并且别和 `.p12` 密码放在同一介质上。

公证链上四条硬约束，改 `build.sh` 时别绕过：

- 提交归档用 `ditto -c -k --keepParent`，**不能用 `zip`**——`zip` 会压平 bundle 的符号链接并丢扩展属性，公证直接拒绝。
- `.app` 和 DMG **各公证一次**，顺序不能反：先公证 app 并 staple，再打 DMG、签 DMG、公证 DMG。Gatekeeper 挂载 DMG 时评估的是 DMG 自己的票据。
- `codesign --timestamp` 不能省。安全时间戳固定「签名时证书有效」，已发布的包在证书过期后仍能验证；漏了它，包会在证书到期当天集体失效。
- **不能只看 `notarytool` 的退出码**——它可能在 `status: Invalid` 时仍退出 0。脚本走 `notarize_or_explain`：认 `status: Accepted`，失败时自动按 submission id 拉 `notarytool log` 并打印 `issues[]`。看到 `error: notarization did not pass` 就直接读日志。

证书有效期到 **2027-02-01**，和签发它的中间 CA（`Developer ID Certification Authority`）
同一天到期。续期时新证书的签发者必须带 `OU=G2`，否则会在同一天原样过期：

```bash
security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -enddate -issuer
```

发出去的包这样复核：

```bash
codesign -dv --verbose=4 build/RDM-ARM.app     # 期望 flags=0x10000(runtime)、有 Timestamp
xcrun stapler validate build/RDM-ARM-<版本>-universal.dmg
```

注意维护机上 Gatekeeper 可能被关掉（`spctl --status` 报 `assessments disabled`），
本地 `spctl -a` 通过只能证明票据存在，不等于在别人的干净机器上也能放行。

### CI 与构建约束

CI（`.github/workflows/build.yml`）在干净的 macOS runner 上验证通用构建、bundle 结构、
两个架构切片都在、版本号在 `build.sh` / `AppInfo.swift` / `Info.plist` 三处一致、CLI 冒烟，并产出 DMG。
**它不跑 GUI** —— 菜单栏图标无法从进程外验证，runner 也没有显示器；GUI 用 `--selftest` 手工验。
CI 也**不做公证**（runner 上没有本机钥匙串凭据），要公证得改用 App Store Connect API key。

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
| **EDID 读取** | IOKit 类匹配 `IOPortTransportStateDisplayPort` | 读通 256 字节，校验和有效，厂商/型号/序号与 CG 一致 | 公开（`CGDisplayIOServicePort` 在 Apple 芯片返回 0，不可用） |
| **链路预算 / 刷新范围** | `DisplayHints` / `DisplayAttributes` | 594 MHz、50–76 Hz | **私有类名**（可选模块） |
| **自定义缩放分辨率** | `/Library/.../Overrides` 的 `scale-resolutions` | **写入并重新挂载后生效**：Studio Display 26 → 28 档，`2304 × 1296 ⚡️` 实测可切换 | 公开写入路径（无需 SIP） |
| **自定义时序** | 改写 `IODisplayEDID` → `/Library/Displays/.../Overrides` | **Apple 芯片：写得进、读不到，`--write` 直接拒绝（退出码 3）**；Intel 可用 | 公开写入路径，无 SIP |
| **刷新率审计** | 公开模式表 + EDID 声明 + 链路预算三者交叉比对 | 区分「系统藏了 / 面板没写 / 链路不够」，并暴露 HiDPI 的点尺寸≠输出时序 | 公开 |

新增的几块都遵守同一条边界：EDID 解析、时序计算、审计判定在 `Core/`（纯数据、无副作用），Apple 私有类名的属性读取和 override 写入在 `Optional/`。

override 能不能用，按**机制**判定，不是按目录判定：`IODisplayEDID` 在 Apple 芯片上写入后被忽略（所以 `--write` 直接拒绝），`scale-resolutions` 则会被重新挂载时读取。EDID 这条闸门仍按**硬件**判定（`sysctlbyname("hw.optional.arm64")`），不是编译期 `#if arch(arm64)`：universal 包的 x86_64 slice 在 Apple 芯片上经 Rosetta 运行时，编译期判断会以为自己在 Intel 上，进而放开一条写了也不被读取的路径——那一步会先要管理员密码。硬件属性从哪个 slice 读都一样。

**关于审计的可信度**：判定逻辑有 25 条断言覆盖（`--selftest-timing` 现在共 73 条：68 条合成、5 条真机；没有 CEA 短格式的面板会少一条并标 `SKIP`）。四种成因各钉一条——因为它们的修法完全不同，"看起来合理"是不够的；其中 10 条走的是**整条审计装配链**（合成 EDID → 模式表 → 按输出几何分组 → 排序 → 判定），不是单独调 `verdict()`，所以分组和排序也会被咬住。另有断言钉住：59.94 与 60 必须算同一个答案、`unknown` 不许冒充 `unreachable`、「已经可用」必须取面积最大的那行而不是表格第一行。自定义缩放分辨率的字节格式、合并/移除、跨屏交集、旋转下的 HiDPI 判定、同型号显示器身份也各有断言。关键几条都做过 mutation 验证（把实现改坏，确认对应断言真的 FAIL）。

说清楚这块还差什么：`hidden` 分支现在有合成样本，但**没有真机样本**——本机这块面板的 EDID 声明被 macOS 全部列了出来，造不出「声明了但系统没列」的现场。要真验这条，得换一台 Intel 机器走一次 override 路线。

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
    EDID.swift               EDID 解析与重编码（时序、CEA 短格式、校验和）
    DetailedTiming.swift     18 字节 DTD 的编解码与重新计时
    DisplayEDID.swift        IOKit 读取 EDID；请求重新枚举
    DisplayCapabilities.swift 声明了什么 / 给了什么 / 链路上限
    TimingSelfTest.swift     --selftest-timing 的纯逻辑断言
    Localization.swift       中英双语字符串
    AppInfo.swift            版本信息与诊断输出
  Optional/     私有 API，全部隔离在这里
    PrivateSymbolLoader.swift        运行时符号解析
    PrivateModeTable.swift           隐藏 HiDPI 模式（私有模式表）
    DisplayRotationController.swift  旋转（能力探测）
    DisplayBrightnessController.swift 亮度（能力探测）
    DisplayLinkInfo.swift            链路预算 / 刷新范围（私有类名，只读）
    DisplayOverrideInstaller.swift   按 key 合并写入 /Library 下的 override
    ScaleResolutionStore.swift       scale-resolutions 的编解码、差集与合并
    CustomTimingEngine.swift         合成 → 预算校验 → 写入 → 重新枚举
  Features/
    ModeMemoryController.swift    每屏记忆 + 热插拔恢复
    DisplayPresets.swift          预设模型、捕获与一键应用
    Preferences.swift             偏好设置持久化
  UI/
    AppDelegate.swift         菜单栏生命周期
    StatusMenuBuilder.swift   菜单构建（所有显示器、预设、自定义分辨率入口）
    MenuActionRouter.swift    菜单动作分发
    CustomResolutionWindow.swift 添加/移除缩放分辨率（AppKit）
    SettingsWindow.swift      设置窗口（AppKit）
    GUISelfTest.swift         --selftest 诊断
  CLI/
    CommandLineRunner.swift   命令行界面
Tools/
  MakeIcon.swift              用 CoreGraphics 程序化生成应用图标
```

设计上有一条清晰的边界：**私有 API 只存在于 `Sources/Optional/`**。Core 引用私有的地方都是显式的：`DisplayManager` 取隐藏模式、`ModeController` 应用隐藏模式、`DisplayCapabilities` 读链路预算、`CustomTimingEngine` 写 override——每一处都会先确认符号/类名存在、开关打开。想知道"哪里可能随系统升级失效"，只看这个目录就够了。

另外两类东西严格分居：EDID 解析、时序计算、预算估算全在 `Core/`，是纯函数、没有副作用，可以用 `--selftest-timing` 单独验证；只有"读 Apple 私有属性"和"以 root 写文件"进 `Optional/`。

---

## 已知限制

- **亮度控制**在外接显示器上不可用（需要 DDC/CI 通路，这台 BenQ 没有暴露）。内置屏应该正常。
- **隐藏 HiDPI 模式依赖私有模式表**：这张表的记录结构 Apple 从未公开，而且在变——macOS 27 上 `depth` / `refreshRate` 字段已经读不出正确值（所以这些模式没有独立刷新率，沿用同尺寸公开模式的值）。一旦偏移再变，`PrivateModeTable` 的自检会失败并整体停用，菜单里就只剩公开模式。
- 已发布的包使用 **Developer ID 签名并通过 Apple 公证**（见「构建」一节），首次打开不需要额外操作；只有本机没有证书、自己从源码构建时才回退 ad-hoc，需要手动放行。
- 部署目标 **macOS 13.0**。旋转依赖的私有符号在更早的系统上可能不存在，此时会自动隐藏旋转菜单。
- 构建工具链**最低已验证到 Xcode 15.4 / Swift 5.10**（CI runner）。早期版本用过会失败的写法
  （`CGRect` 的 `Hashable` 合成）已修掉，但更老的工具链未做验证。
- **切换立即生效，没有确认框、也没有自动还原**。RDM 列出的模式里有一部分被 macOS 标记为不适合桌面 GUI；如果选中的模式显示器显示不出来，画面会变黑，而菜单栏恰好就在这块屏上。此时可以用键盘盲操作菜单退回安全模式（菜单里始终有「恢复系统默认」），或在终端用命令行改回来。
- 多屏镜像（mirroring）状态下部分模式不可用，这是 macOS 本身的限制。
- **自定义时序在 Apple 芯片上只算不写**。真机验证（M4 Max / macOS 27.0.1 / BenQ PD2705U）的结论是：override 文件写得完全正确，系统却不读它——实时 EDID 仍是面板原厂值，拔插线缆、显示器休眠、整机睡眠三种重载触发都试过，模式表 290 条一动不动。所以 `--write` 在 Apple 芯片上直接拒绝（退出码 3），不再让你输密码再告诉你没变化；菜单和 `--capabilities` 也会如实标注。Intel 机器上这条路线保持原样可用。将来系统若修复，设 `RDM_ALLOW_EDID_OVERRIDE=1` 可绕过闸门复验。
- **链路预算依赖私有类名**（`AppleATCDPAltModePort` 等）。这些名字随系统变动时，预算会变成"未知"，`--custom-timing` 仍能算出时序，但不会再声称知道天花板——宁可少说，不可乱说。

---

## 与上游的关系

RDM 由 [Avi Alkalay](https://github.com/avibrazil/RDM) 开发，是 macOS 分辨率解锁工具的经典实现。这个项目**不是 fork**——没有复用它的代码，而是重新实现的：原版是 Objective-C++ 加私有 SPI，重写版是 Swift，以公开 API 为底，只把公开接口拿不到的那几件（旋转、亮度、隐藏 HiDPI 模式、链路预算读取）交给可关闭的私有模块。

上游仓库没有附任何正式许可证文件，README 中作者表示"作者们会乐意你自由使用"。本重写版按原样（as-is）提供，供个人使用。

`⚡️` 这个 HiDPI 标记沿用自原版，作为对它的致意。
