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
        /// Every mode CoreGraphics currently vends for this display, including
        /// the private-table ones when that module is enabled. Kept because the
        /// audit has to compare three layers against each other and the mode
        /// list is the middle one.
        public let offeredModes: [DisplayMode]

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
            // A ceiling below the vendor's own minimum means the geometry cannot
            // run in the panel's supported range at all. Clamping it up to that
            // minimum would turn "the link cannot carry this" into an answer that
            // says it can — and `--custom-timing` would then try to encode it.
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

        // MARK: - Refresh audit

        /// Answers "can this display do *n* Hz, and at which geometry" by
        /// cross-referencing the three layers that actually decide it: what the
        /// panel declares in its EDID, what macOS is currently willing to list,
        /// and what the link's pixel-rate budget would carry.
        ///
        /// The runtime is the one that matters. A rate can be missing for three
        /// very different reasons, and only one of them is fixable from software:
        /// macOS hides a mode the panel declared, the panel never declared it but
        /// the link has room, or the link simply cannot carry it.
        ///
        /// - Parameter target: Rate to audit. Defaults to the highest rate the
        ///   panel declares, which is both the question people actually ask and a
        ///   stable one — it does not drift with whatever mode is current.
        public func audit(target: Double? = nil) -> RefreshAudit {
            let declared = edid?.declaredRates ?? []
            let resolvedTarget = target
                ?? declared.map(\.refreshRate).max()
                ?? maxRefreshRate
                ?? 60

            var sizes: [String: (width: Int, height: Int)] = [:]
            var points: [String: Set<RefreshAudit.PointSize>] = [:]
            var offered: [String: Set<Double>] = [:]
            var declaredRates: [String: Set<Double>] = [:]
            var order: [String] = []

            /// The geometry the panel is actually driven at, which is what the
            /// link budget applies to. Falls back to the EDID's preferred timing
            /// when the private module did not publish the native format.
            let nativeGeometry: (width: Int, height: Int)? = nativeFormat.map {
                (width: $0.width, height: $0.height)
            } ?? nativeTiming.map { (width: $0.width, height: $0.height) }

            func register(_ width: Int, _ height: Int) -> String {
                let key = "\(width)x\(height)"
                if sizes[key] == nil {
                    sizes[key] = (width, height)
                    order.append(key)
                }
                return key
            }

            for mode in offeredModes where mode.refreshRate > 0 {
                // `pixelWidth` is a backing store, and it equals the output timing
                // only while the panel can actually carry it. Anything larger
                // (4608 × 2592 on a 4K panel) is downscaled to the native timing,
                // so treating the backing store as the link geometry would invent
                // 8K timings and contradict the rate being offered.
                let output: (width: Int, height: Int)
                if let nativeGeometry,
                   mode.pixelWidth > nativeGeometry.width || mode.pixelHeight > nativeGeometry.height {
                    output = nativeGeometry
                } else {
                    output = (mode.pixelWidth, mode.pixelHeight)
                }
                let key = register(output.width, output.height)
                points[key, default: []].insert(
                    RefreshAudit.PointSize(width: mode.width, height: mode.height, scale: mode.scale))
                // Two decimals: CoreGraphics reports 59.999999 for a 60 Hz mode
                // and listing that noise would defeat the whole report.
                offered[key, default: []].insert((mode.refreshRate * 100).rounded() / 100)
            }
            for rate in declared {
                let key = register(rate.width, rate.height)
                declaredRates[key, default: []].insert((rate.refreshRate * 100).rounded() / 100)
            }

            // 59.94 and 60 are one choice on a 60 Hz panel, and so are the
            // 1000/1001 variants of every other rate. Collapsing them keeps the
            // row readable without hiding anything a user could select.
            func collapse(_ rates: Set<Double>) -> [Double] {
                var kept: [Double] = []
                for rate in rates.sorted(by: >)
                where !kept.contains(where: { abs($0 - rate) < 0.3 }) {
                    kept.append(rate)
                }
                return kept
            }

            let geometries: [RefreshAudit.Geometry] = order
                .compactMap { key -> RefreshAudit.Geometry? in
                    guard let size = sizes[key] else { return nil }
                    let pointSizes = (points[key] ?? []).sorted { a, b in
                        if a.width != b.width { return a.width > b.width }
                        return a.scale > b.scale
                    }
                    return RefreshAudit.Geometry(
                        width: size.width,
                        height: size.height,
                        pointSizes: pointSizes,
                        offeredRates: collapse(offered[key] ?? []),
                        declaredRates: collapse(declaredRates[key] ?? []),
                        ceiling: estimatedMaximumRefresh(width: size.width, height: size.height))
                }
                .sorted { a, b in
                    // Native first, then geometries the panel actually declares,
                    // then by area.
                    //
                    // Sorting by area alone was tried and is worse: on a 4K panel
                    // it fills the top of the table with 4:3 and portrait
                    // geometries (2688 × 2016, 1920 × 2160) and pushes 1920 × 1080
                    // past the tenth row, because scaled point sizes have more
                    // pixels than 1080p does. "Declared" is the one ordering
                    // signal that comes from the panel's own descriptor rather
                    // than from a scaling factor, so it earns the higher rank.
                    let aIsNative = a.width == nativeGeometry?.width && a.height == nativeGeometry?.height
                    let bIsNative = b.width == nativeGeometry?.width && b.height == nativeGeometry?.height
                    if aIsNative != bIsNative { return aIsNative }

                    let aDeclared = !a.declaredRates.isEmpty
                    let bDeclared = !b.declaredRates.isEmpty
                    if aDeclared != bDeclared { return aDeclared }

                    let areaA = a.width * a.height
                    let areaB = b.width * b.height
                    if areaA != areaB { return areaA > areaB }
                    return a.width > b.width
                }

            return RefreshAudit(target: resolvedTarget, geometries: geometries)
        }
    }

    // MARK: - Refresh audit

    /// The result of `Report.audit(target:)`: one row per pixel geometry, each
    /// carrying what the panel declared, what macOS lists, and the link ceiling.
    public struct RefreshAudit {

        /// Why the target rate is or is not available at one geometry.
        ///
        /// Ordered by how much software can do about it: `offered` needs nothing,
        /// `hidden` needs a mode switch, `synthesizable` needs a timing the panel
        /// never declared, `beyondLink` needs different hardware or a smaller
        /// geometry.
        public enum Verdict: String, Sendable {
            case offered
            case hidden
            case synthesizable
            case beyondLink
            case unknown
        }

        /// A logical size that renders into a given pixel geometry.
        public struct PointSize: Hashable, Sendable {
            public let width: Int
            public let height: Int
            public let scale: Double

            public var description: String {
                let suffix = scale > 1.01 ? String(format: " (%.0f×)", scale) : ""
                return "\(width) × \(height)\(suffix)"
            }
        }

        public struct Geometry {
            public let width: Int
            public let height: Int
            public let pointSizes: [PointSize]
            /// Rates macOS lists at this pixel geometry, descending.
            public let offeredRates: [Double]
            /// Rates the panel declares at this pixel geometry, descending.
            public let declaredRates: [Double]
            /// Estimated link/vendor ceiling, `nil` when not readable.
            public let ceiling: Double?

            public var pixelDescription: String { "\(width) × \(height)" }

            public func verdict(for target: Double, tolerance: Double = 0.5) -> Verdict {
                if offeredRates.contains(where: { abs($0 - target) <= tolerance }) {
                    return .offered
                }
                // The link is the harder limit: a rate the panel declares but the
                // link cannot carry must not be reported as "just hidden by
                // macOS", because switching to it will fail.
                if let ceiling, target > ceiling + tolerance {
                    return .beyondLink
                }
                if declaredRates.contains(where: { abs($0 - target) <= tolerance }) {
                    return .hidden
                }
                guard let ceiling else { return .unknown }
                return target <= ceiling + tolerance ? .synthesizable : .beyondLink
            }
        }

        public let target: Double
        /// Row order: the native geometry first, then geometries the panel
        /// declares, then descending area. An ordering by how well the panel
        /// supports a row, not by size — `recommendedGeometry` explains why that
        /// is the useful one, and `offeredAtAnyGeometry` is where the exception
        /// lives.
        public let geometries: [Geometry]

        /// The best-supported geometry that reaches the target: already listed,
        /// unlockable from the private table, or synthesised within the budget.
        /// `nil` means no row reaches it — or that no row could be judged at all;
        /// `isUndetermined` tells those two apart.
        ///
        /// "Best-supported" is the row order, not the largest area — a row the
        /// panel itself declares outranks a scaled point size, so a synthesised
        /// 3360 × 1890 (a 4K desktop mode, not something anyone picks) does not
        /// beat a declared 1920 × 1080. For the zero-work answer at the largest
        /// selectable geometry, see `offeredAtAnyGeometry`.
        public var recommendedGeometry: Geometry? {
            geometries.first { geometry in
                let verdict = geometry.verdict(for: target)
                return verdict != .beyondLink && verdict != .unknown
            }
        }

        /// The largest geometry where the target rate is already selectable.
        ///
        /// Kept separate from `recommendedGeometry`, which answers a different
        /// question: the best-supported geometry that *could* reach the rate,
        /// possibly only after a mode-table switch or a synthesised timing.
        ///
        /// This one takes the largest area among the offered rows rather than the
        /// first row in the table. Table order ranks native and panel-declared
        /// geometries above size, so the first offered row is often a 640 × 480
        /// mode sitting near the top — true, but not the answer anyone wants when
        /// a 2048 × 1536 mode further down already lists the same rate.
        public var offeredAtAnyGeometry: Geometry? {
            geometries
                .filter { $0.verdict(for: target) == .offered }
                .max { $0.width * $0.height < $1.width * $1.height }
        }

        public var isTargetReachable: Bool { recommendedGeometry != nil }

        /// True when not one row could be judged, because no geometry published a
        /// link budget.
        ///
        /// This is a different answer from "unreachable", and conflating the two
        /// would claim a measurement that was never taken: the honest report is
        /// "cannot tell". `unknown` exists per row precisely to prevent that, so
        /// the report as a whole needs the same distinction.
        public var isUndetermined: Bool {
            !geometries.isEmpty
                && geometries.allSatisfy { $0.verdict(for: target) == .unknown }
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
            }(),
            offeredModes: modes
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
