# RDM-ARM 1.1.0 —— EDID 能力分析，自定义刷新率写入被真机否证

状态：**双源已发布**。`origin`（Gitee）与 `github` 的分支、tag、Release 与附件一致。

## 起因

一句提问：「BetterDisplay 能支持显示器之外的刷新率，是怎么做到的？我也想这个软件支持。」

拆开看是两种能力，机制完全不同：

1. **系统隐藏档位** —— 面板在 EDID / CEA 里声明过，macOS 只是没列出来（4K 屏缺 59.94 / 29.97 / 23.976 这类 NTSC 档位）；
2. **真正的超规格时序** —— 面板从没报过的刷新率，只能自己造一个 detailed timing 塞进 EDID。

先在本机做只读探测，再决定怎么实现。探测本身就把两条常见路线否掉了：

| 路线 | 结论 |
| --- | --- |
| 未声明但导出的 `CGDisplayModeCreate` | 符号在（`dlsym` 能拿到地址），但按 `Width/Height/BitsPerPixel/RefreshRate` 调用**连"原样重建当前模式"都返回 `NULL`** |
| 写 `/Library/Displays/.../Overrides` | 写得进、读不到（详见下文真机验证） |

## 改了什么

| 位置 | 变化 |
| --- | --- |
| 解析 | 新增 `Core/EDID.swift` —— 256 字节 EDID 全量解析：基准 DTD、CEA 短格式、厂商/型号/序号、块校验和；可重编码并按槽位修补 |
| 时序 | 新增 `Core/DetailedTiming.swift` —— 18 字节 DTD 编解码、`retimed`（只改像素时钟）、`scaled` / `synthesized` |
| 读取 | 新增 `Core/DisplayEDID.swift` —— IOKit 类匹配取实时 EDID；`requestReprobe` 用模式表指纹核对是否真的重新枚举 |
| 分析 | 新增 `Core/DisplayCapabilities.swift` —— 「EDID 声明了什么 / 系统给了什么 / 链路上限是多少」三方对比 |
| 自检 | 新增 `Core/TimingSelfTest.swift` —— 18 项纯逻辑断言，`--selftest-timing` 触发 |
| 注入 | 新增 `Optional/DisplayOverrideInstaller.swift`、`Optional/CustomTimingEngine.swift` —— 生成三键 plist、备份、管理员授权、预算守卫、看门狗回滚 |
| 链路 | 新增 `Optional/DisplayLinkInfo.swift` —— `DisplayHints.MaxTotalPixelRate` 等私有节点读取，开关关掉即退化为「只报时序成本、不报天花板」 |
| 命令行 | 新增 `--edid` / `--capabilities` / `--custom-timing` / `--write` / `--keep` / `--revert` / `--emit-edid` / `--timeout` / `--sleep-wake` / `--selftest-timing` |
| 菜单 | 每屏新增子菜单「EDID 与刷新上限」：原生时序、带宽与厂商范围、隐藏档位、越限说明 |
| 本地化 | 中英各 89 键，键集完全一致（比 1.0.5 多 30 键） |
| 版本 | `build.sh` / `AppInfo.swift` / `Info.plist` 三处同步到 1.1.0 |

新增 8 个源文件、1351 行；源文件从 19 个增到 27 个，总行数 5102。
改动量：`CommandLineRunner` +314、`Localization` +100、`StatusMenuBuilder` +51、`README` +81。

## 屏幕上的样子

```
$ rdm-arm --capabilities
Display 0: BenQ PD2705U
    native timing  3840 × 2160 @ 59.997 Hz (533.25 MHz, totals 4000 × 2222)
    budget         链路 594 MHz · 厂商范围 50–76 Hz
    at 3840 × 2160      up to 67 Hz by budget
    hidden rates   none — every declared rate has a mode
    beyond         timing computed, but a display override is ignored on Apple silicon
```

