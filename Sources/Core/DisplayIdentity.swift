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
    /// `CGDisplayUnitNumber` — the only per-instance discriminator.
    ///
    /// Two panels of the same model can report serial 0, which used to collapse
    /// them into one key: remembering a mode on one silently overwrote the
    /// other. The unit number differs between physically distinct units, while
    /// tiles of one panel share a display ID (and therefore a unit).
    public let unit: UInt32
    public let isBuiltin: Bool
    /// Ordinal fallback for displays that report no usable EDID identity
    /// (virtual displays, some KVMs).
    public let ordinal: Int

    public init(vendor: UInt32, model: UInt32, serial: UInt32,
                unit: UInt32 = 0, isBuiltin: Bool, ordinal: Int) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.unit = unit
        self.isBuiltin = isBuiltin
        self.ordinal = ordinal
    }

    /// Reads identity from a live display using public CoreGraphics accessors.
    public static func of(_ displayID: CGDirectDisplayID, ordinal: Int) -> DisplayIdentity {
        DisplayIdentity(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            unit: CGDisplayUnitNumber(displayID),
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            ordinal: ordinal
        )
    }

    /// Persistable key. Falls back to the ordinal when the display exposes no EDID.
    ///
    /// A real serial number is already unique, so those panels keep the old key
    /// format — adding the unit there would churn every existing memory for no
    /// benefit, and a unit number is not guaranteed to survive every reconnect.
    /// Only panels that report serial 0 (cheap adapters, some KVMs, and the exact
    /// case where two identical monitors collided) get the unit-qualified form.
    public var key: String {
        if vendor == 0 && model == 0 {
            return "ordinal:\(ordinal)"
        }
        if serial == 0 {
            return String(format: "edid:%04X:%04X:%08X:%u:%@",
                          vendor, model, serial, unit, isBuiltin ? "b" : "e")
        }
        return legacyKey
    }

    /// Key written by earlier versions, before the unit number was part of it.
    /// Used once on lookup so an upgrade does not discard remembered modes.
    public var legacyKey: String {
        guard vendor != 0 || model != 0 else { return key }
        return String(format: "edid:%04X:%04X:%08X:%@",
                      vendor, model, serial, isBuiltin ? "b" : "e")
    }

    /// Short human-readable form, e.g. "09D1:8039".
    public var shortDescription: String {
        String(format: "%04X:%04X", vendor, model)
    }
}
