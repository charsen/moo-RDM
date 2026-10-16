import CoreGraphics
import Foundation

/// Applies display modes through the public CoreGraphics configuration API.
///
/// The three-call sequence — begin, configure, complete — is the supported way to
/// change a mode atomically. `CGDisplaySetDisplayMode` also exists, but it is
/// session-scoped and reverts when the process exits, so it is not used here.
///
/// Verified on macOS 27 / arm64: all three calls return `kCGErrorSuccess`.
public enum ModeController {

    public enum ApplyError: Error, CustomStringConvertible {
        case beginFailed(CGError)
        case configureFailed(CGError)
        case completeFailed(CGError)
        case modeNotFound(String)

        public var description: String {
            switch self {
            case .beginFailed(let code):
                return L10n.t("error.setModeFailed", Int32(code.rawValue))
            case .configureFailed(let code):
                return L10n.t("error.setModeFailed", Int32(code.rawValue))
            case .completeFailed(let code):
                return L10n.t("error.setModeFailed", Int32(code.rawValue))
            case .modeNotFound(let description):
                return L10n.t("error.noSuchMode", description)
            }
        }
    }

    // MARK: - Applying

    /// Switches the display to `mode`.
    ///
    /// - Parameter permanently: persist across restarts (`kCGConfigurePermanently`)
    ///   instead of only for this session (`kCGConfigureForSession`).
    ///
    /// Modes that only exist in the private table have no `CGDisplayMode`, so they
    /// take the private configure call instead of the public one. Everything else
    /// goes through the public API as before.
    @discardableResult
    public static func apply(_ mode: DisplayMode,
                             permanently: Bool = false) -> Result<Void, ApplyError> {
        guard let cgMode = mode.cgMode else {
            let status = PrivateModeTable.apply(modeID: mode.modeID,
                                                on: mode.displayID,
                                                permanently: permanently)
            guard status == .success else { return .failure(.configureFailed(status)) }
            return .success(())
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            return .failure(.beginFailed(begin))
        }

        let configure = CGConfigureDisplayWithDisplayMode(config, mode.displayID, cgMode, nil)
        guard configure == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(.configureFailed(configure))
        }

        let complete = CGCompleteDisplayConfiguration(
            config, permanently ? .permanently : .forSession
        )
        guard complete == .success else {
            return .failure(.completeFailed(complete))
        }
        return .success(())
    }

    // MARK: - Searching

    /// Finds the single best mode matching the given constraints.
    ///
    /// Preference order: exact geometry → requested scale → requested refresh rate.
    /// When no refresh rate is requested the highest available one wins, and modes
    /// the system considers usable are preferred over hidden ones.
    public static func findMode(on displayID: CGDirectDisplayID,
                                width: Int? = nil,
                                height: Int? = nil,
                                scale: Double? = nil,
                                refreshRate: Double? = nil,
                                includeUnusable: Bool = true,
                                hiDPIOnly: Bool = false) -> DisplayMode? {
        var candidates = DisplayManager.allModes(for: displayID, includeUnusable: includeUnusable)
        if hiDPIOnly { candidates = candidates.filter(\.isHiDPI) }
        if let width { candidates = candidates.filter { $0.width == width } }
        if let height { candidates = candidates.filter { $0.height == height } }
        if let scale {
            candidates = candidates.filter { abs($0.scale - scale) < 0.01 }
        }
        guard !candidates.isEmpty else { return nil }

        if let refreshRate {
            let exact = candidates.filter { abs($0.refreshRate - refreshRate) < 0.5 }
            if !exact.isEmpty { candidates = exact }
        }

        return candidates.sorted { a, b in
            // Prefer modes the system actually offers for the desktop GUI.
            if a.isUsable != b.isUsable { return a.isUsable }
            // Then prefer the highest refresh rate.
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.modeID < b.modeID
        }.first
    }

    /// Human-readable description of a search, used in error messages.
    public static func describe(width: Int?, height: Int?, scale: Double?, refreshRate: Double?) -> String {
        var parts: [String] = []
        if let width, let height { parts.append("\(width) × \(height)") }
        else if let width { parts.append("width \(width)") }
        else if let height { parts.append("height \(height)") }
        if let scale { parts.append(scale >= 2 ? "HiDPI @\(Int(scale))x" : "scale \(scale)") }
        if let refreshRate { parts.append(String(format: "%.0f Hz", refreshRate)) }
        return parts.isEmpty ? "any mode" : parts.joined(separator: ", ")
    }

    /// Convenience: search and apply in one step, reporting the mode that was used.
    @discardableResult
    public static func applyResolution(on displayID: CGDirectDisplayID,
                                       width: Int? = nil,
                                       height: Int? = nil,
                                       scale: Double? = nil,
                                       refreshRate: Double? = nil,
                                       permanently: Bool = false,
                                       includeUnusable: Bool = true,
                                       hiDPIOnly: Bool = false) -> Result<DisplayMode, ApplyError> {
        let description = describe(width: width, height: height, scale: scale, refreshRate: refreshRate)
        guard let mode = findMode(on: displayID,
                                  width: width, height: height,
                                  scale: scale, refreshRate: refreshRate,
                                  includeUnusable: includeUnusable,
                                  hiDPIOnly: hiDPIOnly) else {
            return .failure(.modeNotFound(description))
        }
        switch apply(mode, permanently: permanently) {
        case .success:      return .success(mode)
        case .failure(let error): return .failure(error)
        }
    }

    /// Restores the mode macOS considers the display's default.
    @discardableResult
    public static func resetToDefault(on displayID: CGDirectDisplayID,
                                      permanently: Bool = false) -> Result<DisplayMode, ApplyError> {
        guard let mode = DisplayManager.defaultMode(for: displayID) else {
            return .failure(.modeNotFound("system default"))
        }
        switch apply(mode, permanently: permanently) {
        case .success:            return .success(mode)
        case .failure(let error): return .failure(error)
        }
    }
}
