@preconcurrency import CoreGraphics
import Foundation

/// IOKit display-mode flags.
///
/// Values are taken verbatim from `IOKit/graphics/IOGraphicsTypes.h` and verified
/// against the macOS 27.0 SDK. `CGDisplayModeGetIOFlags` returns a plain `uint32_t`,
/// so we model the bits ourselves rather than depending on an SDK enum.
public struct DisplayModeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let valid                = DisplayModeFlags(rawValue: 0x0000_0001)
    public static let safe                 = DisplayModeFlags(rawValue: 0x0000_0002)
    public static let isDefault            = DisplayModeFlags(rawValue: 0x0000_0004)
    public static let alwaysShow           = DisplayModeFlags(rawValue: 0x0000_0008)
    public static let notResize            = DisplayModeFlags(rawValue: 0x0000_0010)
    public static let requiresPan          = DisplayModeFlags(rawValue: 0x0000_0020)
    public static let interlaced           = DisplayModeFlags(rawValue: 0x0000_0040)
    public static let neverShow            = DisplayModeFlags(rawValue: 0x0000_0080)
    public static let simulscan            = DisplayModeFlags(rawValue: 0x0000_0100)
    public static let notPreset            = DisplayModeFlags(rawValue: 0x0000_0200)
    public static let builtIn              = DisplayModeFlags(rawValue: 0x0000_0400)
    public static let stretched            = DisplayModeFlags(rawValue: 0x0000_0800)
    public static let notGraphicsQuality   = DisplayModeFlags(rawValue: 0x0000_1000)
    public static let validateAgainstDisplay = DisplayModeFlags(rawValue: 0x0000_2000)
    public static let television           = DisplayModeFlags(rawValue: 0x0010_0000)
    public static let validForMirroring    = DisplayModeFlags(rawValue: 0x0020_0000)
    public static let acceleratorBacked    = DisplayModeFlags(rawValue: 0x0040_0000)
    public static let validForHiRes        = DisplayModeFlags(rawValue: 0x0080_0000)
    public static let validForAirPlay      = DisplayModeFlags(rawValue: 0x0100_0000)
    public static let native               = DisplayModeFlags(rawValue: 0x0200_0000)

    /// Ordered for stable, readable diagnostics.
    static let allNamed: [(DisplayModeFlags, String)] = [
        (.valid, "valid"), (.safe, "safe"), (.isDefault, "default"),
        (.alwaysShow, "alwaysShow"), (.neverShow, "neverShow"),
        (.notResize, "notResize"), (.requiresPan, "requiresPan"),
        (.interlaced, "interlaced"), (.simulscan, "simulscan"),
        (.notPreset, "notPreset"), (.builtIn, "builtIn"), (.stretched, "stretched"),
        (.notGraphicsQuality, "notGraphicsQuality"),
        (.validateAgainstDisplay, "validateAgainstDisplay"),
        (.television, "television"), (.validForMirroring, "validForMirroring"),
        (.acceleratorBacked, "acceleratorBacked"), (.validForHiRes, "validForHiRes"),
        (.validForAirPlay, "validForAirPlay"), (.native, "native"),
    ]

    public var names: [String] {
        Self.allNamed.filter { contains($0.0) }.map(\.1)
    }
}

/// A resolution as the user thinks of it: point size plus HiDPI or not.
public struct ResolutionChoice: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let isHiDPI: Bool

    public init(width: Int, height: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }
}

/// A resolution plus a refresh rate available on every display in a set.
public struct CommonResolution: Hashable, Sendable {
    public let choice: ResolutionChoice
    public let refreshRate: Int

    public init(choice: ResolutionChoice, refreshRate: Int) {
        self.choice = choice
        self.refreshRate = refreshRate
    }
}

/// One selectable display mode on a specific display.
///
/// Wraps a `CGDisplayMode` — CoreGraphics owns the underlying ref and Swift ARC
/// manages its lifetime — together with the scalar properties we need for
/// grouping, sorting and labelling.
///
/// Everything here comes from the **public** CoreGraphics display API.
///
/// Not `Sendable`: `CGDisplayMode` is a CoreFoundation class that is not
/// concurrency-safe, and modes are only ever touched on the main thread.
public struct DisplayMode: Hashable, Identifiable {

    public let displayID: CGDirectDisplayID
    /// The underlying CoreGraphics mode, kept alive for `CGConfigureDisplayWithDisplayMode`.
    ///
    /// `nil` for modes that exist only in the private table (see `PrivateModeTable`):
    /// macOS generates them but will not vend a `CGDisplayMode`, so they are applied
    /// by ID instead.
    public let cgMode: CGDisplayMode?

