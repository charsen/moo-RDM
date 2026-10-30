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

    // MARK: - Hashable
    //
    // Written out by hand rather than synthesised. `CGRect` only gained a
    // `Hashable` conformance in recent SDKs, so a synthesised conformance makes
    // this type fail to compile on Xcode 15 / Swift 5.10 — which is still a very
    // common toolchain. Decomposing the rect into its four `Double`s keeps the
    // type portable without changing its public API.

    public static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.ordinal == rhs.ordinal
            && lhs.name == rhs.name
            && lhs.isBuiltin == rhs.isBuiltin
            && lhs.isMain == rhs.isMain
            && lhs.isActive == rhs.isActive
            && lhs.isMirrored == rhs.isMirrored
            && lhs.identity == rhs.identity
            && lhs.currentMode == rhs.currentMode
            && lhs.rotation == rhs.rotation
            && lhs.bounds == rhs.bounds
            && lhs.nativePixelSize == rhs.nativePixelSize
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ordinal)
        hasher.combine(name)
        hasher.combine(isBuiltin)
        hasher.combine(isMain)
        hasher.combine(isActive)
        hasher.combine(isMirrored)
        hasher.combine(identity)
        hasher.combine(currentMode)
        hasher.combine(rotation)
        hasher.combine(bounds.origin.x)
        hasher.combine(bounds.origin.y)
        hasher.combine(bounds.size.width)
        hasher.combine(bounds.size.height)
        hasher.combine(nativePixelSize)
    }
}

/// One display plus the mode table read for it.
///
/// The menu needs the mode list, the native size and the current mode in the
/// same breath. Computing them separately used to enumerate the display three
/// times per open; a snapshot reads the table once and derives the rest.
public struct DisplaySnapshot {
    public let display: DisplayInfo
    /// Modes that should be listed: the full table when macOS-hidden modes are
    /// on, otherwise the usable public rows.
    public let modes: [DisplayMode]
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
    /// - Parameter includePrivate: append rows only the private window-server table
    ///   knows. Callers that do not need them (the menu with hidden modes off, native
    ///   size detection) skip a per-row private call.
    public static func allModes(for displayID: CGDirectDisplayID,
                                includeUnusable: Bool = true,
                                includePrivate: Bool = true) -> [DisplayMode] {
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
        // The private table is fiction unless asked for. It is not filtered by
        // `isUsableForDesktopGUI` — those records never went through CoreGraphics,
        // so they carry no usability verdict at all, and the ones it lists are
        // exactly the "hidden" modes the preference is named after. Appending
        // them unconditionally put rows in the menu that could not be applied
        // (CoreGraphics error 1001, e.g. a 60 Hz HiDPI size the link only
        // carries at 30); whoever wants those turns the switch on and accepts
        // the risk that comes with them.
        if includeUnusable && includePrivate {
            modes.append(contentsOf: hiddenModes(for: displayID, known: modes))
        }
        return modes
    }

    /// HiDPI modes the window server holds but never returns publicly.
    ///
    /// These are the supersampled "more space" modes: a 1920 × 1200 mode on a
    /// 2560 × 1600 panel, rendered at 3840 × 2400 and scaled down. Only the
    /// private table exposes them, and they can only be applied by ID — see
    /// `PrivateModeTable`. Empty when the optional module is off.
    private static func hiddenModes(for displayID: CGDirectDisplayID,
                                    known publicModes: [DisplayMode]) -> [DisplayMode] {
        let knownIDs = Set(publicModes.map(\.modeID))
        let fallbackRefresh = currentMode(for: displayID)?.refreshRate ?? 0

        return PrivateModeTable.modes(for: displayID)
            .filter { $0.scale >= 1.5 && !knownIDs.contains($0.modeID) }
            .map { entry in
                // The private record's refresh-rate field is stale, so borrow the
                // rate from the public mode with the same point size when there is
                // one — a 1920 × 1200 HiDPI mode runs at whatever 1920 × 1200 runs at.
                let refresh = publicModes.first {
                    $0.width == entry.width && $0.height == entry.height && $0.refreshRate > 0
                }?.refreshRate ?? fallbackRefresh
                return DisplayMode(displayID: displayID,
                                   privateModeID: entry.modeID,
                                   width: entry.width,
                                   height: entry.height,
                                   scale: entry.scale,
                                   refreshRate: refresh,
                                   ioFlags: entry.ioFlags)
            }
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
    public static func nativePixelSize(in modes: [DisplayMode]) -> PixelSize? {
        // Private modes are excluded on purpose: their backing stores are larger
        // than the panel, so the "largest pixel size" fallback would report a
        // supersampled size as native.
        let publicModes = modes.filter { !$0.isPrivate }
        let flagged = publicModes.filter { $0.flags.contains(.native) }
        let candidates = flagged.isEmpty ? publicModes : flagged
        guard let best = candidates.max(by: {
            ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight)
        }) else { return nil }
        return PixelSize(width: best.pixelWidth, height: best.pixelHeight)
    }

    public static func nativePixelSize(for displayID: CGDirectDisplayID) -> PixelSize? {
        nativePixelSize(in: allModes(for: displayID))
    }

    // MARK: - Snapshots

    public static func snapshot(_ displayID: CGDirectDisplayID,
                                ordinal: Int,
                                includeUnusable: Bool = true) -> DisplaySnapshot {
        // Public rows are needed either way; the private table is only consulted
        // when the caller wants hidden modes. With the menu's default (hidden
        // modes off) this removes a per-row private call from every menu open.
        let publicModes = allModes(for: displayID, includeUnusable: true, includePrivate: false)
        let native = nativePixelSize(in: publicModes)
        let visible: [DisplayMode]
        if includeUnusable {
            visible = publicModes + hiddenModes(for: displayID, known: publicModes)
        } else {
            visible = publicModes.filter(\.isUsable)
        }

        let info = DisplayInfo(
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
            nativePixelSize: native
        )
        return DisplaySnapshot(display: info, modes: visible)
    }

    public static func snapshots(includeUnusable: Bool = true) -> [DisplaySnapshot] {
        onlineDisplayIDs().enumerated().map {
            snapshot($0.element, ordinal: $0.offset, includeUnusable: includeUnusable)
        }
    }

    // MARK: - Lightweight info

    /// Display identity and current state without enumerating the mode table.
    ///
    /// Menu actions, mode memory and preset capture only need the current mode,
    /// rotation, mirror state and identity. A full `snapshot` would enumerate
    /// every mode (and the private table) just to answer that.
    public static func info(_ displayID: CGDirectDisplayID, ordinal: Int) -> DisplayInfo {
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
            nativePixelSize: nil
        )
    }

    public static func allInfos() -> [DisplayInfo] {
        onlineDisplayIDs().enumerated().map { info($0.element, ordinal: $0.offset) }
    }

    // MARK: - Assembly

    public static func display(_ displayID: CGDirectDisplayID, ordinal: Int) -> DisplayInfo {
        snapshot(displayID, ordinal: ordinal).display
    }

    public static func allDisplays() -> [DisplayInfo] {
        snapshots().map(\.display)
    }
}
