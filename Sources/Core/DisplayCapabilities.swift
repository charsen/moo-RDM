import CoreGraphics
import Foundation

/// What a display can do, as opposed to what macOS is willing to offer.
///
/// Three numbers decide whether a refresh rate beyond the listed ones is even
/// physically possible: the panel's declared timings, the link's pixel-rate
/// budget and the vendor's reference refresh range. CoreGraphics exposes none of
/// them, so they are assembled here from the EDID blob plus — when the optional
/// module is on — the undocumented DCP port attributes.
public enum DisplayCapabilities {

    public struct Report {
        public let displayID: CGDirectDisplayID
        public let edid: EDID?
        /// What the panel uses to bring itself up; the only timing we know it
        /// locks onto, and therefore the safest basis for re-clocking.
        public let nativeTiming: DetailedTiming?
        /// Rates the panel declares that macOS does not list at that geometry.
        public let hiddenRates: [EDID.DeclaredRate]
        /// `DisplayHints.MaxTotalPixelRate`. `nil` when the optional module is off
        /// or the figure is not published on this machine.
        public let linkMaxPixelRate: Int?
        public let maxRefreshRate: Double?
        public let minRefreshRate: Double?
        public let nativeFormat: PixelSize?

        /// Highest refresh rate the hardware could plausibly take at a geometry.
        ///
        /// Derived by scaling the native timing's blanking ratios to the target
        /// geometry and dividing the pixel-rate budget by the resulting total.
        /// This is an estimate, not a promise: it says what the link and the
        /// panel's reference range allow, not what the scaler will accept.
        public func estimatedMaximumRefresh(width: Int, height: Int) -> Double? {
            guard let base = nativeTiming, base.hActive > 0, base.vActive > 0,
                  width > 0, height > 0 else { return maxRefreshRate }

            let hTotal = Int((Double(width) * Double(base.hTotal) / Double(base.hActive)).rounded())
            let vTotal = Int((Double(height) * Double(base.vTotal) / Double(base.vActive)).rounded())
            guard hTotal > 0, vTotal > 0 else { return maxRefreshRate }

            var cap: Double?
            if let budget = linkMaxPixelRate {
                cap = Double(budget) / Double(hTotal * vTotal)
            }
            if let vendor = maxRefreshRate {
                cap = min(cap ?? vendor, vendor)
            }
            guard let result = cap else { return nil }
            if let floor = minRefreshRate, result < floor { return floor }
            return result
        }

        /// One-line explanation for diagnostics, e.g.
        /// "link 594 MHz · vendor range 50–76 Hz · 3840 × 2160 tops out near 67 Hz".
        public func budgetDescription(width: Int? = nil, height: Int? = nil) -> String {
            var parts: [String] = []
            if let rate = linkMaxPixelRate {
                parts.append(L10n.t("capabilities.link", Int32((Double(rate) / 1_000_000).rounded())))
            }
            if let low = minRefreshRate, let high = maxRefreshRate {
                parts.append(L10n.t("capabilities.range",
                                    String(format: "%.0f–%.0f", low, high)))
            } else if let high = maxRefreshRate {
                parts.append(L10n.t("capabilities.max", Int32(high.rounded())))
            }
            if let width, let height, let cap = estimatedMaximumRefresh(width: width, height: height) {
                parts.append(L10n.t("capabilities.cap", width, height, Int32(cap.rounded())))
            }
            return parts.isEmpty
                ? L10n.t("capabilities.unknown")
                : parts.joined(separator: " · ")
        }
    }

    // MARK: - Assembly

    public static func report(for displayID: CGDirectDisplayID,
                              offeredModes: [DisplayMode]? = nil) -> Report {
        let edid = DisplayEDIDReader.read(for: displayID)
        let modes = offeredModes ?? DisplayManager.allModes(for: displayID)

        var attributes: [String: Any]?
        if let edid {
            attributes = DisplayLinkInfo.attributes(vendor: edid.vendor,
                                                    product: edid.product,
                                                    serial: edid.serial)
        }

        return Report(
            displayID: displayID,
            edid: edid,
            nativeTiming: edid?.preferredTiming,
            hiddenRates: edid.map { hiddenRates(in: $0, offered: modes) } ?? [],
            linkMaxPixelRate: DisplayLinkInfo.maxPixelRate(productName: edid?.productName),
            maxRefreshRate: (attributes?["MaximumRefreshRate"] as? NSNumber)?.doubleValue,
            minRefreshRate: (attributes?["MinimumRefreshRate"] as? NSNumber)?.doubleValue,
            nativeFormat: {
                guard let width = (attributes?["NativeFormatHorizontalPixels"] as? NSNumber)?.intValue,
                      let height = (attributes?["NativeFormatVerticalPixels"] as? NSNumber)?.intValue,
                      width > 0, height > 0 else { return nil }
                return PixelSize(width: width, height: height)
            }()
        )
    }

    /// Declared rates with no corresponding mode in the CoreGraphics list.
    ///
    /// The comparison is deliberately loose (0.5 Hz). CoreGraphics reports
    /// nominal rates, so a panel's 59.94 Hz descriptor is presented by macOS as
    /// "60.000". Calling that a missing mode would be technically tidy and
    /// practically wrong — the mode is there, the label is rounded.
    static func hiddenRates(in edid: EDID, offered: [DisplayMode],
                            tolerance: Double = 0.5) -> [EDID.DeclaredRate] {
        var seen: Set<String> = []
        var result: [EDID.DeclaredRate] = []

        for declared in edid.declaredRates {
            // Compare against *both* geometries. A 4K panel's 3840 × 2160 @ 50 Hz
            // short format can be offered as a 1920 × 1080 point mode with a
            // 3840 × 2160 backing store, so matching on point size alone would
            // report every 4K rate as missing.
            let sameGeometry = offered.filter {
                ($0.width == declared.width && $0.height == declared.height)
                    || ($0.pixelWidth == declared.width && $0.pixelHeight == declared.height)
            }
            guard !sameGeometry.isEmpty else { continue }
            guard !sameGeometry.contains(where: { abs($0.refreshRate - declared.refreshRate) <= tolerance })
            else { continue }

            let key = "\(declared.width)x\(declared.height)@\(Int(declared.refreshRate.rounded()))"
            guard seen.insert(key).inserted else { continue }
            result.append(declared)
        }
        return result.sorted { $0.refreshRate > $1.refreshRate }
    }

    // MARK: - Thresholds

    /// How far a proposed refresh rate may sit above the offered one before the
    /// app asks the user to confirm. Above this the panel is being overclocked,
    /// which is a different kind of action from picking an existing mode.
    public static let confirmationThreshold: Double = 0.6
}
