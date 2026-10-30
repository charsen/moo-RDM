import CoreGraphics
import Darwin
import Foundation

/// Installs and removes a display override under
/// `/Library/Displays/Contents/Resources/Overrides/`.
///
/// The directory mirrors the system's own display database. A file named after
/// the panel's EDID vendor and product carries two independent kinds of data:
///
/// | Key | What it changes | Apple silicon |
/// |---|---|---|
/// | `IODisplayEDID` | replaces the panel's EDID blob | **ignored** — measured on M4 Max; the live EDID stays the panel's own |
/// | `scale-resolutions` | adds point sizes to the mode table | **honoured** — measured on M4 Max; 26 → 28 modes after re-attach |
///
/// Because the two mechanisms behave differently, availability is answered per
/// mechanism. Treating "Apple silicon ignores overrides" as one fact would
/// disable the one route that actually works.
///
/// Every write merges into the existing payload instead of replacing it, so an
/// EDID patch cannot silently delete a scaled-resolution entry (or vice versa).
///
/// `/Library` (not `/System`) is used on purpose: it is the user-installable
/// layer, so no SIP changes and no disabled security are required. Writing there
/// needs administrator rights, which is why every mutation goes through a single
/// `do shell script … with administrator privileges` call.
///
/// This is an optional module: nothing here runs unless the user asks for it, and
/// every mutation is preceded by a backup and paired with `revert`.
enum DisplayOverrideInstaller {

    // MARK: - Mechanisms

    enum Mechanism {
        case edidBlob
        case scaledResolutions
    }

    /// Whether writing a plist here actually reaches the display pipeline.
    ///
    /// `edidBlob` was measured inert on Apple silicon: the plist lands exactly
    /// where Apple's own overrides live and validates, and the system still
    /// enumerates the panel's own EDID afterwards. Cable re-plug, display
    /// sleep/wake and full system sleep/wake all left the mode list unchanged.
    ///
    /// `scaledResolutions` is the opposite: after adding one 8-byte entry and
    /// re-attaching the display, the mode list grows and the new point size can
    /// be applied. That is why the two are answered separately.
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

