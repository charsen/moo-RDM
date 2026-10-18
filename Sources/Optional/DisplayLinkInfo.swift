import CoreGraphics
import Foundation
import IOKit

/// Reads the bandwidth and refresh-range figures the display pipeline publishes.
///
/// Both live on undocumented Apple DCP classes rather than on the standard
/// display transport:
///   * `DisplayHints` (with `MaxTotalPixelRate`) is attached to
///     `AppleATCDPAltModePort`, `AppleATCDPINAdapterPort`, `AppleDCPDPTXRemotePortUFP`
///     and `AppleT8122DPTXPort`;
///   * `DisplayAttributes` (with `MaximumRefreshRate`, `MinimumRefreshRate`,
///     `NativeFormat*`) is attached to `IOMobileFramebufferShim`.
///
/// Class names and property names are Apple's internals, so this is kept in the
/// optional module and gated by `Preferences.enableOptionalModule` — the same
/// rule the rotation and brightness features follow. When the module is off, the
/// app reports a timing's link cost but does not claim to know the ceiling.
///
/// Only published properties are read; nothing is written, and no private
/// function is called.
enum DisplayLinkInfo {

    /// Highest pixel rate the link and panel are documented to carry.
    static func maxPixelRate(productName: String?) -> Int? {
        guard Preferences.shared.enableOptionalModule else { return nil }
        for className in hintClassNames {
            for service in DisplayEDIDReader.services(named: className) {
                defer { IOObjectRelease(service) }
                guard let hints = DisplayEDIDReader.dictionary(of: service, key: "DisplayHints")
                else { continue }
                guard productName == nil
                        || (hints["ProductName"] as? String) == productName
                else { continue }
                if let rate = (hints["MaxTotalPixelRate"] as? NSNumber)?.intValue, rate > 0 {
                    return rate
                }
            }
        }
        return nil
    }

    /// The panel's reference refresh range and native format.
    static func attributes(vendor: UInt32, product: UInt32, serial: UInt32) -> [String: Any]? {
        guard Preferences.shared.enableOptionalModule else { return nil }
        for service in DisplayEDIDReader.services(named: "IOMobileFramebufferShim") {
            defer { IOObjectRelease(service) }
            guard let attributes = DisplayEDIDReader.dictionary(of: service, key: "DisplayAttributes"),
                  let productAttributes = attributes["ProductAttributes"] as? [String: Any]
            else { continue }
            let vendorID = (productAttributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value
            let productID = (productAttributes["ProductID"] as? NSNumber)?.uint32Value
            let serialNumber = (productAttributes["SerialNumber"] as? NSNumber)?.uint32Value

            guard vendorID == vendor, productID == product else { continue }
            if let serialNumber, serial != 0, serialNumber != serial { continue }
            return attributes
        }
        return nil
    }

    /// Whether the figures are readable at all on this machine.
    static var isAvailable: Bool {
        guard Preferences.shared.enableOptionalModule else { return false }
        for className in hintClassNames {
            let services = DisplayEDIDReader.services(named: className)
            let found = !services.isEmpty
            services.forEach { IOObjectRelease($0) }
            if found { return true }
        }
        return false
    }

    private static let hintClassNames = [
        "AppleATCDPAltModePort",
        "AppleATCDPINAdapterPort",
        "AppleDCPDPTXRemotePortUFP",
        "AppleT8122DPTXPort",
    ]
}