    /// Logical size in points.
    public let width: Int
    public let height: Int
    /// Backing-store size in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioFlags: UInt32
    public let modeID: Int32
    /// `CGDisplayModeIsUsableForDesktopGUI` — false for modes macOS hides from System Settings.
    public let isUsable: Bool

    public init(displayID: CGDirectDisplayID, cgMode: CGDisplayMode) {
        self.displayID   = displayID
        self.cgMode      = cgMode
        // Swift maps the CGDisplayModeGet* C functions to properties; see
        // CoreGraphics.apinotes. Calling the C names is an error since Swift 3.
        self.width       = cgMode.width
        self.height      = cgMode.height
        self.pixelWidth  = cgMode.pixelWidth
        self.pixelHeight = cgMode.pixelHeight
        self.refreshRate = cgMode.refreshRate
        self.ioFlags     = cgMode.ioFlags
        self.modeID      = cgMode.ioDisplayModeID
        self.isUsable    = cgMode.isUsableForDesktopGUI()
    }

    /// Builds a mode that only the private table knows about.
    ///
    /// There is no `CGDisplayMode` to read from, so every field is supplied by the
    /// caller. The private record no longer carries a usable refresh rate, so that
    /// is passed in too.
    public init(displayID: CGDirectDisplayID,
                privateModeID modeID: Int32,
                width: Int,
                height: Int,
                scale: Double,
                refreshRate: Double,
                ioFlags: UInt32) {
        self.displayID   = displayID
        self.cgMode      = nil
        self.width       = width
        self.height      = height
        self.pixelWidth  = Int((Double(width) * scale).rounded())
        self.pixelHeight = Int((Double(height) * scale).rounded())
        self.refreshRate = refreshRate
        self.ioFlags     = ioFlags
        self.modeID      = modeID
        self.isUsable    = true
    }

    /// Builds a mode from already-known numbers, including geometries whose
    /// backing store does not follow `width * scale` (rotated displays). Used by
    /// the pure self test, which cannot obtain a `CGDisplayMode` without hardware.
    init(displayID: CGDirectDisplayID,
         modeID: Int32 = 0,
         width: Int,
         height: Int,
         pixelWidth: Int,
         pixelHeight: Int,
         refreshRate: Double = 60,
         ioFlags: UInt32 = 0,
         isUsable: Bool = true) {
        self.displayID   = displayID
        self.cgMode      = nil
        self.width       = width
        self.height      = height
        self.pixelWidth  = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioFlags     = ioFlags
        self.modeID      = modeID
        self.isUsable    = isUsable
    }

    // MARK: - Identity

    public var id: String { "\(displayID):\(modeID)" }

    public static func == (lhs: DisplayMode, rhs: DisplayMode) -> Bool {
        lhs.displayID == rhs.displayID
            && lhs.modeID == rhs.modeID
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.refreshRate == rhs.refreshRate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(displayID)
        hasher.combine(modeID)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(refreshRate)
    }

    // MARK: - Derived properties

    public var flags: DisplayModeFlags { DisplayModeFlags(rawValue: ioFlags) }

    /// Backing scale factor: 1.0 for standard, 2.0 for HiDPI/Retina.
    ///
    /// Derived from area rather than width alone. A rotated display reports its
    /// point size in the rotated orientation while the backing store keeps the
    /// panel's own orientation, so `pixelWidth / width` can come out as 1.0 and
    /// make every HiDPI row disappear under the default HiDPI-only filter.
    public var scale: Double {
        guard width > 0, height > 0 else { return 1.0 }
        let pointArea = Double(width * height)
        let pixelArea = Double(pixelWidth * pixelHeight)
        guard pointArea > 0, pixelArea > 0 else { return 1.0 }
        return (pixelArea / pointArea).squareRoot()
    }

    /// True when the backing store is larger than the logical size, i.e. a HiDPI mode.
    /// These are the modes RDM exists to unlock — macOS normally hides them.
    public var isHiDPI: Bool { pixelWidth * pixelHeight > width * height }

    /// A 1× row whose output geometry is larger than the panel's native size.
    ///
    /// macOS creates these when a `scale-resolutions` entry is read as a
    /// standard size. No panel ever declared such a timing, so selecting one is
    /// a good way to black the screen; the menu hides them while the CLI keeps
    /// reporting what the mode table really contains.
    public func isStandardOutputBeyondPanel(_ native: PixelSize?) -> Bool {
        guard let native, !isHiDPI else { return false }
        let fitsPortrait = pixelWidth <= native.width && pixelHeight <= native.height
        let fitsLandscape = pixelWidth <= native.height && pixelHeight <= native.width
        return !(fitsPortrait || fitsLandscape)
    }

