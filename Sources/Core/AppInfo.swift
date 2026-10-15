import Foundation

/// Static facts about the app, in one place.
public enum AppInfo {

    public static let name = "RDM-ARM"

    public static let version = "1.0.2"

    public static let build = "1"

    public static let bundleIdentifier = "io.rdmarm.RDM-ARM"

    /// Upstream project this is a rework of.
    public static let upstreamURL = URL(string: "https://github.com/avibrazil/RDM")!

    public static var versionDescription: String { "\(name) \(version) (build \(build))" }

    /// A short diagnostic block users can paste into a bug report.
    public static func diagnostics() -> String {
        var lines: [String] = []
        lines.append(versionDescription)
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("architecture: \(architecture)")
        lines.append("engine: public CoreGraphics API")
        lines.append("optional module enabled: \(Preferences.shared.enableOptionalModule)")
        lines.append("SLSSetDisplayRotation present: \(DisplayRotationController.isSymbolPresent)")

        let displays = DisplayManager.allDisplays()
        lines.append("displays: \(displays.count)")
        for display in displays {
            lines.append("  [\(display.ordinal)] \(display.name)")
            lines.append("      id=\(display.id) builtin=\(display.isBuiltin) main=\(display.isMain)")
            lines.append("      identity=\(display.identity.key)")
            lines.append("      current=\(display.currentDescription)")
            lines.append("      rotation=\(Int(display.rotation))°")
            if let native = display.nativePixelSize {
                lines.append("      native=\(native.description)")
            }
            let all = DisplayManager.allModes(for: display.id)
            let usable = all.filter(\.isUsable).count
            let hiDPI = all.filter(\.isHiDPI).count
            lines.append("      modes=\(all.count) (usable=\(usable), hidpi=\(hiDPI))")
        }
        return lines.joined(separator: "\n")
    }

    /// "arm64" or "x86_64".
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
