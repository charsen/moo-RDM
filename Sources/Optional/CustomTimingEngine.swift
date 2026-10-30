import CoreGraphics
import Foundation

/// Synthesises a refresh rate the panel never advertised and hands it to the
/// system as an override.
///
/// The chain is deliberately short and every step is verified:
///   1. read the panel's own EDID and its link budget;
///   2. take a timing the panel already locks onto at that geometry, or scale the
///      native one when there is none;
///   3. re-clock it (blanking untouched) to the requested rate;
///   4. refuse if the result needs more pixel rate than the link publishes;
///   5. write the patched EDID as a display override and ask for a reprobe.
///
/// Step 4 is the part that keeps this honest. "Beyond the listed modes" is not
/// the same as "beyond the hardware", and a tool that will not say which one it
/// is doing is just a way to black your screen.
enum CustomTimingEngine {

    struct Proposal {
        /// The descriptor that will be added to the EDID.
        let timing: DetailedTiming
        /// The EDID with `timing` written into a spare slot.
        let edid: EDID
        let requestedRefresh: Double
        let width: Int
        let height: Int
        /// True when no descriptor existed at this geometry and the blanking was
        /// scaled from the native timing.
        let isSyntheticGeometry: Bool
        /// Link and vendor ceiling at this geometry, when known.
        let estimatedMaximumRefresh: Double?

        var encodedRefresh: Double { timing.refreshRate }
        var pixelRateMHz: Double { Double(timing.pixelRate) / 1_000_000 }

        /// Difference between what was asked for and what the 10 kHz pixel-clock
        /// grid can actually encode.
        var quantisationError: Double { encodedRefresh - requestedRefresh }

        var overBudget: Bool {
            guard let maximum = estimatedMaximumRefresh else { return false }
            return requestedRefresh > maximum + 0.5
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case optionalModuleDisabled
        case noEDID
        case noNativeTiming
        case geometryTooLarge(String)
        case clockCeilingExceeded(Double)
        case aboveBudget(requested: Double, maximum: Double)
        case noTimingSlot
        case overrideUnavailable

        var description: String {
            switch self {
            case .optionalModuleDisabled:
                return L10n.t("error.timingOptionalDisabled")
            case .noEDID:
                return L10n.t("error.timingNoEDID")
            case .noNativeTiming:
                return L10n.t("error.timingNoNative")
            case .geometryTooLarge(let geometry):
                return L10n.t("error.timingGeometry", geometry)
            case .clockCeilingExceeded(let megahertz):
                return L10n.t("error.timingClockCeiling", Int32(megahertz.rounded()))
            case .aboveBudget(let requested, let maximum):
                return L10n.t("error.timingBudget",
                              Int32(requested.rounded()), Int32(maximum.rounded()))
            case .noTimingSlot:
                return L10n.t("error.timingNoSlot")
            case .overrideUnavailable:
                return L10n.t("error.timingOverride")
            }
        }
    }

    // MARK: - Proposal

    static func propose(width: Int, height: Int, refresh: Double,
                        for displayID: CGDirectDisplayID) -> Result<Proposal, Failure> {
        guard Preferences.shared.enableOptionalModule else { return .failure(.optionalModuleDisabled) }

        let report = DisplayCapabilities.report(for: displayID)
        guard let edid = report.edid else { return .failure(.noEDID) }

        // Budget first. A request the link cannot carry should say so, rather
        // than failing later as "cannot encode this timing" — that message would
        // blame the descriptor for a bandwidth problem.
        let maximum = report.estimatedMaximumRefresh(width: width, height: height)
        if let maximum, refresh > maximum + 0.5 {
            return .failure(.aboveBudget(requested: refresh, maximum: maximum))
        }

        // Prefer a descriptor the panel already uses at this exact geometry: its
        // blanking is proven. Fall back to scaling the native timing, which is an
        // approximation and is flagged as such.
        var isSynthetic = false
        var base: DetailedTiming?
        if let exact = edid.detailedTimings.first(where: { $0.width == width && $0.height == height }) {
            base = exact.retimed(toRefresh: refresh)
        } else if let native = report.nativeTiming {
            base = native.scaled(toWidth: width, toHeight: height, refresh: refresh)
            isSynthetic = true
        }
        guard let timing = base else {
            // "Cannot scale the native timing" and "the descriptor's clock field
            // overflows" need different advice: the first is an unsupported
            // geometry, the second is exactly why a 5K panel cannot take a
            // synthesised timing at all.
            let reference = edid.detailedTimings.first(where: {
                $0.width == width && $0.height == height
            }) ?? report.nativeTiming
            if let reference,
               let rate = reference.estimatedPixelRate(width: width, height: height, refresh: refresh),
               rate > DetailedTiming.maximumPixelClockHz {
                return .failure(.clockCeilingExceeded(rate / 1_000_000))
            }
            if report.nativeTiming == nil { return .failure(.noNativeTiming) }
            return .failure(.geometryTooLarge("\(width) × \(height)"))
        }

        guard let patched = edid.adding(timing) else { return .failure(.noTimingSlot) }

        return .success(Proposal(timing: timing,
                                 edid: patched,
                                 requestedRefresh: refresh,
                                 width: width,
                                 height: height,
                                 isSyntheticGeometry: isSynthetic,
                                 estimatedMaximumRefresh: maximum))
    }

    // MARK: - Apply

    /// Writes the override and asks the system to re-enumerate.
    ///
    /// - Returns: `true` when the mode list visibly changed afterwards.
    @discardableResult
    static func install(_ proposal: Proposal,
                        for displayID: CGDirectDisplayID) throws -> Bool {
        try DisplayOverrideInstaller.install(proposal.edid)
        return DisplayEDIDReader.requestReprobe(for: displayID, timeout: 4.0)
    }

    static func revert(for displayID: CGDirectDisplayID) throws {
        guard let edid = DisplayEDIDReader.read(for: displayID) else {
            throw Failure.noEDID
        }
        try DisplayOverrideInstaller.revert(for: edid)
        _ = DisplayEDIDReader.requestReprobe(for: displayID, timeout: 4.0)
    }

    static func isInstalled(for displayID: CGDirectDisplayID) -> Bool {
        guard let edid = DisplayEDIDReader.read(for: displayID) else { return false }
        return DisplayOverrideInstaller.hasEDIDOverride(for: edid)
    }
}
