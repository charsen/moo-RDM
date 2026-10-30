import Foundation

/// Static facts about the app, in one place.
public enum AppInfo {

    public static let name = "RDM-ARM"

    public static let version = "1.2.2"

    public static let build = "2"

    public static let bundleIdentifier = "com.mooeen.rdm"

    /// Upstream project this is a rework of.
    public static let upstreamURL = URL(string: "https://github.com/avibrazil/RDM")!

    public static var versionDescription: String { "\(name) \(version) (build \(build))" }

    /// A short diagnostic block users can paste into a bug report.
    public static func diagnostics() -> String {
        var lines: [String] = []
        lines.append(versionDescription)
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("architecture: \(architecture)")
        lines.append("engine: CoreGraphics (public; optional module adds private interfaces)")
        lines.append("optional module enabled: \(Preferences.shared.enableOptionalModule)")
        lines.append("SLSSetDisplayRotation present: \(DisplayRotationController.isSymbolPresent)")
        lines.append("private mode table: \(PrivateModeTable.isSymbolPresent ? "present" : "absent")")

        let snapshots = DisplayManager.snapshots()
        lines.append("displays: \(snapshots.count)")
        for snapshot in snapshots {
            let display = snapshot.display
            lines.append("  [\(display.ordinal)] \(display.name)")
            lines.append("      id=\(display.id) builtin=\(display.isBuiltin) main=\(display.isMain)")
            lines.append("      identity=\(display.identity.key)")
            lines.append("      current=\(display.currentDescription)")
            lines.append("      rotation=\(Int(display.rotation))°")
            if let native = display.nativePixelSize {
                lines.append("      native=\(native.description)")
            }
            let all = snapshot.modes
            let exposed = all.filter { !$0.isPrivate }
            let usable = exposed.filter(\.isUsable).count
            let hiDPI = exposed.filter(\.isHiDPI).count
            let hidden = all.count - exposed.count
            lines.append("      modes=\(exposed.count) (usable=\(usable), hidpi=\(hiDPI))"
                         + (hidden > 0 ? " + \(hidden) hidden HiDPI" : ""))
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
