import Darwin
import Foundation

/// Loads symbols from private system frameworks on demand.
///
/// Every lookup here is **optional**. When a symbol is missing — or the user turns
/// the optional module off — the corresponding feature reports itself unavailable
/// and the app carries on. Nothing in this file is needed by the display-mode
/// engine, which uses only public CoreGraphics API.
///
/// Keeping every private lookup in this one type means the private surface of the
/// whole project is auditable at a glance.
final class PrivateSymbolLoader {

    static let shared = PrivateSymbolLoader()

    private typealias Handle = UnsafeMutableRawPointer

    private var handles: [String: Handle] = [:]
    private var cache: [String: UnsafeMutableRawPointer] = [:]
    private let lock = NSLock()

    /// Frameworks searched, in order.
    private static let searchPaths = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ]

    private init() {}

    /// Resolves `name` and reinterprets it as `type`, typically a `@convention(c)`
    /// function type. Returns `nil` when the symbol does not exist on this system.
    func load<T>(_ name: String, as type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[name] {
            return unsafeBitCast(cached, to: T.self)
        }

        for path in Self.searchPaths {
            guard let handle = handle(for: path) else { continue }
            if let pointer = dlsym(handle, name) {
                cache[name] = pointer
                return unsafeBitCast(pointer, to: T.self)
            }
        }

        // Some frameworks register their symbols globally once loaded.
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
            cache[name] = pointer
            return unsafeBitCast(pointer, to: T.self)
        }

        return nil
    }

    /// Whether a symbol exists, without needing to know its type.
    func exists(_ name: String) -> Bool {
        load(name, as: UnsafeRawPointer?.self) != nil
    }

    private func handle(for path: String) -> Handle? {
        if let existing = handles[path] { return existing }
        guard let opened = dlopen(path, RTLD_LAZY) else { return nil }
        handles[path] = opened
        return opened
    }
}
