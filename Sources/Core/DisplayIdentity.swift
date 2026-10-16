import CoreGraphics
import Foundation

/// Stable identity for a physical display.
///
/// Used to remember per-display settings (preferred mode, rotation) across
/// unplug/replug cycles and reboots. Display *IDs* (`CGDirectDisplayID`) are
/// reassigned by the system on every reconnect, so they must never be persisted.
public struct DisplayIdentity: Codable, Hashable, Sendable {

    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let isBuiltin: Bool
    /// Ordinal fallback for displays that report no usable EDID identity
    /// (virtual displays, some KVMs).
    public let ordinal: Int

    public init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool, ordinal: Int) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
        self.ordinal = ordinal
    }

    /// Reads identity from a live display using public CoreGraphics accessors.
    public static func of(_ displayID: CGDirectDisplayID, ordinal: Int) -> DisplayIdentity {
        DisplayIdentity(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            ordinal: ordinal
        )
    }

    /// Persistable key. Falls back to the ordinal when the display exposes no EDID.
    public var key: String {
        if vendor == 0 && model == 0 {
            return "ordinal:\(ordinal)"
        }
        return String(format: "edid:%04X:%04X:%08X:%@",
                      vendor, model, serial, isBuiltin ? "b" : "e")
    }

    /// Short human-readable form, e.g. "09D1:8039".
    public var shortDescription: String {
        String(format: "%04X:%04X", vendor, model)
    }
}
