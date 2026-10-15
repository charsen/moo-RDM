# RDM-ARM 1.0.1 —— 同事测试版

状态：**已发布**（GitHub Release 预发布）。Gitee 侧仓仍未建，见上一条记录的卡点。

## 发布形态

- 本仓：`master` 顶点打 annotated tag **`1.0.1`**。
- **本版是给同事试用的测试版**，GitHub Release 标为 pre-release。
- 发布物是**编译好的通用二进制**，不是源码：
  `RDM-ARM-1.0.1-universal.zip`（arm64 + x86_64，解压得 `RDM-ARM.app` + `安装说明.txt`）。
- 不包含任何部署步骤。

## 为什么 1.0.0 之后马上有 1.0.1

1.0.0 只是把源码推上了仓，**没有可下载的二进制**，同事拿不到能跑的东西 —— 他们得先装
Command Line Tools 再 `./build.sh`，对"下载来测试"来说门槛太高。1.0.1 补齐的是**分发形态**，
顺带修了一个在测试场景下会直接坏事的问题：

- **`try?` 吞掉导入/导出的错误**（`SettingsWindow`）。配置文件 JSON 格式不对时，界面
  什么都不显示、什么都不发生 —— 对试用者来说这是最糟的反馈。改为弹 `NSAlert` 说明原因。
  `Localization` 里 `profile.importFailed` 等键早就写好了，只是一直没接上。
- 版本号漂移防护：`build.sh` 现在会核对 `AppInfo.swift` 里的版本，不一致直接报错退出
  （否则 About 面板和 Finder 显示简介会报出两个版本号）。

## 验证

| 项 | 结果 |
| --- | --- |
| 通用构建 | `x86_64 arm64`，2.4 MB，无源码警告 |
| x86_64 切片 | Rosetta 下 `-v` 正常；`minos 13.0`，未引用 `swift_task_*` 等并发回部署符号 |
| zip 结构 | 解压顶层即 `RDM-ARM.app` + `安装说明.txt`，可直接拖入「应用程序」 |
| zip 内应用 | `-v` 报 `1.0.1`，`lipo` 报 `x86_64 arm64` |
| 包体 | 1.4 MB，SHA-256 `08fccd90fa2926fc1884418129b631205746f484f4e57da5c836984103a18aa4` |

关于链接器那条 `libswiftCompatibilityPacks.a ... missing arch 'x86_64'` 警告：**无害**。
该库提供的是 Swift 并发等特性的向后部署垫片，本应用用 `DispatchQueue` 而非 `async/await`，
`nm -u` 确认 x86_64 切片未引用任何 `swift_task_*` / `swift_async*` 符号。

## 给同事的注意事项（已写进 zip 内的安装说明）

- 应用是 **ad-hoc 签名**，没有 Apple 开发者签名与公证 ⇒ 下载后会被 Gatekeeper 拦下并
  报「已损坏」。需执行一次
  `xattr -dr com.apple.quarantine /Applications/RDM-ARM.app`。
- 它是**菜单栏应用，没有主窗口** —— 打开后要看屏幕顶部菜单栏，否则会以为没启动成功。
- 菜单栏图标可能因为菜单栏太满而被系统藏起来，需在菜单栏空白处按住 Command 拖动调整顺序。

## 正式发版下一步

Gitee 建仓后一条命令补齐双源（同 1.0.0 记录）：

```bash
cd /Volumes/dev/wwwroot/moo-RDM
git push -u origin master && git push origin 1.0.1
git ls-remote origin
```