带宽 594 MHz 来自 `DisplayHints.MaxTotalPixelRate`，厂商范围来自 `DisplayAttributes.MaximumRefreshRate`，两者都挂在 Apple 私有 DCP 端口类上，因此按项目边界放进 `Sources/Optional/`。开关一关，这两行就只说「unknown — optional module off」，其余分析照常。

越限会带数字拒绝，而不是含糊一句「做不到」：

```
$ rdm-arm --custom-timing 3840x2160@75
75 Hz 超出链路能力（约 67 Hz）        # exit 1
$ rdm-arm --custom-timing 3840x2160@65
    encoded  3840 × 2160 @ 65.000 Hz  (577.72 MHz, totals 4000 × 2222)   # 预算内
```

## 时序怎么算

**沿用面板已经在用的 blanking，只改像素时钟。** 原描述符里的前后肩、同步宽度、图像尺寸、标志位一个字节都不动——面板既然锁得上原生时序，这些数字就已经被证明可用。自己重算一套 CVT 等于同时改两个变量，失败时说不清是谁的问题。

只有目标分辨率根本没有描述符时（4K 面板常用一字节 CEA 码描述 1080p），才退回按原生时序的 blanking 比例缩放，并在输出里标注 `no descriptor at this geometry`。

## B 路线：真机写入被否证

三次真机写入，结论是「写得进去，系统不读」：

| 触发方式 | 系统是否重读 EDID | 模式数 |
| --- | --- | --- |
| 热插拔重连（拔线 2 秒再插） | 否 | 290 → 290 |
| 显示器休眠唤醒（`pmset displaysleepnow`） | 否 | 290 |
| 整机睡眠唤醒（16:10:02 睡 → 16:10:14 醒，实测 12 秒） | 否 | 290 |

落盘内容本身是对的，独立 Python 复核过：

- 路径 `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9d1/DisplayProductID-8039`，`root:wheel 644`；
- 三键 plist、256 字节 EDID、块校验和有效；
- 槽 54 首选时序 `3840×2160@59.997 / 533.25 MHz` **一字节未动**，前 128 字节零差异；
- 槽 72 写入 `1920×1080@75 / 166.65 MHz`，被牺牲的是空槽而不是产品名。

但系统读回来的还是原厂值：`ioreg` 里实时 `EDID` 的槽 72 时钟是 **0.00 MHz**（那里仍是显示器信息描述符），模式表始终 290 条。

顺带排除掉的另外几条路：

- `CoreDisplay_Display_SetEDID`、`SLSDisplaySetEDID`、`CGSDisplaySetEDID`、`DisplayServicesSetEDID` —— **全部不存在**；
- `IOAVService*` —— 符号齐备，但 `ioreg -c IOAVService` **一个实例都没有**，那条路属于 Intel / MST；
- `CGVirtualDisplay` —— 类在，能建虚拟屏，但只能镜像到 60 Hz 面板，**面板实际刷新率不变**。

所以 **1.1.0 在 Apple 芯片上不给 `--write`**：闸门在弹管理员密码之前就拦住，退出码 3，并说明原因。时序仍然可算、可 `--emit-edid` 导出，只是交不到系统手里。留了 `RDM_ALLOW_EDID_OVERRIDE=1` 复验开关：将来某个系统版本修好了，不改代码就能验证。Intel 机器行为保持原样。

## 验证