    static func support(for mechanism: Mechanism) -> Support {
        switch mechanism {
        case .edidBlob:
            if ProcessInfo.processInfo.environment["RDM_ALLOW_EDID_OVERRIDE"] == "1" {
                return .available
            }
            return isAppleSiliconHost ? .inertOnAppleSilicon : .available
        case .scaledResolutions:
            return .available
        }
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

        /// Apple's own entry for this panel, used as the baseline when adding a
        /// scaled resolution and as the "nothing custom left" comparison.
        var systemPath: String {
            String(format: "/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x",
                   vendor, product)
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

    // MARK: - Reading

    /// The override currently on disk for this panel, if any.
    static func installedPayload(for edid: EDID) -> [String: Any]? {
        readPayload(at: target(for: edid).path)
    }

    /// Apple's own entry for this panel, when it ships one.
    static func systemPayload(for edid: EDID) -> [String: Any]? {
        readPayload(at: target(for: edid).systemPath)
    }

    private static func readPayload(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func backupPayload(target: Target) -> [String: Any]? {
        readPayload(at: target.backupPath)
    }

    static func hasEDIDOverride(for edid: EDID) -> Bool {
        installedPayload(for: edid)?["IODisplayEDID"] != nil
    }

    /// Scaled resolutions this app added on top of Apple's own entry.
    static func scaledResolutions(for edid: EDID) -> [ScaledResolution] {
        scaledResolutions(vendor: edid.vendor, product: edid.product)
    }

    /// Same lookup without reading the EDID: the menu only needs the panel's
    /// vendor/product numbers, which CoreGraphics already exposes.
    static func scaledResolutions(vendor: UInt32, product: UInt32) -> [ScaledResolution] {
        let target = Target(vendor: vendor, product: product)
        let installed = ScaleResolutionStore.rawEntries(in: readPayload(at: target.path))
        let baseline = ScaleResolutionStore.rawEntries(in: readPayload(at: target.systemPath))
        return ScaleResolutionStore.customEntries(installed: installed, baseline: baseline)
            .compactMap(ScaledResolution.decode)
    }

    static func hasScaledResolutions(for edid: EDID) -> Bool {
        !scaledResolutions(for: edid).isEmpty
    }

    static func hasAnyOverride(for edid: EDID) -> Bool {
        hasEDIDOverride(for: edid) || hasScaledResolutions(for: edid)
    }

    // MARK: - Mutations

    /// Writes `edid` as the system-wide override for its own panel.
    ///
    /// Merges into the existing payload: an EDID patch must not wipe a
    /// `scale-resolutions` array, and vice versa.
    static func install(_ edid: EDID) throws {
        var payload = installedPayload(for: edid) ?? systemPayload(for: edid) ?? [:]
        payload["IODisplayEDID"] = edid.data
        try write(payload, for: edid)
    }

    static func installScaledResolutions(_ resolutions: [ScaledResolution], for edid: EDID) throws {
        var payload = installedPayload(for: edid) ?? systemPayload(for: edid) ?? [:]
        for resolution in resolutions {
            payload = ScaleResolutionStore.merged(payload: payload, adding: resolution)
        }
        try write(payload, for: edid)
    }

    static func removeScaledResolutions(_ resolutions: [ScaledResolution], for edid: EDID) throws {
        guard var payload = installedPayload(for: edid) else { return }
        for resolution in resolutions {
            payload = ScaleResolutionStore.merged(payload: payload, removing: resolution)
        }
        if isRedundant(payload, for: edid) {
            try delete(for: edid)
        } else {
            try write(payload, for: edid)
        }
    }

    /// Removes the EDID patch only. Scaled-resolution entries survive, because
    /// they are a different mechanism with a different owner — reverting one
    /// must never undo the other.
    static func revert(for edid: EDID) throws {
        let target = target(for: edid)
        guard var payload = installedPayload(for: edid) else {
            try? FileManager.default.removeItem(atPath: target.backupPath)
            return
        }

        let backup = backupPayload(target: target)
        if let original = backup?["IODisplayEDID"] as? Data {
            payload["IODisplayEDID"] = original
        } else {
            payload.removeValue(forKey: "IODisplayEDID")
        }

        if isRedundant(payload, for: edid) {
            try delete(for: edid)
        } else {
            try write(payload, for: edid)
        }
        try? FileManager.default.removeItem(atPath: target.backupPath)
    }

    // MARK: - Writing

    private static func write(_ payload: [String: Any], for edid: EDID) throws {
        let target = target(for: edid)
        try backupExistingOverride(target: target)

        var merged = payload
        merged["DisplayVendorID"] = Int(edid.vendor)
        merged["DisplayProductID"] = Int(edid.product)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdm-override-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: merged,
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

    private static func delete(for edid: EDID) throws {
        let target = target(for: edid)
        let command = "/bin/rm -f \(shellQuote(target.path))"
            + " && /bin/rmdir \(shellQuote(target.directory)) 2>/dev/null || true"
        try runAsAdministrator(command)
    }

    /// True when the payload carries nothing beyond Apple's own entry, so the
    /// `/Library` file can be removed without changing the mode table.
    private static func isRedundant(_ payload: [String: Any], for edid: EDID) -> Bool {
        let current = normalized(payload)
        if let system = systemPayload(for: edid) {
            return NSDictionary(dictionary: current).isEqual(to: normalized(system))
        }
        return current.isEmpty
    }

    private static func normalized(_ payload: [String: Any]) -> [String: Any] {
        var copy = payload
        copy.removeValue(forKey: "DisplayVendorID")
        copy.removeValue(forKey: "DisplayProductID")
        return copy
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
    static func runAsAdministrator(_ command: String) throws {
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
