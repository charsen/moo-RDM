import CoreGraphics
import Foundation

/// Display rotation.
///
/// **Reading is public** — `CGDisplayRotation` has been available since 10.5.
///
/// **Writing has no public API.** On macOS 27 / arm64 the candidates were probed:
///
/// | Symbol | Result |
/// |---|---|
/// | `CGXSetDisplayRotation` | exists, but crashes with a 2- or 3-argument call |
/// | `DisplayServicesSetRotation` | not present |
/// | `CGSSetDisplayRotation` | not present |
/// | `SLSSetDisplayRotation` | **works** |
///
/// The working signature was confirmed live: rotating a display to 90° reported
/// `CGDisplayRotation == 90`, and rotating back to 0° restored it, both returning
/// `kCGErrorSuccess`.
///
/// This is the only write path in RDM-ARM that touches a private interface, it is
/// opt-out from Preferences, and it degrades silently when unavailable.
public enum DisplayRotationController {

    public static let supportedAngles: [Double] = [0, 90, 180, 270]

    public enum RotationError: Error, CustomStringConvertible {
        case disabled
        case unavailable
        case unsupportedAngle(Double)
        case failed(Int32)

        public var description: String {
            switch self {
            case .disabled, .unavailable:
                return L10n.t("error.rotationUnsupported")
            case .unsupportedAngle(let angle):
                return L10n.t("error.rotationUnsupported") + " (\(Int(angle))°)"
            case .failed(let code):
                return L10n.t("error.rotationFailed", code)
            }
        }
    }

    private typealias SetRotationFunction = @convention(c) (CGDirectDisplayID, UInt32) -> Int32

    private static let setter: SetRotationFunction? =
        PrivateSymbolLoader.shared.load("SLSSetDisplayRotation", as: SetRotationFunction.self)

    /// True when rotation can actually be changed on this machine right now.
    public static var isAvailable: Bool {
        Preferences.shared.enableOptionalModule && setter != nil
    }

    /// Whether the private symbol exists, regardless of the preference toggle.
    public static var isSymbolPresent: Bool { setter != nil }

    /// Current rotation in degrees.
    public static func currentRotation(of displayID: CGDirectDisplayID) -> Double {
        CGDisplayRotation(displayID)
    }

    @discardableResult
    public static func setRotation(_ degrees: Double,
                                   on displayID: CGDirectDisplayID) -> Result<Void, RotationError> {
        guard Preferences.shared.enableOptionalModule else { return .failure(.disabled) }
        guard let setter else { return .failure(.unavailable) }

        let angle = normalize(degrees)
        guard supportedAngles.contains(angle) else { return .failure(.unsupportedAngle(degrees)) }

        let status = setter(displayID, UInt32(angle))
        guard status == 0 else { return .failure(.failed(status)) }

        // `SLSSetDisplayRotation` writes into the pending display configuration.
        // Once this process has changed a display configuration (for example after
        // `ModeController.apply`), the rotation is ignored until a configuration is
        // committed; the setter still returns success. An empty commit flushes it.
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            _ = CGCompleteDisplayConfiguration(config, .forSession)
        }
        return .success(())
    }

    /// Wraps any angle into 0..<360.
    public static func normalize(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    /// Localised label for a rotation angle.
    public static func label(for degrees: Double) -> String {
        L10n.t("rotation.\(Int(normalize(degrees)))")
    }
}
