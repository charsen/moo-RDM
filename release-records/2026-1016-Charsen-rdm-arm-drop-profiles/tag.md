# RDM-ARM 1.0.4 —— 移除配置文件功能

状态：**双源已发布**。`origin`（Gitee）与 `github` 的分支、tag、Release 与附件一致。

## 起因

同事试用反馈：**配置文件这套东西实际没人用**，却占着菜单和偏好设置的位置。
截图里菜单中间那个「配置文件 ›」子菜单（里面只有一条「将当前布局存为配置文件…」）
就是要拿掉的东西。

1.0.3 时已经按反馈去掉了导出 / 导入，这次是把整个功能拿掉。

## 改了什么

| 位置 | 变化 |
| --- | --- |
| 菜单 | 整块去掉「配置文件」子菜单（含「将当前布局存为配置文件…」） |
| 偏好设置 | 去掉「配置文件」标签页（原为第 3 个标签） |
| 命令行 | 去掉 `--save` / `--apply` / `--list-profiles` |
| 源码 | 删除 `ProfileStore.swift`、`ProfileBox`、`HotKeyAction.profile(_:)` |
| 本地化 | 中英各删 13 个键 |
| 顺带 | 去掉「打开支持文件夹」按钮与 `Preferences.supportDirectory` |

净变化：**532 行删除，17 行新增**，源文件从 22 个减到 21 个。

### 为什么连「打开支持文件夹」也去掉

`~/Library/Application Support/RDM-ARM/` 这个目录此前**只用来放 `profiles.json`**。
配置文件功能没了，就没有任何东西会往里写 —— 留着那个按钮就是项目硬约束里
明确禁止的「点不动的死控件」。所以按钮、`supportDirectory`、`ensureSupportDirectory`
一并移除。

> 如果以后需要支持目录，重新加回来是几行的事；但**不该为了「看起来有用」先留着**。

### 什么没受影响

**每屏模式记忆照常工作。** 它走的是 `Preferences.rememberedModes`（`UserDefaults`），
与 `ProfileStore`（`profiles.json`）是两套完全独立的机制。重插显示器后仍会自动
恢复你选的分辨率，菜单里的「记住此显示器的模式 / 忘记已记住的模式 /
恢复已记住的模式」都还在。

同理，`HotKeyAction` 里剩下的三个动作不受影响。老用户 `UserDefaults` 里可能残留
`profile.<uuid>` 形式的快捷键键值，它们**再也不会被读取**，是惰性数据而不是迁移隐患
（已写进 `HotKeyAction.swift` 的注释）。

## 验证

| 项 | 结果 |
| --- | --- |
| 通用构建 | `x86_64 arm64`，app 2.2 MB |
| CI（Xcode 15.4 / Swift 5.10） | 全绿，12 步 |
| 菜单结构 | `--selftest` 全量 dump 中 `配置文件` / `profile` 命中 **0** |
| 菜单残留 | 无空分隔符、无死条目（顶层：显示器 / 两个开关 / 偏好设置 / 关于 / 退出） |
| 偏好设置 | 标签页从 5 个减到 4 个（通用 / 快捷键 / 高级 / 关于） |
| 命令行 | `--list-profiles`、`--save`、`--apply` 均返回 `unknown option` |
| `--help` | 配置相关文案命中 **0** |
| 本地化 | 中英各 74 键，两侧键集完全相同；无「用了但表里没有」的键 |
| 显示设置 | 验证后仍为 2304 × 1296 ⚡️ · 60 Hz |

### 本地化键核查

写了个脚本比对两张表与 `Sources` 里所有 `L10n.t("…")` 字面量：

- 中英各 **74** 个键，**键集完全一致**
- 「用了但表里没有」：仅 `rotation.\(Int(normalize(degrees)))`，是**动态拼键**，符合预期
- 「表里有但没引用」：12 条中，`lang.system` 在 `Localization.swift` 内部使用、
  `rotation.0/90/180/270` 由上面的动态拼键覆盖 —— 真正未使用的从 **9 条降到 7 条**
  （`profile.applied` 与 `settings.hotkeyProfile` 随本次删除一并消失）

## 引用（逐远端回读核验）

```
8152d0e  refs/heads/master
         refs/tags/1.0.4        (peeled 8152d0e)
```

tag 打在「发布准备」commit `chore(release): 版本号提到 1.0.4` 上，与 `master` 顶点相同。

本次是两个 commit：

| commit | 说明 |
| --- | --- |
| `4c3b3e7` | `feat: 移除配置文件功能` |
| `8152d0e` | `chore(release): 版本号提到 1.0.4` ← **tag 在这里** |

## 发布物

两端各一个通用二进制附件，`prerelease=false`（正式 Release）：

| 项 | 值 |
| --- | --- |
| 文件 | `RDM-ARM-1.0.4-universal.zip` |
| 字节 | 1 448 070 |
| SHA-256 | `a7fbb36a4aad95f62015aa489b69ec08a2f720bcd27dd5bb4ab1c5150d29e93c` |

**从两个远端各自下载后**与本地构建产物比对，哈希均一致（不是只看接口返回值）。
zip 内附 `安装说明.txt`（1 598 字节，版本号已随 1.0.4 更新），含 Gatekeeper 拦截的
一行解法与「这是菜单栏应用、没有主窗口」的提示。

Gitee 侧照例自动附带源码包 `1.0.4.zip` / `1.0.4.tar.gz`，是平台行为，不是我们传的。

## 遗留

- 7 条长期未使用的本地化键：`app.name`、`menu.builtIn`、`menu.currentResolution`、
  `menu.unsupported`、`menu.autoApplied`、`settings.launchAtLogin`(+`.hint`)。
  注意 `rotation.*` 与 `lang.system` 是**动态拼键 / 内部使用**，别误删。
- 之前记的：快捷键注册失败静默、零测试、无 `LICENSE`、无 `CHANGELOG`。
- 老用户磁盘上可能残留 `~/Library/Application Support/RDM-ARM/profiles.json`，
  已不再读取。**没有主动去删** —— 那是用户数据，不该由我们清理。
