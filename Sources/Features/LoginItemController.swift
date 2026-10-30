import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+).
///
/// The system owns the actual login-item state: registering can end in
/// `.requiresApproval` until the user allows the app under System Settings →
/// General → Login Items. The settings checkbox reflects that state rather than
/// pretending the item is active.
enum LoginItemController {

    enum State: CustomStringConvertible {
        case enabled
        case disabled
        case requiresApproval
        case unavailable

        var description: String {
            switch self {
            case .enabled: return "enabled"
            case .disabled: return "not registered"
            case .requiresApproval: return "requires approval"
            case .unavailable: return "unavailable"
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            // Current macOS reports `.notFound` for a main app that has never
            // been registered. Treating that as unavailable would disable the
            // checkbox on every fresh install; register() is still valid.
            return .disabled
        @unknown default:
            return .unavailable
        }
    }

    static var isEnabled: Bool {
        state == .enabled || state == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
