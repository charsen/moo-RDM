import CoreGraphics
import Foundation

/// Command-line interface.
///
/// Flag names stay close to the original RDM so muscle memory carries over
/// (`-w`, `-h`, `-s`, `-d`, `-lm`, `-ld`), with additions for rotation, JSON
/// output and profiles.
public enum CommandLineRunner {

    // MARK: - Options

    private struct Options {
        var width: Int?
        var height: Int?
        var scale: Double?
        var refresh: Double?
        var rotation: Double?
        var displayIndex = 0

        var listDisplays = false
        var listModes = false
        var listProfiles = false

        var includeUnusable = true
        var hiDPIOnly = false
        var json = false
        var permanent = false

        var saveProfile: String?
        var applyProfile: String?

        var showHelp = false
        var showVersion = false

        /// True when the user asked us to actually change something.
        var wantsChange: Bool {
            width != nil || height != nil || scale != nil
                || refresh != nil || rotation != nil
        }
    }

    private struct ParseError: Error {
        let message: String
    }

    // MARK: - Entry point

    public static func run(arguments: [String]) -> Int32 {
        var options = Options()
        do {
            try parse(arguments, into: &options)
        } catch let error as ParseError {
            writeError(error.message)
            writeError("")
            writeError(L10n.t("cli.usage"))
            return 2
        } catch {
            writeError("\(error)")
            return 2
        }

        if options.showHelp {
            print(L10n.t("cli.usage"))
            return 0
        }
        if options.showVersion {
            print(AppInfo.versionDescription)
            return 0
        }
        if options.listDisplays {
            return listDisplays(options)
        }
        if options.listModes {
            return listModes(options)
        }
        if options.listProfiles {
            return listProfiles(options)
        }
        if let name = options.saveProfile {
            return saveProfile(named: name, options: options)
        }
        if let name = options.applyProfile {
            return applyProfile(named: name, options: options)
        }
        if options.wantsChange {
            return changeMode(options)
        }

        print(L10n.t("cli.usage"))
        return 0
    }

    // MARK: - Parsing

