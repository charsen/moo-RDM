import Foundation

/// Interface language. Defaults to whatever the system is set to.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case english
    case simplifiedChinese

    public var displayName: String {
        switch self {
        case .system:            return L10n.t("lang.system")
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

public extension Notification.Name {
    static let rdmLanguageChanged = Notification.Name("io.rdmarm.languageChanged")
}

/// Tiny dependency-free localisation layer.
///
/// The app ships with English and Simplified Chinese tables and picks one at
/// runtime, so the interface language can be switched without a relaunch.
public enum L10n {

    public static var language: AppLanguage = .system {
        didSet {
            guard oldValue != language else { return }
            NotificationCenter.default.post(name: .rdmLanguageChanged, object: nil)
        }
    }

    /// Resolved language code, e.g. "en" or "zh-Hans".
    public static var effectiveCode: String {
        switch language {
        case .english:           return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    /// Looks up a key, falling back to English and then to the key itself.
    public static func t(_ key: String) -> String {
        let table = effectiveCode == "zh-Hans" ? chinese : english
        return table[key] ?? english[key] ?? key
    }

    /// Formatted lookup, e.g. `L10n.t("menu.displayN", 2)`.
    public static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    // MARK: - English

    private static let english: [String: String] = [
        "app.name": "RDM-ARM",
        "common.ok": "OK",
        "common.cancel": "Cancel",

        "menu.display": "Display %d",
        "menu.mainDisplay": "Main Display",
        "menu.mainShort": "Main",
        "menu.builtinShort": "Built-in",
        "menu.noDisplays": "No displays detected",
        "menu.noModes": "No modes match the current filter",
        "menu.native": "native %@",

        "menu.resolution": "Resolution",
        "menu.allDisplays": "All displays",
        "menu.sameResolution": "Same resolution",
        "menu.matchMain": "Match main display",
        "menu.matchMain.hint": "Apply the main display's current resolution to every display",
        "menu.mirrorAll": "Mirror all displays to main",
        "menu.stopMirroring": "Stop mirroring",
        "menu.noCommonResolution": "No resolution is available on every display",
        "menu.missingOn": "Not available on %@",
        "menu.customResolution": "Add scaled resolution…",
        "menu.removeCustomResolution": "Remove scaled resolution",
        "menu.refreshRate": "Refresh rate",
        "menu.standardResolutions": "Standard resolutions (1×)",
        "menu.refreshAtGeometry": "%@ @ %@",
        "menu.rotation": "Rotation",
        "menu.brightness": "Brightness",
        "menu.showAllModes": "Show modes macOS hides",
        "menu.showAllModes.hint": "Includes modes not usable for the desktop GUI",
        "menu.hiDPIOnly": "HiDPI modes only",
        "menu.hiDPIOnly.hint": "Keep the main list HiDPI-only; standard entries move to their own submenu",
        "menu.preferences": "Preferences…",
        "menu.about": "About RDM-ARM",
        "menu.quit": "Quit RDM-ARM",
        "menu.resetToDefault": "Reset to system default",
        "menu.forgetRemembered": "Forget remembered mode",
        "menu.unsupported": "not for desktop GUI",

        "menu.presets": "Presets",
        "menu.preset.save": "Save current setup…",
        "menu.preset.save.title": "Save current setup",
        "menu.preset.save.hint": "Name this preset. It stores each display's resolution, rotation, mirroring and brightness.",
        "menu.preset.defaultName": "Setup %d",
        "menu.preset.delete": "Delete preset",
        "menu.preset.delete.confirm": "Delete “%@”?",
        "menu.preset.delete.hint": "This cannot be undone.",
        "menu.preset.none": "No presets yet",
        "menu.preset.partial": "Preset applied with issues",
        "menu.preset.missing": "Not connected: %@",
        "menu.preset.rate": "%@: %d Hz is not available, using %d Hz",
        "menu.preset.summary.mirrors": "%d mirror link(s)",

        "menu.capabilities": "EDID and refresh limits",
        "menu.capabilities.link": "Budget: %@",
        "menu.capabilities.native": "Native timing: %@",
        "menu.capabilities.hidden": "Declared, not offered: %@",
        "menu.capabilities.nothingHidden": "Panel declares nothing beyond the listed modes",
        "menu.capabilities.noEDID": "EDID not readable for this display",
        "menu.capabilities.override": "Override installed",
        "menu.capabilities.scaled": "Scaled resolutions: %@",
        "menu.capabilities.cliHint": "Beyond-limit rates need the CLI: rdm-arm --custom-timing",
        "menu.capabilities.inert": "Beyond-limit rates need an EDID override — Apple silicon ignores it, so this machine can only report",

        "window.custom.title": "Add scaled resolution — %@",
        "window.custom.display": "%@ · native %@",
        "window.custom.preset": "Common sizes…",
        "window.custom.preset.available": "available",
        "window.custom.width": "Width",
        "window.custom.height": "Height",
        "window.custom.backing": "Backing store %d × %d (2×)",
        "window.custom.add": "Add",
        "window.custom.remove": "Remove",
        "window.custom.installed": "Custom resolutions",
        "window.custom.none": "None yet",
        "window.custom.note": "Writes a display override, which needs one administrator password. macOS only reads it when the display is attached, so reconnect the display (or restart) before the new size appears in the Resolution menu.",
        "window.custom.close": "Close",
        "window.custom.written": "Override written",
        "window.custom.written.hint": "%@ was added. Reconnect the display or restart to make it appear in the Resolution menu.",
        "window.custom.removed": "Override updated",
        "window.custom.removed.hint": "%@ was removed. Reconnect the display or restart to drop it from the menu.",
        "window.custom.busy": "Writing…",

        "rotation.0": "Standard (0°)",
        "rotation.90": "90°",
        "rotation.180": "180°",
        "rotation.270": "270°",

        "settings.title": "RDM-ARM Preferences",
        "settings.general": "General",
        "settings.advanced": "Advanced",
        "settings.about": "About",

        "settings.language": "Language",
        "settings.showUnusable": "List modes macOS hides",
        "settings.showUnusable.hint": "Show modes marked as unusable for the desktop GUI. These are the modes RDM is known for.",
        "settings.hiDPIOnly": "HiDPI modes only",
        "settings.hiDPIOnly.hint": "Keep the main list HiDPI-only; standard entries move to their own submenu",
        "settings.section.changes": "Mode changes",
        "settings.permanent": "Apply changes permanently",
        "settings.permanent.hint": "Persist the chosen mode across restarts instead of only for this session",
        "settings.section.memory": "Mode memory",
        "settings.rememberPerDisplay": "Remember mode per display",
        "settings.rememberPerDisplay.hint": "Restore your chosen resolution when a display is reconnected",
        "settings.restoreOnWake": "Restore modes after wake",
        "settings.restoreOnWake.hint": "Re-apply the remembered mode when the Mac wakes up",
        "settings.forgetAll": "Forget all remembered modes",
        "settings.forgetAll.hint": "Displays keep their current mode; only the automatic restore is removed",
        "settings.forgetAll.confirm": "Forget every remembered resolution?",
        "settings.forgetAll.confirm.hint": "This cannot be undone. Displays are not changed right now.",
        "settings.section.private": "Private interfaces",
        "settings.optionalModule": "Enable rotation, brightness and hidden HiDPI",
        "settings.optionalModule.hint": "These need private system interfaces. Rotation and brightness use them to write; hidden HiDPI lists the supersampled resolutions macOS generates but never exposes. Turn this off to keep the app strictly on public APIs.",
        "settings.hiddenHiDPI": "Hidden HiDPI modes",
        "settings.diagnostics.title": "Diagnostics",
        "settings.diagnostics": "Copy diagnostics",
        "settings.diagnostics.done": "Copied",
        "settings.diagnostics.hint": "The full report is generated when you copy it.",
        "settings.status.unavailable": "unavailable on this system",
        "settings.status.available": "available",
        "settings.status.disabled": "disabled",
        "settings.status.brightness": "available on %d display(s)",
        "settings.status.hiddenHiDPI": "%d extra mode(s) offered",
        "settings.status.none": "none offered",

        "about.version": "Version %@",
        "about.credits": "A native Apple silicon rework of RDM by Avi Alkalay.",
        "about.license": "Upstream RDM carries no formal licence; this rework is provided as-is.",
        "about.engine": "Display engine: public CoreGraphics API only.",
        "about.repo": "Source code",

        "error.noSuchDisplay": "No display matches index %d",
        "error.noSuchMode": "No mode matches %@",
        "error.setModeFailed": "Could not set the mode (CoreGraphics error %d)",
        "error.rotationFailed": "Could not set rotation (error %d)",
        "error.rotationUnsupported": "This display does not support rotation",
        "error.brightnessUnsupported": "This display does not support software brightness control",
        "error.privateModeBatch": "A batch change cannot include a mode that only exists in the private table",
        "error.resolutionRange": "Width and height must be between 320 and 8192 points (backing store up to 16384)",
        "error.resolutionAlreadyOffered": "%d × %d is already available at %d Hz",
        "error.resolutionAlreadyInstalled": "%@ is already installed",
        "error.presetEmpty": "No displays to capture",

        "error.timingOptionalDisabled": "The optional module is off — turn it on in Preferences first",
        "error.timingNoEDID": "Could not read this display's EDID",
        "error.timingNoNative": "This display reports no native timing to build on",
        "error.timingGeometry": "The native timing cannot be scaled to %@",
        "error.timingClockCeiling": "This timing needs about %d MHz, but an EDID descriptor's pixel clock tops out at 655 MHz. Add a scaled resolution from the menu instead — it adds a backing size without a new timing",
        "error.timingBudget": "%d Hz is beyond what this link allows (about %d Hz)",
        "error.timingNoSlot": "The EDID has no free descriptor slot for another timing",
        "error.timingSyntax": "Expected a timing like 3840x2160@75",
        "error.refreshOutOfRange": "A refresh rate has to be above 1 Hz and at most 1000 Hz",
        "error.jsonUnsupportedEDID": "--edid has no JSON form: the EDID is binary. Use --emit-edid <path> to write the blob out",
        "error.timingOverride": "The display override could not be prepared",
        "error.overrideCancelled": "Cancelled — nothing was changed",
        "error.overrideFailed": "The display override could not be written",
        "error.overrideInert": "Apple silicon does not apply /Library display overrides — the file would be written and ignored (measured: cable re-plug, display sleep, system sleep all left the mode list unchanged)",

        "capabilities.link": "link %d MHz",
        "capabilities.range": "vendor range %@ Hz",
        "capabilities.max": "vendor max %d Hz",
        "capabilities.cap": "%d × %d tops out near %d Hz",
        "capabilities.unknown": "unknown — optional module off",

        "cli.timingDryRun": "    not written — add --write to install, --keep to skip the rollback",
        "cli.timingDryRunInert": "    not written — --write is ignored on Apple silicon, so this is a calculation only",
        "cli.timingWatchdog": "    rolling back in %d s unless --keep is given…",
        "cli.timingKept": "    kept — remove later with --revert",
        "cli.timingReverted": "%@: display override reverted",
        "cli.rateSubstituted": "    note: %d Hz is not offered at this size — using %d Hz (available: %@)",

        "cli.usage": """
        RDM-ARM — set macOS displays to any resolution they support

        USAGE
          rdm-arm                       Launch the menu bar app
          rdm-arm -ld                   List connected displays
          rdm-arm -lm                   List every available mode
          rdm-arm -w <n> -h <n> [-s <n>] [-r <n>] [-d <n>]
                                        Switch resolution
          rdm-arm --edid [-d <n>]       Dump the panel's own description
          rdm-arm --capabilities        What the hardware allows beyond the list
          rdm-arm --refresh-audit [-r <n>]
                                        Why a rate is or is not reachable
          rdm-arm --custom-timing 1920x1080@75 --write
                                        Try a rate the panel never advertised

        OPTIONS
          -w, --width <n>       Width in points
          -h, --height <n>      Height in points
          -s, --scale <n>       Backing scale: 1 for standard, 2 for HiDPI
          -r, --refresh <n>     Refresh rate in Hz (default: highest available)
              --rotation <n>    Rotate the display: 0, 90, 180 or 270
          -d, --display <n>     Display index (default: main display)
          -ld, --displays       List connected displays
          -lm, --modes          List available modes
              --edid            Dump EDID: timings, link budget, refresh range
              --capabilities    Summarise hidden rates and the hardware ceiling
              --refresh-audit   Explain gaps between declared, offered and possible rates
              --custom-timing   Synthesise <width>x<height>@<hz>; add --write to install
              --write           Install the EDID override (asks for admin rights)
              --keep            Keep the override instead of rolling it back
              --revert          Remove a previously installed EDID override
              --sleep-wake      Force re-enumeration with a display power cycle
              --timeout <n>     Seconds before the automatic rollback (default 20)
              --emit-edid <p>   Write the patched EDID to <p> for inspection
              --selftest-timing Run the EDID and timing self test, then exit
              --all             Include modes macOS hides from the GUI (the CLI default)
              --usable-only     Exclude modes macOS hides from the GUI
              --hidpi           Only consider HiDPI modes
              --permanent       Persist the chosen mode across restarts
              --json            Machine-readable output
          -v, --version         Print version
              --help            Show this help
              --selftest        Run GUI diagnostics (status item + menu) and exit
              --roundtrip       With --selftest: change the mode and roll it back

        EXIT CODES
          0  success (no arguments also prints this help)
          1  runtime failure (no display, unreadable EDID, refused timing)
          2  bad arguments
          3  --write refused: an EDID override is ignored on Apple silicon

        EXAMPLES
          rdm-arm -w 1920 -h 1080 -s 2
          rdm-arm -lm --json | jq '.displays[].modes | length'
          rdm-arm --rotation 90 -d 1
          rdm-arm --capabilities -d 1
          rdm-arm --refresh-audit -r 60 -d 1
          rdm-arm --refresh-audit -r 75 --json | jq .verdict
          rdm-arm --custom-timing 1920x1080@75 --write --keep -d 1
        """,

        "lang.system": "Match system",
    ]

    // MARK: - Simplified Chinese

    private static let chinese: [String: String] = [
        "app.name": "RDM-ARM",
        "common.ok": "确定",
        "common.cancel": "取消",

        "menu.display": "显示器 %d",
        "menu.mainDisplay": "主显示器",
        "menu.mainShort": "主屏",
        "menu.builtinShort": "内建",
        "menu.noDisplays": "未检测到显示器",
        "menu.noModes": "当前筛选条件下没有可用的模式",
        "menu.native": "原生 %@",

        "menu.resolution": "分辨率",
        "menu.allDisplays": "所有显示器",
        "menu.sameResolution": "相同分辨率",
        "menu.matchMain": "与主显示器一致",
        "menu.matchMain.hint": "把主显示器当前的分辨率应用到每一块屏",
        "menu.mirrorAll": "镜像所有显示器到主屏",
        "menu.stopMirroring": "停止镜像",
        "menu.noCommonResolution": "没有一块屏都支持的分辨率",
        "menu.missingOn": "%@ 不支持",
        "menu.customResolution": "添加缩放分辨率…",
        "menu.removeCustomResolution": "移除缩放分辨率",
        "menu.refreshRate": "刷新率",
        "menu.standardResolutions": "标准分辨率（非 HiDPI）",
        "menu.refreshAtGeometry": "%@ @ %@",
        "menu.rotation": "旋转",
        "menu.brightness": "亮度",
        "menu.showAllModes": "显示 macOS 隐藏的模式",
        "menu.showAllModes.hint": "包含无法用于桌面 GUI 的模式",
        "menu.hiDPIOnly": "仅显示 HiDPI 模式",
        "menu.hiDPIOnly.hint": "主列表只留 HiDPI，标准分辨率收进单独的子菜单",
        "menu.preferences": "偏好设置…",
        "menu.about": "关于 RDM-ARM",
        "menu.quit": "退出 RDM-ARM",
        "menu.resetToDefault": "恢复系统默认",
        "menu.forgetRemembered": "忘掉记住的模式",
        "menu.unsupported": "不适于桌面 GUI",

        "menu.presets": "预设",
        "menu.preset.save": "保存当前配置…",
        "menu.preset.save.title": "保存当前配置",
        "menu.preset.save.hint": "给这套配置起个名字。会记录每块屏的分辨率、旋转、镜像关系和亮度。",
        "menu.preset.defaultName": "配置 %d",
        "menu.preset.delete": "删除预设",
        "menu.preset.delete.confirm": "删除「%@」？",
        "menu.preset.delete.hint": "此操作不可撤销。",
        "menu.preset.none": "还没有预设",
        "menu.preset.partial": "预设已应用，但有未完成项",
        "menu.preset.missing": "未连接：%@",
        "menu.preset.rate": "%@：不提供 %d Hz，已使用 %d Hz",
        "menu.preset.summary.mirrors": "%d 组镜像",

        "menu.capabilities": "EDID 与刷新上限",
        "menu.capabilities.link": "带宽：%@",
        "menu.capabilities.native": "原生时序：%@",
        "menu.capabilities.hidden": "已声明但未提供：%@",
        "menu.capabilities.nothingHidden": "面板没有声明列表之外的模式",
        "menu.capabilities.noEDID": "读不到此显示器的 EDID",
        "menu.capabilities.override": "已安装 override",
        "menu.capabilities.scaled": "自定义缩放分辨率：%@",
        "menu.capabilities.cliHint": "超出上限的刷新率需用命令行：rdm-arm --custom-timing",
        "menu.capabilities.inert": "超出上限的刷新率需改写 EDID——Apple 芯片不读取该 override，本机只能看不能改",

        "window.custom.title": "添加缩放分辨率 — %@",
        "window.custom.display": "%@ · 原生 %@",
        "window.custom.preset": "常用尺寸…",
        "window.custom.preset.available": "已可用",
        "window.custom.width": "宽",
        "window.custom.height": "高",
        "window.custom.backing": "渲染尺寸 %d × %d（2×）",
        "window.custom.add": "添加",
        "window.custom.remove": "移除",
        "window.custom.installed": "自定义分辨率",
        "window.custom.none": "还没有",
        "window.custom.note": "会写入显示器 override，需要一次管理员密码。macOS 只在显示器重新挂载时读取它，所以新尺寸要等重新插拔显示器（或重启）后才会出现在分辨率菜单里。",
        "window.custom.close": "关闭",
        "window.custom.written": "已写入 override",
        "window.custom.written.hint": "%@ 已添加。重新插拔显示器或重启后，它会出现在分辨率菜单里。",
        "window.custom.removed": "已更新 override",
        "window.custom.removed.hint": "%@ 已移除。重新插拔显示器或重启后，它会从菜单里消失。",
        "window.custom.busy": "正在写入…",

        "rotation.0": "标准 (0°)",
        "rotation.90": "90°",
        "rotation.180": "180°",
        "rotation.270": "270°",

        "settings.title": "RDM-ARM 偏好设置",
        "settings.general": "通用",
        "settings.advanced": "高级",
        "settings.about": "关于",

        "settings.language": "界面语言",
        "settings.showUnusable": "列出 macOS 隐藏的模式",
        "settings.showUnusable.hint": "显示被标记为不可用于桌面 GUI 的模式，这正是 RDM 的看家功能。",
        "settings.hiDPIOnly": "仅显示 HiDPI 模式",
        "settings.hiDPIOnly.hint": "主列表只留 HiDPI，标准分辨率收进单独的子菜单",
        "settings.section.changes": "模式更改",
        "settings.permanent": "永久应用更改",
        "settings.permanent.hint": "所选模式在重启后依然生效，而非仅本次会话有效",
        "settings.section.memory": "模式记忆",
        "settings.rememberPerDisplay": "按显示器记忆模式",
        "settings.rememberPerDisplay.hint": "显示器重新接入时恢复你选择的分辨率",
        "settings.restoreOnWake": "唤醒后恢复模式",
        "settings.restoreOnWake.hint": "Mac 唤醒后重新应用记住的模式",
        "settings.forgetAll": "清除全部已记住的模式",
        "settings.forgetAll.hint": "显示器保持当前模式，只是不再自动恢复",
        "settings.forgetAll.confirm": "清除所有已记住的分辨率？",
        "settings.forgetAll.confirm.hint": "此操作不可撤销；当前显示器不会发生变化。",
        "settings.section.private": "私有接口",
        "settings.optionalModule": "启用旋转、亮度与隐藏 HiDPI",
        "settings.optionalModule.hint": "这些功能依赖系统私有接口：旋转与亮度用它写入，隐藏 HiDPI 则用来列出 macOS 生成但未公开的超采样分辨率。关闭后应用将严格只使用公开 API。",
        "settings.hiddenHiDPI": "隐藏 HiDPI 模式",
        "settings.diagnostics.title": "诊断信息",
        "settings.diagnostics": "复制诊断信息",
        "settings.diagnostics.done": "已复制",
        "settings.diagnostics.hint": "点击复制时才会生成完整报告。",
        "settings.status.unavailable": "此系统不支持",
        "settings.status.available": "可用",
        "settings.status.disabled": "已关闭",
        "settings.status.brightness": "%d 块显示器可用",
        "settings.status.hiddenHiDPI": "额外提供 %d 个模式",
        "settings.status.none": "没有额外模式",

        "about.version": "版本 %@",
        "about.credits": "基于 Avi Alkalay 的 RDM 重写的原生 Apple 芯片版本。",
        "about.license": "上游 RDM 未附正式许可证，本重写版按原样提供。",
        "about.engine": "显示引擎：仅使用公开 CoreGraphics API。",
        "about.repo": "源代码",

        "error.noSuchDisplay": "没有索引为 %d 的显示器",
        "error.noSuchMode": "没有匹配 %@ 的模式",
        "error.setModeFailed": "无法设置该模式（CoreGraphics 错误 %d）",
        "error.rotationFailed": "无法设置旋转（错误 %d）",
        "error.rotationUnsupported": "此显示器不支持旋转",
        "error.brightnessUnsupported": "此显示器不支持软件亮度控制",
        "error.privateModeBatch": "批量切换不能包含只存在于私有模式表里的模式",
        "error.resolutionRange": "宽和高需要在 320 到 8192 点之间（渲染尺寸不超过 16384）",
        "error.resolutionAlreadyOffered": "%d × %d 已经可用（%d Hz）",
        "error.resolutionAlreadyInstalled": "%@ 已经安装",
        "error.presetEmpty": "没有可捕获的显示器",

        "error.timingOptionalDisabled": "可选模块已关闭，请先在偏好设置中打开",
        "error.timingNoEDID": "读不到此显示器的 EDID",
        "error.timingNoNative": "此显示器没有可用于推算的原生时序",
        "error.timingGeometry": "原生时序无法缩放到 %@",
        "error.timingClockCeiling": "这个时序需要约 %d MHz，而 EDID 描述符的像素时钟上限是 655 MHz。请改用菜单里的「添加缩放分辨率…」——它只增加渲染尺寸，不新增时序",
        "error.timingBudget": "%d Hz 超出链路能力（约 %d Hz）",
        "error.timingNoSlot": "EDID 里没有空闲的时序描述符槽位",
        "error.timingSyntax": "格式应为 3840x2160@75",
        "error.refreshOutOfRange": "刷新率需要高于 1 Hz 且不超过 1000 Hz",
        "error.jsonUnsupportedEDID": "--edid 没有 JSON 形式：EDID 本身就是二进制。要导出原始数据，用 --emit-edid <路径>",
        "error.timingOverride": "无法准备显示器 override",
        "error.overrideCancelled": "已取消，未做任何更改",
        "error.overrideFailed": "无法写入显示器 override",
        "error.overrideInert": "Apple 芯片不读取 /Library 显示 override：文件会写进去但被忽略（热插拔、显示器休眠、整机睡眠实测均未改变模式表）",

        "capabilities.link": "链路 %d MHz",
        "capabilities.range": "厂商范围 %@ Hz",
        "capabilities.max": "厂商上限 %d Hz",
        "capabilities.cap": "%d × %d 约 %d Hz 上限",
        "capabilities.unknown": "未知 —— 可选模块已关闭",

        "cli.timingDryRun": "    未写入 —— 加 --write 生效，加 --keep 跳过自动回滚",
        "cli.timingDryRunInert": "    未写入 —— Apple 芯片上 --write 会被忽略，这里只是算给你看",
        "cli.timingWatchdog": "    %d 秒后自动回滚，除非加上 --keep…",
        "cli.timingKept": "    已保留 —— 之后可用 --revert 移除",
        "cli.timingReverted": "%@：显示器 override 已回滚",
        "cli.rateSubstituted": "    注意：该尺寸不提供 %d Hz，已使用 %d Hz（可用：%@）",

        "cli.usage": """
        RDM-ARM — 将 macOS 显示器设为它支持的任何分辨率

        用法
          rdm-arm                       启动菜单栏应用
          rdm-arm -ld                   列出已连接的显示器
          rdm-arm -lm                   列出全部可用模式
          rdm-arm -w <n> -h <n> [-s <n>] [-r <n>] [-d <n>]
                                        切换分辨率
          rdm-arm --edid [-d <n>]       输出面板自己的描述
          rdm-arm --capabilities        硬件在系统列表之外还剩多少余量
          rdm-arm --refresh-audit [-r <n>]
                                        某个刷新率为什么拿不到
          rdm-arm --custom-timing 1920x1080@75 --write
                                        试一个面板从未声明过的刷新率

        选项
          -w, --width <n>       宽度（点）
          -h, --height <n>      高度（点）
          -s, --scale <n>       缩放：1 为标准，2 为 HiDPI
          -r, --refresh <n>     刷新率 Hz（默认：最高可用）
              --rotation <n>    旋转显示器：0、90、180 或 270
          -d, --display <n>     显示器索引（默认：主显示器）
          -ld, --displays       列出已连接的显示器
          -lm, --modes          列出可用模式
              --edid            输出 EDID：时序、带宽、刷新范围
              --capabilities    汇总隐藏刷新率与硬件上限
              --refresh-audit   逐分辨率说明「声明 / 系统给出 / 链路可行」的差距
              --custom-timing   合成 <宽>x<高>@<Hz>；加 --write 才会写入
              --write           写入 EDID override（需要管理员授权）
              --keep            保留 override，不自动回滚
              --revert          移除之前安装的 EDID override
              --sleep-wake      用显示器断电/上电强制重新枚举
              --timeout <n>     自动回滚前的秒数（默认 20）
              --emit-edid <p>   把打好补丁的 EDID 写到 <p> 以便检查
              --selftest-timing 运行 EDID 与时序自检后退出
              --all             包含 macOS 从 GUI 隐藏的模式（命令行默认）
              --usable-only     排除 macOS 从 GUI 隐藏的模式
              --hidpi           只考虑 HiDPI 模式
              --permanent       所选模式在重启后依然生效
              --json            输出机器可读格式
          -v, --version         显示版本
              --help            显示帮助
              --selftest        运行 GUI 自检（菜单栏图标 + 菜单）并退出
              --roundtrip       配合 --selftest：真实切换一次分辨率再还原

        退出码
          0  成功（不带参数也会打印本帮助）
          1  运行失败（没有显示器、读不到 EDID、时序被拒绝）
          2  参数错误
          3  --write 被拒绝：Apple 芯片不读取 EDID override

        示例
          rdm-arm -w 1920 -h 1080 -s 2
          rdm-arm -lm --json | jq '.displays[].modes | length'
          rdm-arm --rotation 90 -d 1
          rdm-arm --capabilities -d 1
          rdm-arm --refresh-audit -r 60 -d 1
          rdm-arm --refresh-audit -r 75 --json | jq .verdict
          rdm-arm --custom-timing 1920x1080@75 --write --keep -d 1
        """,

        "lang.system": "跟随系统",
    ]
}
