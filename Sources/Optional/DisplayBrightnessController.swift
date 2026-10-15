import CoreGraphics
import Foundation

/// Software brightness control.
///
/// There is no public API for this at all, so it goes through
/// `DisplayServices` (private). Crucially, the framework exposes
/// `DisplayServicesCanChangeBrightness`, which is an honest capability probe —
/// RDM-ARM uses it to hide the brightness control entirely on displays that do
/// not support it, rather than showing a slider that does nothing.
///
/// Measured on an external display over DisplayPort: `CanChangeBrightness`
/// returned 0 and `GetBrightness` returned `kCGErrorFailure`, so the feature
/// correctly hides itself. On a built-in panel or a DDC-capable display it works.
public enum DisplayBrightnessController {

    public enum BrightnessError: Error, CustomStringConvertible {
        case disabled
        case unavailable
        case unsupported
        case failed(Int32)

        public var description: String {
            switch self {
            case .disabled, .unavailable, .unsupported:
                return L10n.t("error.brightnessUnsupported")
            case .failed(let code):
                return L10n.t("error.brightnessUnsupported") + " (\(code))"
            }
        }
    }

    private typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFunction = @convention(c) (CGDirectDisplayID) -> Bool

    private static let getter: GetBrightnessFunction? =
        PrivateSymbolLoader.shared.load("DisplayServicesGetBrightness", as: GetBrightnessFunction.self)
    private static let setter: SetBrightnessFunction? =
        PrivateSymbolLoader.shared.load("DisplayServicesSetBrightness", as: SetBrightnessFunction.self)
    private static let canChange: CanChangeFunction? =
        PrivateSymbolLoader.shared.load("DisplayServicesCanChangeBrightness", as: CanChangeFunction.self)

    /// Whether this display reports that brightness can be changed in software.
    /// Call this before showing any brightness UI.
    public static func canChangeBrightness(of displayID: CGDirectDisplayID) -> Bool {
        guard Preferences.shared.enableOptionalModule,
              getter != nil, setter != nil, let canChange else { return false }
        return canChange(displayID)
    }

    /// Current brightness in 0...1, or `nil` when unsupported.
    public static func brightness(of displayID: CGDirectDisplayID) -> Float? {
        guard canChangeBrightness(of: displayID), let getter else { return nil }
        var value: Float = -1
        guard getter(displayID, &value) == 0, value >= 0 else { return nil }
        return value
    }

    @discardableResult
    public static func setBrightness(_ value: Float,
                                     on displayID: CGDirectDisplayID) -> Result<Void, BrightnessError> {
        guard Preferences.shared.enableOptionalModule else { return .failure(.disabled) }
        guard let setter, canChangeBrightness(of: displayID) else { return .failure(.unsupported) }
        let clamped = min(max(value, 0), 1)
        let status = setter(displayID, clamped)
        guard status == 0 else { return .failure(.failed(status)) }
        return .success(())
    }

    /// Nudges brightness by `delta`, clamped to 0...1. Returns the new value.
    @discardableResult
    public static func adjust(_ delta: Float,
                              on displayID: CGDirectDisplayID) -> Float? {
        guard let current = brightness(of: displayID) else { return nil }
        let target = min(max(current + delta, 0), 1)
        guard case .success = setBrightness(target, on: displayID) else { return nil }
        return target
    }
}
