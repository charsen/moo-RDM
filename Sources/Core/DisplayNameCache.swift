import Foundation

/// Remembers the last human-readable name for a physical display.
///
/// `NSScreen.screens` omits displays that are mirror slaves, which is exactly
/// when the menu still needs a name. Cache the name while the display is visible
/// and fall back to it when the OS stops reporting one. Persisted so a launch
/// that starts in mirror mode still has a usable name.
///
/// This is a cache, not a preference: losing it only brings back the
/// "Display N" fallback, so it is deliberately kept outside `Preferences` and
/// does not post preference-change notifications.
enum DisplayNameCache {

    private static let key = "displayNameCache"
    private static let lock = NSLock()

    private static var names: [String: String] = {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }()

    static func name(for identityKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[identityKey]
    }

    static func store(_ name: String, for identityKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard names[identityKey] != name else { return }
        names[identityKey] = name
        UserDefaults.standard.set(names, forKey: key)
    }
}
