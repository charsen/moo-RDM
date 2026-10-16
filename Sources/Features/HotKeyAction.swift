import Foundation

/// Stable identifiers for the actions a global shortcut can trigger.
///
/// These strings are persisted in `UserDefaults`, so they must not be renamed
/// without a migration.
///
/// Per-profile shortcuts used to live here as `profile.<uuid>`. The profile
/// feature was removed in 1.0.4, so any such entries left in `UserDefaults` are
/// simply never read — they are inert, not a migration hazard.
public enum HotKeyAction {

    public static let nextResolution = "nextResolution"
    public static let previousResolution = "previousResolution"
    public static let toggleHiDPI = "toggleHiDPI"

    /// The three always-available actions, in menu order.
    public static let builtIn: [String] = [nextResolution, previousResolution, toggleHiDPI]

    public static func label(for action: String) -> String {
        switch action {
        case nextResolution:     return L10n.t("settings.hotkeyNext")
        case previousResolution: return L10n.t("settings.hotkeyPrevious")
        case toggleHiDPI:        return L10n.t("settings.hotkeyToggleHiDPI")
        default:                 return action
        }
    }
}
