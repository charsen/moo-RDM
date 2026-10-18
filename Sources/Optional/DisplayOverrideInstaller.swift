import CoreGraphics
import Darwin
import Foundation

/// Installs and removes a display override — the only mechanism on Apple silicon
/// for teaching macOS a timing the panel did not advertise.
///
/// How it works: `/Library/Displays/Contents/Resources/Overrides/` mirrors the
/// system's own display database. A file named after the panel's EDID vendor and
/// product replaces the panel's EDID blob for the whole system, and macOS then
/// enumerates modes from *that* blob instead. This is exactly the shape Apple
/// itself ships — e.g.
/// `/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-10ac/DisplayProductID-4093`
/// is a three-key plist holding `IODisplayEDID`.
///
/// `/Library` (not `/System`) is used on purpose: it is the user-installable
/// layer, so no SIP changes and no disabled security are required. Writing there
/// needs administrator rights, which is why every mutation goes through a single
/// `do shell script … with administrator privileges` call.
///
/// This is an optional module: nothing here runs unless the user asks for it, and
/// every mutation is preceded by a backup and paired with `revert`.
enum DisplayOverrideInstaller {

    // MARK: - Availability

    /// Whether writing a plist here actually reaches the display pipeline.
    ///
    /// Measured on M4 Max / macOS 27.0.1 / BenQ PD2705U: the plist lands exactly
    /// where Apple's own overrides live and validates, and the system still
    /// enumerates the panel's own EDID afterwards. The three triggers that are
    /// documented to reload the display database were all tried — cable re-plug,
    /// display sleep/wake, full system sleep/wake — and every one of them left the
    /// mode list at 290 entries with the live `EDID` property untouched (the
    /// descriptor slot we patched read back as `0.00 MHz`).
    ///
    /// On Apple silicon the only mechanism that does work is a private live
    /// injection, which has no exported entry point on this system:
    /// `CoreDisplay_Display_SetEDID`, `SLSDisplaySetEDID`, `CGSDisplaySetEDID`,
    /// `DisplayServicesSetEDID` do not exist, and `IOAVService*` exists as symbols
    /// but has no instance to attach to.
    ///
    /// So the honest thing is to say "this cannot work here" before asking for an
    /// administrator password. `RDM_ALLOW_EDID_OVERRIDE=1` forces the old
    /// behaviour, which is how a future macOS release can be re-tested without
    /// rebuilding.
    enum Support {
        case available
        case inertOnAppleSilicon

        var isAvailable: Bool { self == .available }
    }

    /// Whether this *machine* is Apple silicon — which is not the same question
    /// as whether this *slice* of the universal binary is arm64.
    ///
    /// `#if arch(arm64)` only answers the second. The x86_64 slice running under
    /// Rosetta on an M-series Mac would answer "no", conclude it was on Intel,
    /// and re-enable the write path: ask for an administrator password, install
    /// an override, and report success for something the display pipeline then
    /// ignores. `hw.optional.arm64` is a hardware property, so it reads the same
    /// from either slice; on an Intel Mac the key does not exist at all.
    private static var isAppleSiliconHost: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    static var support: Support {
        if ProcessInfo.processInfo.environment["RDM_ALLOW_EDID_OVERRIDE"] == "1" {
            return .available
        }
        return isAppleSiliconHost ? .inertOnAppleSilicon : .available
    }

    // MARK: - Paths

    struct Target: Hashable {
        let vendor: UInt32
        let product: UInt32

        /// Apple names these directories without zero padding, e.g.
        /// `DisplayVendorID-469`, `DisplayVendorID-9d1`.
        var directory: String {
            String(format: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x", vendor)
        }

        var path: String {
            directory + String(format: "/DisplayProductID-%x", product)
        }

        /// User-domain copy kept in Application Support so `revert` never needs
        /// the original file to still exist on disk.
        var backupDirectory: String {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/RDM-ARM/overrides")
                .path
            return base + String(format: "/DisplayVendorID-%x", vendor)
        }

        var backupPath: String {
            backupDirectory + String(format: "/DisplayProductID-%x", product)
        }
    }

    static func target(for edid: EDID) -> Target {
        Target(vendor: edid.vendor, product: edid.product)
    }

    // MARK: - State

    /// The override currently installed for this panel, if any.
    static func installedEDID(for edid: EDID) -> EDID? {
        let target = target(for: edid)
        guard let data = FileManager.default.contents(atPath: target.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let blob = dictionary["IODisplayEDID"] as? Data
        else { return nil }
        return EDID(data: blob)
    }

    static func hasOverride(for edid: EDID) -> Bool {
        FileManager.default.fileExists(atPath: target(for: edid).path)
    }

    static func hasBackup(for edid: EDID) -> Bool {
        FileManager.default.fileExists(atPath: target(for: edid).backupPath)
    }

    // MARK: - Mutations

    /// Writes `edid` as the system-wide override for its own panel.
    ///
    /// - Throws: `InstallError` with the shell's message when authorisation is
    ///   cancelled or the copy fails.
    static func install(_ edid: EDID) throws {
        let target = target(for: edid)
        try backupExistingOverride(target: target)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdm-override-\(UUID().uuidString).plist")
        let payload: [String: Any] = [
            "DisplayVendorID": Int(edid.vendor),
            "DisplayProductID": Int(edid.product),
            "IODisplayEDID": edid.data,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload,
                                                      format: .binary,
                                                      options: 0)
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let command = [
            "/bin/mkdir -p \(shellQuote(target.directory))",
            "/usr/bin/install -m 644 -o root -g wheel \(shellQuote(temporary.path)) \(shellQuote(target.path))",
        ].joined(separator: " && ")

        try runAsAdministrator(command)
    }

    /// Restores the file that was there before `install`, or removes the override
    /// entirely when there was none.
    static func revert(for edid: EDID) throws {
        let target = target(for: edid)
        var commands: [String] = []

        if FileManager.default.fileExists(atPath: target.backupPath) {
            commands.append("/bin/mkdir -p \(shellQuote(target.directory))")
            commands.append("/usr/bin/install -m 644 -o root -g wheel "
                            + "\(shellQuote(target.backupPath)) \(shellQuote(target.path))")
        } else {
            commands.append("/bin/rm -f \(shellQuote(target.path))")
            commands.append("/bin/rmdir \(shellQuote(target.directory)) 2>/dev/null || true")
        }

        try runAsAdministrator(commands.joined(separator: " && "))
        try? FileManager.default.removeItem(atPath: target.backupPath)
    }

    // MARK: - Backup

    private static func backupExistingOverride(target: Target) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: target.backupDirectory,
                                        withIntermediateDirectories: true)

        // A previous backup must not be overwritten by a backup of *our* own
        // override — that would make revert restore the modified blob.
        if fileManager.fileExists(atPath: target.backupPath) { return }

        try? fileManager.removeItem(atPath: target.backupPath)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.copyItem(atPath: target.path, toPath: target.backupPath)
        }
    }

    // MARK: - Privileged execution

    enum InstallError: Error, CustomStringConvertible {
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .cancelled: return L10n.t("error.overrideCancelled")
            case .failed(let message): return message
            }
        }
    }

    /// Runs one shell command with administrator rights.
    ///
    /// The command is passed as an *argument* to `do shell script`, not spliced
    /// into AppleScript source, so there is no second layer of quoting to get
    /// wrong.
    private static func runAsAdministrator(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            command,
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript reports a user cancel as error -128.
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            throw InstallError.cancelled
        }
        throw InstallError.failed(message.isEmpty ? L10n.t("error.overrideFailed") : message)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
