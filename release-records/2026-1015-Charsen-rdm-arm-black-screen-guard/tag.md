# RDM-ARM 1.0.2 —— 黑屏保护

状态：**已发布**（GitHub Release 预发布）。Gitee 侧仓仍未建，见 1.0.0 记录的卡点。

## 发布形态

- 本仓：`master` 顶点打 annotated tag **`1.0.2`**。
- GitHub Release 标为 pre-release，发布物是编译好的通用二进制：
  `RDM-ARM-1.0.2-universal.zip`（arm64 + x86_64）。
- 不包含任何部署步骤。

## 这一版解决什么

1.0.1 让同事能下载到能跑的东西；1.0.2 解决的是**跑起来可能回不去**的问题。

本机 macOS 报告 257 个模式，其中 **77 个**带 `kDisplayModeNotGraphicsQuality` 一类标志位，
即"不适合桌面 GUI 使用"。而 RDM 的价值恰恰在于把它们**全部列出来**——不列出来就没有可解锁的东西。

风险在于：显示器如果真显示不了这个模式，画面会全黑。而**能让你改回来的菜单栏图标，正好画在这块
黑掉的屏幕上**。除了等系统超时或强制重启，没有别的办法。原版 RDM 没有处理这件事。

### 黑屏保护（新增）

每次切换分辨率或旋转后弹出 15 秒确认框：

- 不操作 → 15 秒后自动还原到切换前的**模式与旋转角度**
- 「保留」→ 采用新模式
- 「立即还原」→ 立刻退回

实现要点（都不是可选项）：

- 倒计时 `Timer` 挂在 `RunLoop.current` 上，模式为 **`.common`**。只加 `.modalPanel` 的话，
  模态循环里定时器根本不会触发，"自动还原"就是一句空话。
- 面板层级 `.screenSaver` + `canJoinAllSpaces` + `fullScreenAuxiliary`：多屏时不会落在黑掉的那块屏上。
- **模式记忆只在确认之后写入**。否则被还原掉的分辨率会在下次重插屏幕时自己回来。
- **「恢复默认分辨率」故意不加保护**——它本身就是出问题时的救命操作，不能被自己回滚掉。
- 选中的就是当前模式时不弹框。
- 设置 → 通用里可关闭（`confirmModeChanges`，默认开）。

### 命令行也加了保护，但只在真正危险时拦

只有当选中的模式被 macOS 标记为**不可用**时才询问，并且要求 stdin 是终端。

两个理由：每次切换都问会让脚本白白卡 15 秒；而一个动不动就拦人的保护，最后一定会被永久关掉。
管道和 CI 里没人按键，直接跳过。显式跳过用 `-y` / `--no-confirm`。

### 顺带修掉的问题

- **打包脚本会把非通用二进制标成 "universal"**。`package-release.sh` 原本只检查 arm64 切片，
  于是 `--no-build` 复用一次 arm64-only 构建时，会产出一个文件名和安装说明都写着"通用二进制"、
  实际只能在 Apple silicon 上跑的 zip。现在两个切片都强制检查，缺 x86_64 直接报错。
  安装说明里的 `$ARCHS 通用二进制`（会渲染成"arm64 通用二进制"这种病句）也一并改掉。
- **版本号防护只覆盖了两处中的一处**。`Resources/Info.plist` 里的模板版本一直是 `1.0.0`，
  虽然构建时会被 `PlistBuddy` 覆盖，但任何跳过 `build.sh` 的打包路径都会带着错版本出去。
  现在 `build.sh` 和 CI 都核对三处（`build.sh` / `AppInfo.swift` / `Info.plist`）。

### 验证工具

`--selftest` 新增两段输出，并且可以真的跑一遍还原：

```
-- mode change guard --
confirm pref : on
timeout      : 15s
stdin is tty : true  (CLI prompts only on a terminal)
snapshot     : 1 display(s) can be restored
risky modes  : 77 of 257 are flagged not usable for the desktop GUI

-- guard round trip --
from         : 2304 × 1296 ⚡️
to           : 2304 × 1296
applied      : 2304 × 1296
rolled back  : 2304 × 1296 ⚡️
PASS: rollback restored the original mode
```

`--selftest --roundtrip` 会挑一块**最接近当前分辨率**的可用模式切过去再还原，
把闪烁降到最小，并且一定在返回前还原。

## 验证

| 项 | 结果 |
| --- | --- |
| 通用构建 | `x86_64 arm64`，2.4 MB，无源码警告 |
| 还原往返 | 2304×1296 ⚡️ → 2304×1296 → 2304×1296 ⚡️，PASS |
| 倒计时自动还原 | 临时把超时改成 3 秒、强制弹框实测：3.5 秒返回、退出码 3、输出「未确认 —— 已还原到之前的模式」，显示器无变化 |
| 非终端不阻塞 | `-w 2304 -h 1296 -s 2 < /dev/null` 0.036 秒返回，无弹框 |
| 测试改动已清 | 临时改动与备份 `diff` 为空 |
| 还原后显示状态 | 2304 × 1296 ⚡️ · 60 Hz（用户原设置） |
| zip 结构 | `ditto` 与 Info-ZIP 解压均得 `RDM-ARM.app` + `安装说明.txt`（中文名两边都正确） |
| zip 内应用 | `-v` 报 `1.0.2`，`lipo` 报 `x86_64 arm64` |
| 包体 | 1.5 MB，SHA-256 `810609208af04a8666395e0bf79bad9ad0efb7863385d68d88fcf5fdf60dc060` |

### 没验到的

**「保留」按钮这条路径没有实测。** 按下它需要真实键盘事件，而合成键盘事件打进自己进程需要
辅助功能权限（本机未授予）。代码上它和「立即还原」走同一个 `ButtonBridge`，只是
`stopModal(.OK)` 与 `.cancel` 之差；超时路径已验证定时器确实在模态循环里触发，
所以剩下的风险很低，但确实没有端到端跑过。

`unzip -l` 列表里中文文件名显示为乱码，这是 Info-ZIP 列表输出不认 UTF-8 标志位所致，
**解压结果两边都正确**（已实测），不影响同事使用。

## 正式发版下一步

Gitee 建仓后一条命令补齐双源：

```bash
cd /Volumes/dev/wwwroot/moo-RDM
git push -u origin master && git push origin 1.0.2
git ls-remote origin
```