    /// The 1× twin macOS creates next to a custom `scale-resolutions` entry.
    ///
    /// Adding 4608 × 2592 to create `2304 × 1296 ⚡️` also adds a 1× mode at
    /// 4608 × 2592. It is inside the panel, so the "beyond native" rule does not
    /// catch it, but no display ever declared that output timing. Selecting it is
    /// how a custom resolution blacks a screen.
    public func isCustomStandardTwin(of backing: PixelSize) -> Bool {
        !isHiDPI && pixelWidth == backing.width && pixelHeight == backing.height
    }

    /// True when the mode only exists in the private table — the public
    /// enumeration does not return it, and it has to be applied by ID.
    public var isPrivate: Bool { cgMode == nil }

    /// True when the mode is taller than it is wide (rotated display).
    public var isPortrait: Bool { pixelHeight > pixelWidth }

    public var pointDescription: String { "\(width) × \(height)" }
    public var pixelDescription: String { "\(pixelWidth) × \(pixelHeight)" }

    public var refreshDescription: String {
        refreshRate > 0 ? String(format: "%.0f Hz", refreshRate) : "—"
    }

    /// Menu label. The lightning bolt mirrors the original RDM's HiDPI marker.
    ///
    /// Omits the refresh rate: the rate lives in its own submenu here, and in
    /// the resolution list it is added by `menuTitle(withFastestRate:)`.
    public var menuTitle: String {
        isHiDPI ? "\(pointDescription) ⚡️" : pointDescription
    }

    /// `menuTitle` plus the fastest rate the group offers.
    ///
    /// The resolution list shows this rather than a bare name because the
    /// refresh-rate menu only ever describes the geometry in use: a row that
    /// cannot reach the rate the user wants has no other way to say so, and
    /// "1920 × 1080 ⚡️" and "1920 × 1080" sitting a submenu apart look like the
    /// same choice until one of them prints its ceiling.
    public func menuTitle(withFastestRate rate: Double) -> String {
        guard rate > 0 else { return menuTitle }
        return "\(menuTitle) · \(String(format: "%.0f Hz", rate))"
    }

    /// `menuTitle` plus the refresh rate, for places where the rate is not shown
    /// separately — the change-confirmation panel and alerts.
    /// Without this, changing only the refresh rate reports the same resolution
    /// back to the user and reads as if nothing happened.
    public var detailedTitle: String {
        refreshRate > 0 ? "\(menuTitle) @ \(refreshDescription)" : menuTitle
    }

    /// Modes that differ only in refresh rate collapse into one group under this key.
    public var resolutionKey: String {
        "\(width)x\(height)x\(pixelWidth)x\(pixelHeight)"
    }

    /// True when `other` is what the user would call the same setting — same
    /// geometry and effectively the same refresh rate.
    ///
    /// Used to tick the active menu entry and to skip the confirmation prompt
    /// when nothing would actually change.
    public func isSame(as other: DisplayMode?) -> Bool {
        guard let other else { return false }
        return resolutionKey == other.resolutionKey
            && abs(refreshRate - other.refreshRate) < 0.5
    }

    /// Aspect ratio as a displayable string, e.g. "16:9".
    public var aspectDescription: String {
        guard width > 0, height > 0 else { return "—" }
        let divisor = Self.greatestCommonDivisor(width, height)
        let w = width / divisor, h = height / divisor
        switch (w, h) {
        case (8, 5), (16, 10): return "16:10"
        case (64, 27), (43, 18), (21, 9): return "21:9"
        default: return "\(w):\(h)"
        }
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }

