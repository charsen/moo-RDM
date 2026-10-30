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
        static let enableOptionalModule = "enableOptionalModule"
        static let language            = "language"
        static let rememberedModes     = "rememberedModes"
        static let displayPresets      = "displayPresets"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showUnusableModes: false,
            Key.hiDPIOnly: true,
            Key.permanentChanges: false,
            Key.rememberPerDisplay: true,
            Key.restoreOnWake: true,
            Key.enableOptionalModule: true,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
    }

    // MARK: - Toggles

    /// List modes macOS hides from System Settings — the ones it marks as unfit
    /// for the desktop GUI.
    ///
    /// Off by default: the menu opens clean, with only the modes that are safe to
    /// pick. Turning it on adds the rest, which is RDM's signature feature but is
    /// also the thing that can leave a screen black.
    public var showUnusableModes: Bool {
        get { defaults.bool(forKey: Key.showUnusableModes) }
        set { defaults.set(newValue, forKey: Key.showUnusableModes); changed() }
    }

    /// Hide every standard-resolution entry, leaving only HiDPI ones.
    ///
    /// On by default: the HiDPI modes are the reason to run this app at all, and
    /// mixing them in with a hundred standard entries buries them. The toggle in
    /// the menu and in Preferences brings the rest back.
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

    /// Drops the remembered mode for one identity key.
    public func forgetRememberedMode(for identityKey: String) {
        var current = rememberedModes
        current.removeValue(forKey: identityKey)
        rememberedModes = current
    }

    public func forgetAllRememberedModes() {
        rememberedModes = [:]
    }

    // MARK: - Presets

    public var displayPresets: [DisplayPreset] {
        get { decode([DisplayPreset].self, key: Key.displayPresets) ?? [] }
        set { encode(newValue, key: Key.displayPresets); changed() }
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
}
