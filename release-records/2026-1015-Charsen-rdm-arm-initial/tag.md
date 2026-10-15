# RDM-ARM 1.0.0 首次发布

状态：**GitHub 已发布；Gitee 侧待建仓** —— 已 commit 并打 annotated tag `1.0.0`，
GitHub（公开镜像）已直推并回读核验通过；Gitee（canonical）仓尚未创建，因此 `origin` 未推。

## 发布形态

- 本仓：`master` 顶点打 annotated tag **`1.0.0`**。
- 发布物是**源码**：`./build.sh` 用 swiftc 现场编译并组装 `.app`，不随仓分发二进制
  （`/build/` 已在 `.gitignore` 中）。这样每个使用者编译出的都是本机架构、ad-hoc 签名。
- 不包含任何部署步骤，也不需要。

## 背景与改动

上游 [avibrazil/RDM](https://github.com/avibrazil/RDM) 已停止维护，在新版 macOS 上
只能"凑合能用"。本仓是它的原生 Apple 芯片重写版，**不是 fork** —— 原版是
Objective-C++ + 私有 SPI，本仓是 Swift + 公开 API，未复用任何原版代码。

**失效根因**：原版依赖的私有结构体长度 `0xD4`(212B) 已过期。相关私有符号在 macOS 27 上
仍然存在，所以原版还能启动，但按固定偏移解码时 `depth`(0x10) 恒读出 8、`freq`(0xBC) 恒
读出 0 —— 菜单能列分辨率，刷新率与色深却是错的。

**方案**：改用公开的 `CGDisplayCopyAllDisplayModes` 加
`kCGDisplayShowDuplicateLowResolutionModes`。实测把可见模式数从 120 提升到 257
（含 137 个 HiDPI），私有 API 为 290 —— 差 33 个边缘低分模式，换来"系统升级不再失效"。

主要内容：

- 21 个 Swift 源文件，`build.sh` 只用 Command Line Tools（不需要 Xcode.app / SPM / CocoaPods）
- 显示引擎纯公开 API；私有 API（旋转、亮度）**全部隔离在 `Sources/Optional/`**，
  删掉该目录其余代码仍可编译运行
- 菜单栏：每屏子菜单、⚡️ 标 HiDPI、刷新率二级子菜单、当前模式打勾、自动去重
- 增强功能：Carbon 全局快捷键、每屏模式记忆 + 热插拔恢复、JSON 配置文件导入导出、旋转
- CLI 保留原版 `-w/-h/-s/-d/-lm/-ld` 并扩展 `--rotation/--json/--save/--apply/--selftest`
- `--selftest` 从进程内报告菜单栏图标实际位置 —— 外部无法验证（`CGWindowListCopyWindowInfo`
  不枚举菜单栏项，截屏需录屏权限）

首次提交前修掉的问题：菜单刷新率重复（`deduplicated()` 写了但从未被调用）、原生分辨率
误判（改用 `kDisplayModeNativeFlag`）、许可证声明不实（上游无许可证，原写 GPL v3）、
`-h` 歧义（裸 `-h` 现显示帮助）。

## 验证

macOS 27.0.1 / arm64 / BenQ PD2705U（原生 3840 × 2160）实机：

| 项 | 结果 |
| --- | --- |
| 构建 | `./build.sh` 通过，arm64、1.7 MB、ad-hoc 签名有效、可启动 |
| 枚举模式 | 120 → **257**（137 HiDPI） |
| 应用模式 | `CGConfigureDisplayWithDisplayMode` 返回 `kCGErrorSuccess` |
| 旋转 | `SLSSetDisplayRotation` 实机转 90° 并成功还原 |
| 亮度 | 外接屏不支持，菜单自动隐藏（能力探测驱动） |
| GUI 自检 | `--selftest` 报告菜单栏图标 on screen、菜单 11 个顶级项 |
| 命令行 | `-ld/-lm/-v/--json/-w -h -s/-h 1080/裸 -h` 逐项通过 |

**注意**：验证旋转与分辨率切换时改动了本机显示器模式，已还原为
`2304 × 1296 ⚡️ @ 60 Hz`。

## 双源发布状态

远端配置（沿用 `moo-scaffold` 的命名习惯）：`origin` → `git@gitee.com:charsen/moo-RDM.git`
（canonical），`github` → `https://github.com/charsen/moo-RDM.git`（公开镜像）。

| 远端 | 仓已建 | master | tag `1.0.0` | 回读核验 |
| --- | --- | --- | --- | --- |
| github（公开镜像） | ✅ 2026-10-15 建 | ✅ `f90e929` | ✅ annotated `d7c46eb`，peeled → `f90e929` | ✅ `git ls-remote` 一致 |
| origin（Gitee，canonical） | ❌ 待建 | — | — | — |

**卡点**：Gitee 不支持 push-to-create，建仓要走 API，需要 access token；本机
（env / keychain / credential helper / shell profile）均无 Gitee token，SSH key 虽可认证
但仓不存在。⇒ 需人工建仓。

`moo-RDM` 已登记进 `/Volumes/dev/wwwroot/git-local-pull.sh` 的 `REPOS_TABLE`
（`git-local-push.sh` 从该表取真值源），建仓后 fleet cron 即可自动同步 Gitee。

## 正式发版下一步

1. 在 Gitee 建 `charsen/moo-RDM`（**不要**勾选初始化 README，否则会与本地历史分叉）。
2. 一条命令补齐 Gitee 侧：

   ```bash
   cd /Volumes/dev/wwwroot/moo-RDM
   git push -u origin master && git push origin 1.0.0
   git ls-remote origin    # 回读核验 master 与 peeled tag 与 github 一致
   ```

3. 核验两端 `refs/heads/master` 与 `refs/tags/1.0.0^{}` 指向同一 commit `f90e929`。

> 上游 RDM 未附任何正式许可证文件（README 中作者表示"作者们会乐意你自由使用"）。
> 本仓按原样（as-is）提供，README 与 About 均已如实声明，**未臆造 GPL/MIT 之类的许可证**。