| 项 | 结果 |
| --- | --- |
| 通用构建 | `x86_64 arm64`，app 2.4 MB，zip 1.5 MB |
| CI（GitHub Actions，`build`） | `88d4868` **failure**（类型检查超时）→ `9e4245d` **success** |
| 重构 A/B | 同一目标导出的 EDID 与修正前 `cmp` 逐字节一致（256 字节） |
| 版本一致性 | `build.sh` / `AppInfo.swift` / `Info.plist` 三处均为 1.1.0 |
| 安装 | `/Applications/RDM-ARM.app`，`CFBundleShortVersionString` 1.1.0，`CFBundleVersion` 1.1.0，签名 ad-hoc，无 quarantine |
| `--version` | `RDM-ARM 1.1.0 (build 1)` |
| `--selftest` | 退出码 0；状态栏图标 `on screen`；顶层 9 项；「EDID 与刷新上限」子菜单内容正确 |
| `--selftest-timing` | 18 项断言全 PASS（重定时只改字节 0/1；补丁后块数不变、校验和有效、首选时序未动；缩放后仍有 back porch） |
| `--capabilities` | 原生时序、594 MHz、50–76 Hz、4K 天花板 67 Hz 全部读出 |
| `--custom-timing 4K@75` | 拒绝，提示「超出链路能力（约 67 Hz）」，退出码 1 |
| `--custom-timing 1080p@75 --write` | Apple 芯片闸门拦截，退出码 3，不弹密码框 |
| 导出 EDID 交叉校验 | 独立 Python 解析器复核：4K60 原样保留，新增 1080p@75（166.65 MHz，2000×1111） |
| 现场恢复 | `--revert` 后 override 删除，`/Library/.../Overrides` 无残留，模式表回 290 |
| 本地化 | 中英各 89 键，键集一致；新增键均有引用，无「用了但表里没有」 |
| zip 内容 | 解包复核：`RDM-ARM.app`（1.1.0，双切片）＋ `安装说明.txt`（版本号已随 1.1.0 更新） |
| 双源附件 | 两侧各自下载，哈希均与本地一致 |
| 正式 Release | GitHub 与 Gitee 的 `/releases/latest` 均返回 `1.1.0`，`prerelease=False` |

### 未验证 / 已知代价

- **Intel 未实机验证**：B 路线在 Intel 上「应当成立」是按机制推断的，本机只有 M4 Max。代码保留了执行路径，但「写入 → 重新枚举 → 新档位出现」这一段在 Intel 上没人跑过。
- **`--revert` 在 Apple 芯片上仍会执行**：闸门只拦 `--write`。这样做是为了不把已经写进去的东西锁死——撤销总是允许的。
- **私有节点读不到时**：`DisplayHints` / `DisplayAttributes` 属于 Apple DCP 私有类，系统升级可能改类名。读不到就退回「不报天花板」，不报错、不猜数。
- **`CGDisplayIOServicePort` 在 Apple 芯片返回 0**：所以 EDID 读取改走 IOKit 类匹配，不是原版 RDM 那条路。

## 引用（逐远端回读核验）

```
9e4245d  refs/heads/master   (origin 与 github 一致)
d49d71b  refs/tags/1.1.0     (annotated → 9e4245d)
```

`rev-list --count origin/master..master` 与 `github/master..master` 均为 **0**；
`ls-remote` 两端 tag 对象均指向 `d49d71b`，解引用后都是 `9e4245d`。

| commit | 说明 |
| --- | --- |
| `3b93e66` | `feat: EDID 解析与能力分析，Apple 芯片上如实拒绝改写 EDID`（13 文件，1896 增 / 2 删） |
| `88d4868` | `chore(release): 版本号提到 1.1.0`（3 文件，3 增 / 3 删） |
| `9e4245d` | `fix: 拆开 DTD 字节 4/7/11 的位运算，避免旧工具链类型检查超时` ← **tag 在这里** |

### tag 为什么不在 `chore(release)` 上

按惯例 tag 打在 `chore(release)`。这一次不行：`88d4868` 的 CI **failed**，而
`1.1.0` 曾在它上面推出过几分钟。原因和处置：

- CI（`macos-14` / Swift 5.10）在 `DetailedTiming.synthesized` 的字节 11 表达式上报
  `the compiler is unable to type-check this expression in reasonable time`；
- 本机 Swift 6.4 能过——**本地全绿不代表 CI 绿**，这条以后要记住；
- 修法是把四处嵌套位运算改成具名中间量（纯重构，不改取值）；
- 为了不让 tag 停在失败提交上，删掉两端的 `1.1.0` 重新打到 `9e4245d`。旧 tag 只存在
  了约十分钟，没有 Release 附件挂在上面，因此没有对外可见的后果；
- 修完后 CI 在 `9e4245d` 上 **success**。

