import CoreGraphics
import Foundation

/// A resolution the user asked us to restore automatically for a given display.
public struct RememberedMode: Codable, Hashable, Sendable {
    public var displayName: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var refreshRate: Double
    /// `nil` when rotation was never touched, so we do not force it on reconnect.
    public var rotation: Double?

    public init(displayName: String, width: Int, height: Int,
                scale: Double, refreshRate: Double, rotation: Double? = nil) {
        self.displayName = displayName
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
        self.rotation = rotation
    }
}

/// Persisted user settings, backed by `UserDefaults`.
public final class Preferences {

    public static let shared = Preferences()

    /// Posted whenever any preference changes, so open windows and the menu refresh.
    public static let didChangeNotification = Notification.Name("io.rdmarm.preferencesChanged")

    private enum Key {
        static let showUnusableModes   = "showUnusableModes"
        static let hiDPIOnly           = "hiDPIOnly"
        static let permanentChanges    = "permanentChanges"
        static let rememberPerDisplay  = "rememberPerDisplay"
        static let restoreOnWake       = "restoreOnWake"
        static let confirmModeChanges  = "confirmModeChanges"
        static let enableOptionalModule = "enableOptionalModule"
        static let language            = "language"
        static let hotkeys             = "hotkeys"
        static let rememberedModes     = "rememberedModes"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showUnusableModes: true,
            Key.hiDPIOnly: false,
            Key.permanentChanges: false,
            Key.rememberPerDisplay: true,
            Key.restoreOnWake: true,
            Key.confirmModeChanges: true,
            Key.enableOptionalModule: true,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
    }

    // MARK: - Toggles

    /// List modes macOS hides from System Settings. On by default — it is the point of the app.
    public var showUnusableModes: Bool {
        get { defaults.bool(forKey: Key.showUnusableModes) }
        set { defaults.set(newValue, forKey: Key.showUnusableModes); changed() }
    }

    /// Hide every standard-resolution entry, leaving only HiDPI ones.
    public var hiDPIOnly: Bool {
        get { defaults.bool(forKey: Key.hiDPIOnly) }
        set { defaults.set(newValue, forKey: Key.hiDPIOnly); changed() }
    }

    /// Persist mode changes across restarts instead of only for the session.
    public var permanentChanges: Bool {
        get { defaults.bool(forKey: Key.permanentChanges) }
        set { defaults.set(newValue, forKey: Key.permanentChanges); changed() }
    }

    public var rememberPerDisplay: Bool {
        get { defaults.bool(forKey: Key.rememberPerDisplay) }
        set { defaults.set(newValue, forKey: Key.rememberPerDisplay); changed() }
    }

    public var restoreOnWake: Bool {
        get { defaults.bool(forKey: Key.restoreOnWake) }
        set { defaults.set(newValue, forKey: Key.restoreOnWake); changed() }
    }

    /// Ask for confirmation after a mode change and roll back if the user does
    /// not answer. On by default — a mode the panel cannot show leaves a black
    /// screen with no way back.
    public var confirmModeChanges: Bool {
        get { defaults.bool(forKey: Key.confirmModeChanges) }
        set { defaults.set(newValue, forKey: Key.confirmModeChanges); changed() }
    }

    /// Gates rotation and brightness, the two features that need private interfaces.
    public var enableOptionalModule: Bool {
        get { defaults.bool(forKey: Key.enableOptionalModule) }
        set { defaults.set(newValue, forKey: Key.enableOptionalModule); changed() }
    }

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Language

    public var language: AppLanguage {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let value = AppLanguage(rawValue: raw) else { return .system }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
            L10n.language = newValue
            changed()
        }
    }

    // MARK: - Hotkeys

    /// Shortcut map keyed by a stable action identifier.
    public var hotkeys: [String: HotKeySpec] {
        get { decode([String: HotKeySpec].self, key: Key.hotkeys) ?? [:] }
        set { encode(newValue, key: Key.hotkeys); changed() }
    }

    public func hotkey(for action: String) -> HotKeySpec? {
        hotkeys[action]
    }

    public func setHotkey(_ spec: HotKeySpec?, for action: String) {
        var current = hotkeys
        if let spec, spec.isValid { current[action] = spec } else { current.removeValue(forKey: action) }
        hotkeys = current
    }

    // MARK: - Remembered modes

    /// Remembered resolutions keyed by `DisplayIdentity.key`.
    public var rememberedModes: [String: RememberedMode] {
        get { decode([String: RememberedMode].self, key: Key.rememberedModes) ?? [:] }
        set { encode(newValue, key: Key.rememberedModes); changed() }
    }

    public func remember(_ mode: RememberedMode, for identityKey: String) {
        var current = rememberedModes
        current[identityKey] = mode
        rememberedModes = current
    }

    public func forgetMode(for identityKey: String) {
        var current = rememberedModes
        current.removeValue(forKey: identityKey)
        rememberedModes = current
    }

    public func forgetAllModes() {
        rememberedModes = [:]
    }

    // MARK: - Codable helpers

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Support folder

    /// `~/Library/Application Support/RDM-ARM` — where profiles live.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RDM-ARM", isDirectory: true)
    }

    @discardableResult
    public static func ensureSupportDirectory() -> URL {
        let url = supportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
