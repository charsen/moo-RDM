# NOTES

> 只记录尚未纳入正式规则的已验证事实，一条一事。事故条目写日期、症状、根因与解法。

## 2026-10-30 — `scale-resolutions` 在 Apple 芯片上会被读取

- 症状：Studio Display 没有 `2304 × 1296`，同机的 BenQ 4K 有；两边无法设成同一分辨率。
- 根因：5K 面板的模式阶梯来自系统 override plist 的 `scale-resolutions`
  （`DisplayVendorID-610/DisplayProductID-ae46`）。条目缺失，公开枚举与私有模式表都只有 26 档。
- 解法：在 `/Library/Displays/Contents/Resources/Overrides` 的同名 plist 追加 8 字节
  big-endian `(4608, 2592)`，重新插拔后模式表 26 → 28，`2304 × 1296 ⚡️` 可直接切换。
- 边界：被 Apple 芯片忽略的是 `IODisplayEDID`，不是整个 override 目录。
  `CGDisplayModeCreate` 连重建当前模式都返回 `NULL`；`IOServiceRequestProbe` 返回
  `kIOReturnUnsupported`，重配当前模式也不会重读——只能重新挂载/重启。
- 派生：一条 8 字节条目会同时生成 HiDPI 点尺寸和 1× 的 `4608 × 2592`；后者没有面板声明过的
  输出时序，菜单通过 `DisplayMode.isCustomStandardTwin` 隐藏，CLI 仍如实列出。

## 2026-10-30 — 菜单、设置窗口与显示状态的读取成本

- 两屏（Studio Display 5K + BenQ 4K）实测：顶层菜单构建 2.8 ms → 0.35–0.42 ms；
  显示、分辨率、刷新率子菜单都改为展开时构建（分辨率子菜单约 0.7 ms）。
- 设置窗口首次创建 27 ms → 12 ms（只构建通用页）；偏好切换从 20 ms 级整窗重建
  → 0.2 ms 原地更新。高级页首次展开仍约 36 ms 的 AppKit 布局；窗口空闲 0.35 s
  后预热，预热后首次点击约 8 ms。
- `DisplayManager.allDisplays()` 约 3.3 ms（含私有模式表）；只取当前状态的
  `allInfos()` 约 0.3 ms。菜单动作、按屏记忆、预设捕获已改用后者。
- 空 CoreGraphics 事务约 0.2–0.3 ms；目标状态已一致时直接跳过，约 0.015 ms，
  且不再触发桌面重排。
- 「显示 macOS 隐藏的模式」关闭时，菜单快照不再查询私有表；`-lm --usable-only`
  同理。

## 2026-10-30 — 偏好域迁移

1.2.1 使用 `io.rdmarm.RDM-ARM`，1.2.2 起改为 `com.mooeen.rdm`。1.3.0 首次启动
在新域仍为空时一次性复制旧域的偏好与按屏记忆；新域已有设置时不覆盖。

## 2026-10-30 — 预设排列与记忆恢复提示

- `PresetDisplay` 记录 `CGDisplayBounds` 的原点；应用时在同一个事务里调用
  `CGConfigureDisplayOrigin`，镜像 slave 跳过原点（位置跟随主屏）。
- 主屏指定没有公开的 CoreGraphics API，预设仍不记录。
- 记忆恢复的折衷（刷新率替换、模式缺失、应用失败）记录在
  `ModeMemoryController.lastRestoreNotes`，菜单打开对应显示时显示一行。

## 2026-10-30 — 主屏指定与虚拟屏暂不实现

- macOS 27 的 CoreGraphics 只有 `CGConfigureDisplayOrigin`（排列位置），没有设置主屏的
  公开 API；探测 `SLSSetMainDisplay`、`CGSSetMainDisplay`、`CoreDisplay_Display_SetMain`
  等符号均不存在。预设因此记录排列位置但不记录主屏。
- 虚拟屏（`CGVirtualDisplay` + 硬件镜像）可以在 Apple 芯片上补尺寸，但需要虚拟屏生命周期、
  镜像拓扑与清理逻辑，暂不纳入；已在 TODOS 记录。
