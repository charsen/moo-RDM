import CoreGraphics
import Darwin
import Foundation

/// The private per-display mode table that the original RDM read.
///
/// macOS generates more display modes than `CGDisplayCopyAllDisplayModes` will
/// hand back. The ones it withholds are HiDPI "more space" modes that are
/// supersampled — a 1920 × 1200 mode on a 2560 × 1600 panel is rendered at
/// 3840 × 2400 and scaled down to the panel. System Settings does not offer them
/// and neither does the public API, but the window server keeps them in this
/// table. It is the same table the original RDM listed, and the reason RDM could
/// offer HiDPI resolutions this app could not.
///
/// Everything here is opt-in through `Preferences.enableOptionalModule` and
/// degrades to "no extra modes" when the symbols are absent or the record no
/// longer decodes. The table is validated before it is trusted, because Apple has
/// silently changed this layout before — on macOS 27 `depth` and `refreshRate`
/// already read garbage (see the offsets below).
enum PrivateModeTable {

    /// One row of the private table. Only the fields that still decode correctly
    /// are kept; there is deliberately no refresh rate, because that field is no
    /// longer valid.
    struct Entry {
        let modeID: Int32
        let width: Int
        let height: Int
        let scale: Double
        let ioFlags: UInt32
    }

    private typealias GetCountFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    private typealias GetDescriptionFunction = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    private typealias ConfigureFunction = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    private static let getCount = PrivateSymbolLoader.shared.load("CGSGetNumberOfDisplayModes",
                                                                 as: GetCountFunction.self)
    private static let getDescription = PrivateSymbolLoader.shared.load("CGSGetDisplayModeDescriptionOfLength",
                                                                       as: GetDescriptionFunction.self)
    private static let configure = PrivateSymbolLoader.shared.load("CGSConfigureDisplayMode",
                                                                  as: ConfigureFunction.self)

    // The record is a fixed-layout struct Apple never declared publicly. The
    // offsets below were verified against `CGDisplayCopyAllDisplayModes` on
    // macOS 27 / arm64: across 303 modes on two displays, width and height
    // matched the public API on every shared row, and `scale` read exactly 1.00
    // or 2.00. `depth` @0x10 and `refreshRate` @0xBC are known to be stale and
    // are deliberately not read.
    private static let recordSize = 0xDC
    private static let descriptionLength: Int32 = 0xD4
    private static let offsetModeID = 0x00
    private static let offsetFlags  = 0x04
    private static let offsetWidth  = 0x08
    private static let offsetHeight = 0x0C
    private static let offsetScale  = 0xD0

    /// Whether the private symbols exist, regardless of the preference toggle.
    static var isSymbolPresent: Bool { getCount != nil && getDescription != nil }

    /// Whether the table can be read *and* applied to right now.
    static var isEnabled: Bool {
        Preferences.shared.enableOptionalModule && isSymbolPresent && configure != nil
    }

    /// Every row the private table reports for a display.
    ///
    /// - Returns: the rows, or `[]` when the feature is off, the symbols are
    ///   gone, or enough rows fail to decode that the layout must have changed.
    static func modes(for displayID: CGDirectDisplayID) -> [Entry] {
        guard isEnabled, let getCount, let getDescription else { return [] }

        var count: Int32 = 0
        getCount(displayID, &count)
        guard count > 0, count < 4096 else { return [] }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: recordSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [Entry] = []
        var malformed = 0
        for index in 0..<Int(count) {
            _ = memset(buffer, 0, recordSize)
            getDescription(displayID, Int32(index), buffer, descriptionLength)

            let entry = Entry(
                modeID: Int32(bitPattern: buffer.load(fromByteOffset: offsetModeID, as: UInt32.self)),
                width: Int(buffer.load(fromByteOffset: offsetWidth, as: UInt32.self)),
                height: Int(buffer.load(fromByteOffset: offsetHeight, as: UInt32.self)),
                scale: Double(buffer.load(fromByteOffset: offsetScale, as: Float.self)),
                ioFlags: buffer.load(fromByteOffset: offsetFlags, as: UInt32.self)
            )
            guard entry.width > 0, entry.width <= 16_384,
                  entry.height > 0, entry.height <= 16_384,
                  abs(entry.scale - 1) < 0.01 || abs(entry.scale - 2) < 0.01 else {
                malformed += 1
                continue
            }
            entries.append(entry)
        }

        // If a noticeable share of the table no longer decodes, Apple has moved
        // the layout again. Report nothing rather than offer nonsense modes.
        guard malformed <= max(2, entries.count / 10) else { return [] }
        return entries
    }

    /// Applies a table row by its mode ID.
    ///
    /// These rows have no `CGDisplayMode`, so `CGConfigureDisplayWithDisplayMode`
    /// cannot reach them; this is the call the original RDM made instead.
    static func apply(modeID: Int32, on displayID: CGDirectDisplayID, permanently: Bool) -> CGError {
        guard isEnabled, let configure else { return .failure }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }

        let configureResult = configure(config, displayID, modeID)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(config)
            return configureResult
        }
        return CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession)
    }
}