    /// Human-readable dump of the raw CoreGraphics mode flags.
    public var flagDescription: String {
        let names = flags.names
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    // MARK: - Cross-display matching

    /// Resolutions every display in the set can show, with the fastest refresh
    /// rate they all offer at that size.
    ///
    /// The caller decides which modes are eligible (public, usable, not the 1×
    /// twin of a custom entry); this function only does the intersection, so it
    /// is cheap to pin in the self test.
    public static func commonResolutions(among displays: [[DisplayMode]],
                                         hiDPIOnly: Bool) -> [CommonResolution] {
        guard displays.count >= 2 else { return [] }

        var perDisplay: [[ResolutionChoice: Set<Int>]] = []
        for modes in displays {
            var map: [ResolutionChoice: Set<Int>] = [:]
            for mode in modes where !hiDPIOnly || mode.isHiDPI {
                let choice = ResolutionChoice(width: mode.width,
                                              height: mode.height,
                                              isHiDPI: mode.isHiDPI)
                map[choice, default: []].insert(Int(mode.refreshRate.rounded()))
            }
            perDisplay.append(map)
        }

        guard let first = perDisplay.first else { return [] }
        var result: [CommonResolution] = []
        for (choice, rates) in first {
            var common = rates
            for map in perDisplay.dropFirst() {
                guard let other = map[choice] else { common = []; break }
                common.formIntersection(other)
            }
            if let best = common.max() {
                result.append(CommonResolution(choice: choice, refreshRate: best))
            }
        }

        return result.sorted { a, b in
            if a.choice.width != b.choice.width { return a.choice.width > b.choice.width }
            if a.choice.isHiDPI != b.choice.isHiDPI { return a.choice.isHiDPI }
            if a.choice.height != b.choice.height { return a.choice.height > b.choice.height }
            return a.refreshRate > b.refreshRate
        }
    }
}

// MARK: - Collection helpers

// `Collection` rather than `Sequence`: on `Sequence`, the bare name `count`
// resolves to Swift 6's `count(where:)` method instead of the property.
public extension Collection where Element == DisplayMode {

    /// Menu ordering: widest first, HiDPI before standard, taller before shorter,
    /// and within identical geometry, highest refresh rate first.
    ///
    /// Mirrors the original RDM's `compareResMenuItem:` ordering so the menu reads
    /// the same way long-time users expect.
    func sortedForMenu() -> [DisplayMode] {
        sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.height != b.height { return a.height > b.height }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.modeID < b.modeID
        }
    }

    /// Key identifying a menu entry: same geometry *and* same refresh rate.
    /// macOS returns several distinct mode IDs for what the user sees as one entry
    /// (different pixel encodings, colour depths and scan variants), and listing
    /// them all produces a menu with the same "60 Hz" repeated four times.
    ///
    /// The backing-store size deliberately stays out of the key: two encodings
    /// that render the same point size at the same rate are one menu row. The
    /// 1× / HiDPI split stays in, because those are genuinely different choices.
    func entryKey(_ mode: DisplayMode) -> String {
        "\(mode.width)x\(mode.height)@\(Int(mode.refreshRate.rounded())):\(mode.isHiDPI ? 2 : 1)"
    }

    /// Collapses visually identical modes into one entry per geometry + refresh rate.
    ///
    /// When several modes share a key we keep the most useful one, in order of
    /// preference: the mode that is currently active (so the tick lands on a real
    /// entry), then a mode the system marks as a default, then the lowest mode ID
    /// for stability across launches.
    func deduplicated(preferring current: DisplayMode? = nil) -> [DisplayMode] {
        var best: [String: DisplayMode] = [:]
        var order: [String] = []

        for mode in self {
            let key = entryKey(mode)
            guard let incumbent = best[key] else {
                best[key] = mode
                order.append(key)
                continue
            }
            if isBetter(mode, than: incumbent, current: current) {
                best[key] = mode
            }
        }

        return order.compactMap { best[$0] }
    }

    /// Ranking used by `deduplicated(preferring:)` to choose between equal modes.
    private func isBetter(_ candidate: DisplayMode,
                          than incumbent: DisplayMode,
                          current: DisplayMode?) -> Bool {
        func rank(_ mode: DisplayMode) -> Int {
            var score = 0
            if let current, mode.modeID == current.modeID { score += 100 }
            if mode.flags.contains(.isDefault) { score += 10 }
            if mode.flags.contains(.safe) { score += 1 }
            return score
        }
        let a = rank(candidate), b = rank(incumbent)
        if a != b { return a > b }
        return candidate.modeID < incumbent.modeID
    }

    /// Collapses a mode list into resolution groups, each holding its refresh rates.
    func groupedByResolution() -> [(mode: DisplayMode, refreshRates: [DisplayMode])] {
        var order: [String] = []
        var buckets: [String: [DisplayMode]] = [:]
        for mode in self {
            let key = mode.resolutionKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(mode)
        }
        return order.compactMap { key in
            guard let group = buckets[key], let first = group.first else { return nil }
            let rates = group.sorted { $0.refreshRate > $1.refreshRate }
            return (mode: first, refreshRates: rates)
        }
    }
}
