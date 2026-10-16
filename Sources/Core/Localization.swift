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

        "menu.display": "Display %d",
        "menu.mainDisplay": "Main Display",
        "menu.builtIn": "Built-in",
        "menu.noDisplays": "No displays detected",
        "menu.noModes": "No modes match the current filter",
        "menu.currentResolution": "Current: %@",

        "menu.resolution": "Resolution",
        "menu.refreshRate": "Refresh rate",
        "menu.rotation": "Rotation",
        "menu.brightness": "Brightness",
        "menu.showAllModes": "Show modes macOS hides",
        "menu.showAllModes.hint": "Includes modes not usable for the desktop GUI",
        "menu.hiDPIOnly": "HiDPI modes only",
        "menu.preferences": "Preferences…",
        "menu.about": "About RDM-ARM",
        "menu.quit": "Quit RDM-ARM",
        "menu.resetToDefault": "Reset to system default",
        "menu.unsupported": "Not supported by this display",
        "menu.autoApplied": "Applied automatically",

        "rotation.0": "Standard (0°)",
        "rotation.90": "90°",
        "rotation.180": "180°",
        "rotation.270": "270°",

        "settings.title": "RDM-ARM Preferences",
        "settings.general": "General",
        "settings.advanced": "Advanced",
        "settings.about": "About",

        "settings.language": "Language",
        "settings.launchAtLogin": "Launch at login",
        "settings.launchAtLogin.hint": "Start RDM-ARM automatically when you log in",
        "settings.showUnusable": "List modes macOS hides",
        "settings.showUnusable.hint": "Show modes marked as unusable for the desktop GUI. These are the modes RDM is known for.",
        "settings.hiDPIOnly": "Only show HiDPI modes",
        "settings.hiDPIOnly.hint": "Hide all standard-resolution entries from the menu",
        "settings.permanent": "Apply changes permanently",
        "settings.permanent.hint": "Persist the chosen mode across restarts instead of only for this session",
        "settings.rememberPerDisplay": "Remember mode per display",
        "settings.rememberPerDisplay.hint": "Restore your chosen resolution when a display is reconnected",
        "settings.restoreOnWake": "Restore modes after wake",
        "settings.optionalModule": "Enable rotation, brightness and hidden HiDPI",
        "settings.optionalModule.hint": "These need private system interfaces. Rotation and brightness use them to write; hidden HiDPI lists the supersampled resolutions macOS generates but never exposes. Turn this off to keep the app strictly on public APIs.",
        "settings.hiddenHiDPI": "Hidden HiDPI modes",
        "settings.diagnostics": "Copy diagnostics",
        "settings.diagnostics.done": "Copied",

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

        "cli.usage": """
        RDM-ARM — set macOS displays to any resolution they support

        USAGE
          rdm-arm                       Launch the menu bar app
          rdm-arm -ld                   List connected displays
          rdm-arm -lm                   List every available mode
          rdm-arm -w <n> -h <n> [-s <n>] [-r <n>] [-d <n>]
                                        Switch resolution

        OPTIONS
          -w, --width <n>       Width in points
          -h, --height <n>      Height in points
          -s, --scale <n>       Backing scale: 1 for standard, 2 for HiDPI
          -r, --refresh <n>     Refresh rate in Hz (default: highest available)
              --rotation <n>    Rotate the display: 0, 90, 180 or 270
          -d, --display <n>     Display index (default: main display)
          -ld, --displays       List connected displays
          -lm, --modes          List available modes
              --all             Include modes macOS hides from the GUI
              --hidpi           Only consider HiDPI modes
              --json            Machine-readable output
          -v, --version         Print version
              --help            Show this help
              --selftest        Run GUI diagnostics (status item + menu) and exit
              --roundtrip       With --selftest: change the mode and roll it back

        EXAMPLES
          rdm-arm -w 1920 -h 1080 -s 2
          rdm-arm -lm --json | jq '.displays[].modes | length'
          rdm-arm --rotation 90 -d 1
        """,

        "lang.system": "Match system",
    ]

    // MARK: - Simplified Chinese

    private static let chinese: [String: String] = [
        "app.name": "RDM-ARM",
        "common.ok": "好",

        "menu.display": "显示器 %d",
        "menu.mainDisplay": "主显示器",
        "menu.builtIn": "内置",
        "menu.noDisplays": "未检测到显示器",
        "menu.noModes": "当前筛选条件下没有可用的模式",
        "menu.currentResolution": "当前：%@",

        "menu.resolution": "分辨率",
        "menu.refreshRate": "刷新率",
        "menu.rotation": "旋转",
        "menu.brightness": "亮度",
        "menu.showAllModes": "显示 macOS 隐藏的模式",
        "menu.showAllModes.hint": "包含无法用于桌面 GUI 的模式",
        "menu.hiDPIOnly": "仅显示 HiDPI 模式",
        "menu.preferences": "偏好设置…",
        "menu.about": "关于 RDM-ARM",
        "menu.quit": "退出 RDM-ARM",
        "menu.resetToDefault": "恢复系统默认",
        "menu.unsupported": "此显示器不支持",
        "menu.autoApplied": "已自动应用",

        "rotation.0": "标准 (0°)",
        "rotation.90": "90°",
        "rotation.180": "180°",
        "rotation.270": "270°",

        "settings.title": "RDM-ARM 偏好设置",
        "settings.general": "通用",
        "settings.advanced": "高级",
        "settings.about": "关于",

        "settings.language": "界面语言",
        "settings.launchAtLogin": "登录时启动",
        "settings.launchAtLogin.hint": "登录后自动启动 RDM-ARM",
        "settings.showUnusable": "列出 macOS 隐藏的模式",
        "settings.showUnusable.hint": "显示被标记为不可用于桌面 GUI 的模式，这正是 RDM 的看家功能。",
        "settings.hiDPIOnly": "仅显示 HiDPI 模式",
        "settings.hiDPIOnly.hint": "在菜单中隐藏所有标准分辨率条目",
        "settings.permanent": "永久应用更改",
        "settings.permanent.hint": "所选模式在重启后依然生效，而非仅本次会话有效",
        "settings.rememberPerDisplay": "按显示器记忆模式",
        "settings.rememberPerDisplay.hint": "显示器重新接入时恢复你选择的分辨率",
        "settings.restoreOnWake": "唤醒后恢复模式",
        "settings.optionalModule": "启用旋转、亮度与隐藏 HiDPI",
        "settings.optionalModule.hint": "这些功能依赖系统私有接口：旋转与亮度用它写入，隐藏 HiDPI 则用来列出 macOS 生成但未公开的超采样分辨率。关闭后应用将严格只使用公开 API。",
        "settings.hiddenHiDPI": "隐藏 HiDPI 模式",
        "settings.diagnostics": "复制诊断信息",
        "settings.diagnostics.done": "已复制",

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

        "cli.usage": """
        RDM-ARM — 将 macOS 显示器设为它支持的任何分辨率

        用法
          rdm-arm                       启动菜单栏应用
          rdm-arm -ld                   列出已连接的显示器
          rdm-arm -lm                   列出全部可用模式
          rdm-arm -w <n> -h <n> [-s <n>] [-r <n>] [-d <n>]
                                        切换分辨率

        选项
          -w, --width <n>       宽度（点）
          -h, --height <n>      高度（点）
          -s, --scale <n>       缩放：1 为标准，2 为 HiDPI
          -r, --refresh <n>     刷新率 Hz（默认：最高可用）
              --rotation <n>    旋转显示器：0、90、180 或 270
          -d, --display <n>     显示器索引（默认：主显示器）
          -ld, --displays       列出已连接的显示器
          -lm, --modes          列出可用模式
              --all             包含 macOS 从 GUI 隐藏的模式
              --hidpi           只考虑 HiDPI 模式
              --json            输出机器可读格式
          -v, --version         显示版本
              --help            显示帮助
              --selftest        运行 GUI 自检（菜单栏图标 + 菜单）并退出
              --roundtrip       配合 --selftest：真实切换一次分辨率再还原

        示例
          rdm-arm -w 1920 -h 1080 -s 2
          rdm-arm -lm --json | jq '.displays[].modes | length'
          rdm-arm --rotation 90 -d 1
        """,

        "lang.system": "跟随系统",
    ]
}
