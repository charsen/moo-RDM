import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// A display's backing-store size in pixels.
public struct PixelSize: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var description: String { "\(width) × \(height)" }
}

/// A connected display and its current state.
///
/// Not `Sendable` because it carries a `DisplayMode`, which wraps a
/// CoreFoundation `CGDisplayMode`.
public struct DisplayInfo: Identifiable, Hashable {
    public let id: CGDirectDisplayID
    /// Position in the online-display list — this is what the CLI's `-d` selects.
    public let ordinal: Int
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    public let isActive: Bool
    public let isMirrored: Bool
    public let identity: DisplayIdentity
    public let currentMode: DisplayMode?
    public let rotation: Double
    public let bounds: CGRect
    /// The display's native panel resolution, derived from the modes macOS flags
    /// with `kDisplayModeNativeFlag`.
    public let nativePixelSize: PixelSize?

    public var menuTitle: String { name }

    /// e.g. "1920 × 1080 ⚡️ · 60 Hz"
    public var currentDescription: String {
        guard let mode = currentMode else { return "—" }
        var text = mode.menuTitle
        if mode.refreshRate > 0 { text += " · \(mode.refreshDescription)" }
        if rotation != 0 { text += String(format: " · %.0f°", rotation) }
        return text
    }

    /// Only meaningful when the display reports a native panel size.
    public var isAtNativeResolution: Bool {
        guard let mode = currentMode, let native = nativePixelSize else { return false }
        return mode.pixelWidth == native.width && mode.pixelHeight == native.height
    }
}

/// Reads the display topology through the **public** CoreGraphics API.
///
/// No private SPI is used anywhere in this type — that is the whole point of the
/// RDM-ARM rewrite. See `Sources/Optional/` for the strictly opt-in extras.
public enum DisplayManager {

    // MARK: - Enumeration

    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &ids, &actual) == .success else { return [] }
        return Array(ids.prefix(Int(actual)))
    }

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &actual) == .success else { return [] }
        return Array(ids.prefix(Int(actual)))
    }

    // MARK: - Naming

    /// Maps display IDs to the names AppKit shows in System Settings.
    /// `NSScreen` is the only public source of a human-readable display name.
    public static func screenNameMap() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            map[CGDirectDisplayID(truncating: number)] = screen.localizedName
        }
        return map
    }

    public static func name(for displayID: CGDirectDisplayID, ordinal: Int) -> String {
        if let name = screenNameMap()[displayID], !name.isEmpty { return name }
        if CGDisplayIsMain(displayID) != 0 { return L10n.t("menu.mainDisplay") }
        return L10n.t("menu.display", Int32(ordinal + 1))
    }

    // MARK: - Modes

    /// Every mode the display reports.
    ///
    /// `kCGDisplayShowDuplicateLowResolutionModes` is the switch that makes this
    /// useful. Without it macOS returns only the modes System Settings exposes —
    /// on the machine this was developed against, 120 instead of 257, with every
    /// HiDPI variant missing.
    ///
    /// - Parameter includeUnusable: keep modes where
    ///   `CGDisplayModeIsUsableForDesktopGUI` is false. macOS hides these from the
    ///   GUI, but they are often perfectly displayable — this is RDM's signature feature.
    public static func allModes(for displayID: CGDirectDisplayID,
                                includeUnusable: Bool = true) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) else { return [] }

        let count = CFArrayGetCount(raw)
        var modes: [DisplayMode] = []
        modes.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(raw, index) else { continue }
            let cgMode = Unmanaged<CGDisplayMode>.fromOpaque(pointer).takeUnretainedValue()
            let mode = DisplayMode(displayID: displayID, cgMode: cgMode)
            if !includeUnusable && !mode.isUsable { continue }
            modes.append(mode)
        }
        return modes
    }

    /// The mode the display is using right now.
    public static func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayMode(displayID: displayID, cgMode: mode)
    }

    /// The mode macOS marks as this display's default.
    public static func defaultMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        allModes(for: displayID).first { $0.flags.contains(.isDefault) }
    }

    /// Current rotation in degrees (0, 90, 180 or 270).
    public static func rotation(for displayID: CGDirectDisplayID) -> Double {
        CGDisplayRotation(displayID)
    }

    /// The display's native panel resolution.
    ///
    /// Do **not** simply take the largest pixel size in the mode list: macOS
    /// creates supersampled backing stores that exceed the panel. A 4K display
    /// reports a 3360 × 1890 @2x mode with a 6720 × 3780 backing store, which is
    /// downscaled to the panel — so "largest" would answer 6720 × 3780 for a
    /// 3840 × 2160 screen.
    ///
    /// The reliable signal is `kDisplayModeNativeFlag`, which macOS sets on the
    /// modes that map 1:1 onto the panel.
    public static func nativePixelSize(for displayID: CGDirectDisplayID) -> PixelSize? {
        let modes = allModes(for: displayID)
        let flagged = modes.filter { $0.flags.contains(.native) }
        let candidates = flagged.isEmpty ? modes : flagged
        guard let best = candidates.max(by: {
            ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight)
        }) else { return nil }
        return PixelSize(width: best.pixelWidth, height: best.pixelHeight)
    }

    // MARK: - Assembly

    public static func display(_ displayID: CGDirectDisplayID, ordinal: Int) -> DisplayInfo {
        DisplayInfo(
            id: displayID,
            ordinal: ordinal,
            name: name(for: displayID, ordinal: ordinal),
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            isMain: CGDisplayIsMain(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
            identity: DisplayIdentity.of(displayID, ordinal: ordinal),
            currentMode: currentMode(for: displayID),
            rotation: CGDisplayRotation(displayID),
            bounds: CGDisplayBounds(displayID),
            nativePixelSize: nativePixelSize(for: displayID)
        )
    }

    public static func allDisplays() -> [DisplayInfo] {
        onlineDisplayIDs().enumerated().map { display($0.element, ordinal: $0.offset) }
    }
}
