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

## 2026-10-30 — 菜单与显示状态的读取成本

- 两屏（Studio Display 5K + BenQ 4K）实测：顶层菜单构建约 2.8 ms → 1.5 ms；
  分辨率子菜单改为展开时构建，单次约 0.7 ms（18 行）。
- `DisplayManager.allDisplays()` 约 3.3 ms（含私有模式表）；只取当前状态的
  `allInfos()` 约 0.3 ms。菜单动作、按屏记忆、预设捕获已改用后者。
- 「显示 macOS 隐藏的模式」关闭时，菜单快照不再查询私有表；`-lm --usable-only`
  同理。