重构的正确性用 A/B 证明：拿 `88d4868` 的源码另建一份二进制，与修正版对同一目标
（`1920 × 1080 @ 75`）各导出一份 EDID，`cmp` 逐字节 **完全一致**（256 字节）。

## 发布物

| 项 | 值 |
| --- | --- |
| 文件 | `RDM-ARM-1.1.0-universal.zip` |
| 字节 | 1 532 395 |
| SHA-256 | `bdb770323dc525350208e822cd205911bcbbe3489298568393281d9ac2c4a69f` |
| 架构 | `x86_64 arm64` |
| 签名 | ad-hoc（首次打开需 `xattr -dr com.apple.quarantine`） |

产物是从 **tag 所在提交** 重新构建的，不是修 tag 之前那一份（旧 zip 的 SHA-256 是
`562be6d3…`，字节 1 532 455，已作废）。

两端各传一份，`prerelease=false`（正式 Release）：

| 平台 | Release | 附件 |
| --- | --- | --- |
| GitHub | https://github.com/charsen/moo-RDM/releases/tag/1.1.0 | ✅ 1 532 395 B |
| Gitee | https://gitee.com/charsen/moo-RDM/releases/tag/1.1.0 | ✅ 1 532 395 B |

**从两个远端各自下载后**与本地构建产物比对，三者哈希一致（不是只看接口返回值）：

```
GitHub 下载  bdb770323dc525350208e822cd205911bcbbe3489298568393281d9ac2c4a69f
Gitee  下载  bdb770323dc525350208e822cd205911bcbbe3489298568393281d9ac2c4a69f
本地产物     bdb770323dc525350208e822cd205911bcbbe3489298568393281d9ac2c4a69f
```

下载到的包解压复核：`CFBundleShortVersionString = 1.1.0`，签名 ad-hoc，
identifier `io.rdmarm.RDM-ARM`。

`/releases/latest` 两端都返回 `1.1.0`（`prerelease=False`）。Gitee 侧照例自动附带源码包
`1.1.0.zip` / `1.1.0.tar.gz`，是平台行为，不是我们传的——比对哈希时别把它们算进来。

### 上传方式

凭据取自 `/Volumes/dev/git_tokens`（`## gitee_token` / `## github_token`），只在脚本进程内
读取，不打印、不进命令行参数：

- GitHub：`POST /repos/{owner}/{repo}/releases` → `POST https://uploads.github.com/.../assets`
- Gitee：`POST /api/v5/repos/{owner}/{repo}/releases`（需要 `access_token`、
  `target_commitish`、`prerelease`）→ `POST .../releases/{id}/attach_files`（multipart，
  字段名 `file`）

写成了幂等脚本：先按 tag 查，已存在就复用、附件同名就跳过，重复跑不会造出第二个 Release。

## 遗留

- **B 在 Apple 芯片上是死路**，除非逆向 BetterDisplay 的实时注入链路。1.1.0 的定位是「算得准、说得清、不乱改系统」。
- **隐藏档位依赖私有模式表**（1.0.5 引入），偏移随系统升级可能再变；下次系统大版本升级值得重跑 `--selftest` 看隐藏模式数是否为 0。
- 仍有 7 条长期未使用的本地化键：`app.name`、`menu.builtIn`、`menu.currentResolution`、`menu.unsupported`、`menu.autoApplied`、`settings.launchAtLogin`(+`.hint`)。`rotation.*` 是动态拼键，别误删。
- 仍未做：零单元测试（时序部分靠 `--selftest-timing` 的运行时断言兜着）、无 `LICENSE`、无 `CHANGELOG`。
- 命令行 `-lm` 仍默认列全部模式，保留原行为。
- **本地工具链比 CI 新（Swift 6.4 vs 5.10）**，本机编译通过不代表 CI 通过。本次已经
  因此白推一次。位运算密集的编码代码建议拆成具名中间量；必要时在 CI 加
  `-Xfrontend -warn-long-expression-type-checking` 把热点提前暴露出来。