    private static func parse(_ arguments: [String], into options: inout Options) throws {
        var index = 0

        /// Consumes the value that follows a flag.
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw ParseError(message: "missing value for \(flag)")
            }
            return arguments[index]
        }

        func intValue(_ flag: String) throws -> Int {
            let raw = try value(flag)
            guard let parsed = Int(raw) else {
                throw ParseError(message: "\(flag) expects an integer, got “\(raw)”")
            }
            return parsed
        }

        func doubleValue(_ flag: String) throws -> Double {
            let raw = try value(flag)
            guard let parsed = Double(raw) else {
                throw ParseError(message: "\(flag) expects a number, got “\(raw)”")
            }
            return parsed
        }

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            // Long forms
            case "--help":
                options.showHelp = true
            case "-v", "--version":
                options.showVersion = true
            case "-ld", "--displays":
                options.listDisplays = true
            case "-lm", "--modes":
                options.listModes = true
            case "--list-profiles":
                options.listProfiles = true
            case "--all":
                options.includeUnusable = true
            case "--usable-only":
                options.includeUnusable = false
            case "--hidpi":
                options.hiDPIOnly = true
            case "--json":
                options.json = true
            case "--permanent":
                options.permanent = true

            case "-w", "--width":
                options.width = try intValue(argument)
            case "-h":
                // `-h` is overloaded: the original RDM used it for height, but
                // everyone also expects it to mean help. Treat a bare `-h` (no
                // numeric value following) as a help request instead of an error.
                if index + 1 < arguments.count, Int(arguments[index + 1]) != nil {
                    options.height = try intValue(argument)
                } else {
                    options.showHelp = true
                }
            case "--height":
                options.height = try intValue(argument)
            case "-s", "--scale":
                options.scale = try doubleValue(argument)
            case "-r", "--refresh":
                options.refresh = try doubleValue(argument)
            case "-d", "--display":
                options.displayIndex = try intValue(argument)
            case "--rotation":
                options.rotation = try doubleValue(argument)
            case "--save":
                options.saveProfile = try value(argument)
            case "--apply":
                options.applyProfile = try value(argument)

            default:
                // Support the original's bundled short form, e.g. "-w1920".
                if argument.hasPrefix("-w"), let parsed = Int(argument.dropFirst(2)) {
                    options.width = parsed
                } else if argument.hasPrefix("-h"), let parsed = Int(argument.dropFirst(2)) {
                    options.height = parsed
                } else if argument.hasPrefix("-s"), let parsed = Double(argument.dropFirst(2)) {
                    options.scale = parsed
                } else if argument.hasPrefix("-d"), let parsed = Int(argument.dropFirst(2)) {
                    options.displayIndex = parsed
                } else {
                    throw ParseError(message: "unknown option “\(argument)”")
                }
            }
            index += 1
        }
    }

    // MARK: - Resolving the target display

    private static func targetDisplay(_ options: Options) throws -> DisplayInfo {
        let displays = DisplayManager.allDisplays()
        guard !displays.isEmpty else {
            throw ParseError(message: L10n.t("menu.noDisplays"))
        }
        guard options.displayIndex >= 0, options.displayIndex < displays.count else {
            throw ParseError(message: L10n.t("error.noSuchDisplay", Int32(options.displayIndex)))
        }
        return displays[options.displayIndex]
    }

    // MARK: - Actions

    private static func listDisplays(_ options: Options) -> Int32 {
        let displays = DisplayManager.allDisplays()

        if options.json {
            printJSON(RootDTO(version: AppInfo.version,
                              architecture: AppInfo.architecture,
                              displays: displays.map { dto($0, includeModes: false, options: options) }))
            return 0
        }

        guard !displays.isEmpty else {
            print(L10n.t("menu.noDisplays"))
            return 0
        }

        for display in displays {
            var tags: [String] = []
            if display.isBuiltin { tags.append("builtin") }
            if display.isMain { tags.append("main") }
            if !display.isActive { tags.append("inactive") }
            if display.isMirrored { tags.append("mirrored") }
            let tagText = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"

            print("Display \(display.ordinal): \(display.name)\(tagText)")
            print("    id          \(display.id)")
            print("    identity    \(display.identity.key)")
            print("    current     \(display.currentDescription)")
            if let native = display.nativePixelSize {
                print("    native      \(native.description)")
            }
            let modes = DisplayManager.allModes(for: display.id)
            print("    modes       \(modes.count) total, "
                  + "\(modes.filter(\.isUsable).count) usable, "
                  + "\(modes.filter(\.isHiDPI).count) HiDPI")
        }
        return 0
    }

    private static func listModes(_ options: Options) -> Int32 {
        let displays = DisplayManager.allDisplays()
        guard !displays.isEmpty else {
            print(L10n.t("menu.noDisplays"))
            return 0
        }

        if options.json {
            printJSON(RootDTO(version: AppInfo.version,
                              architecture: AppInfo.architecture,
                              displays: displays.map { dto($0, includeModes: true, options: options) }))
            return 0
        }

        for display in displays {
            var modes = DisplayManager.allModes(for: display.id,
                                                includeUnusable: options.includeUnusable)
            if options.hiDPIOnly { modes = modes.filter(\.isHiDPI) }
            if let width = options.width { modes = modes.filter { $0.width == width } }
            if let height = options.height { modes = modes.filter { $0.height == height } }
            if let scale = options.scale { modes = modes.filter { abs($0.scale - scale) < 0.01 } }

            print("Display \(display.ordinal): \(display.name) — \(modes.count) mode(s)")
            for mode in modes.sortedForMenu() {
                let marker = mode.isHiDPI ? "⚡️" : "  "
                let usable = mode.isUsable ? "usable" : "hidden"
                print(String(format: "  %@ %-14@ %6.0f Hz  %@  id=%d",
                             marker,
                             mode.pointDescription as NSString,
                             mode.refreshRate,
                             usable as NSString,
                             mode.modeID))
            }
        }
        return 0
    }

    private static func listProfiles(_ options: Options) -> Int32 {
        let profiles = ProfileStore.shared.profiles
        guard !profiles.isEmpty else {
            print(L10n.t("menu.noProfiles"))
            return 0
        }
        for profile in profiles {
            print("\(profile.name)")
            for target in profile.targets {
                print("    \(target.displayName): \(target.resolutionDescription)")
            }
        }
        return 0
    }

    private static func saveProfile(named name: String, options: Options) -> Int32 {
        let profile = ProfileStore.shared.captureCurrentLayout(named: name)
        ProfileStore.shared.upsert(profile)
        print("saved profile “\(name)” with \(profile.targets.count) display(s)")
        return 0
    }

    private static func applyProfile(named name: String, options: Options) -> Int32 {
        guard let profile = ProfileStore.shared.profile(named: name) else {
            writeError("no profile named “\(name)”")
            return 1
        }
        let report = ProfileStore.shared.apply(profile, permanently: options.permanent)
        for line in report.applied { print("applied  \(line)") }
        for line in report.warnings { writeError("warning  \(line)") }
        return report.applied.isEmpty ? 1 : 0
    }

    private static func changeMode(_ options: Options) -> Int32 {
        let display: DisplayInfo
        do {
            display = try targetDisplay(options)
        } catch let error as ParseError {
            writeError(error.message)
            return 1
        } catch {
            writeError("\(error)")
            return 1
        }

        var exitCode: Int32 = 0

        // Resolution first, so a rotation request lands on the final geometry.
        if options.width != nil || options.height != nil || options.scale != nil || options.refresh != nil {
            let result = ModeController.applyResolution(on: display.id,
                                                        width: options.width,
                                                        height: options.height,
                                                        scale: options.scale,
                                                        refreshRate: options.refresh,
                                                        permanently: options.permanent,
                                                        includeUnusable: options.includeUnusable,
                                                        hiDPIOnly: options.hiDPIOnly)
            switch result {
            case .success(let mode):
                print("\(display.name): now \(mode.pointDescription)\(mode.isHiDPI ? " ⚡️" : "")"
                      + (mode.refreshRate > 0 ? String(format: " @ %.0f Hz", mode.refreshRate) : ""))
                print("    pixels \(mode.pixelDescription), scale \(String(format: "%.2f", mode.scale))")
            case .failure(let error):
                writeError(error.description)
                exitCode = 1
            }
        }

        if let rotation = options.rotation {
            if !DisplayRotationController.isAvailable {
                writeError(L10n.t("error.rotationUnsupported"))
                exitCode = 1
            } else {
                switch DisplayRotationController.setRotation(rotation, on: display.id) {
                case .success:
                    print("\(display.name): rotated to \(Int(rotation))°")
                case .failure(let error):
                    writeError(error.description)
                    exitCode = 1
                }
            }
        }

        return exitCode
    }

    // MARK: - JSON

    private struct ModeDTO: Codable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double
        let hiDPI: Bool
        let refreshRate: Double
        let usable: Bool
        let modeID: Int32
        let flags: [String]
    }

    private struct DisplayDTO: Codable {
        let index: Int
        let id: UInt32
        let name: String
        let builtin: Bool
        let main: Bool
        let active: Bool
        let mirrored: Bool
        let identity: String
        let rotation: Double
        let current: ModeDTO?
        let native: String?
        let modeCount: Int
        let usableModeCount: Int
        let hiDPIModeCount: Int
        let modes: [ModeDTO]?
    }

    private struct RootDTO: Codable {
        let version: String
        let architecture: String
        let displays: [DisplayDTO]
    }

    private static func modeDTO(_ mode: DisplayMode) -> ModeDTO {
        ModeDTO(width: mode.width, height: mode.height,
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                scale: mode.scale, hiDPI: mode.isHiDPI,
                refreshRate: mode.refreshRate, usable: mode.isUsable,
                modeID: mode.modeID, flags: mode.flags.names)
    }

    private static func dto(_ display: DisplayInfo, includeModes: Bool, options: Options) -> DisplayDTO {
        var modes: [DisplayMode] = []
        if includeModes {
            modes = DisplayManager.allModes(for: display.id,
                                            includeUnusable: options.includeUnusable)
            if options.hiDPIOnly { modes = modes.filter(\.isHiDPI) }
        }
        let all = DisplayManager.allModes(for: display.id)
        return DisplayDTO(
            index: display.ordinal,
            id: display.id,
            name: display.name,
            builtin: display.isBuiltin,
            main: display.isMain,
            active: display.isActive,
            mirrored: display.isMirrored,
            identity: display.identity.key,
            rotation: display.rotation,
            current: display.currentMode.map(modeDTO),
            native: display.nativePixelSize?.description,
            modeCount: all.count,
            usableModeCount: all.filter(\.isUsable).count,
            hiDPIModeCount: all.filter(\.isHiDPI).count,
            modes: includeModes ? modes.sortedForMenu().map(modeDTO) : nil
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    // MARK: - Output helpers

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
