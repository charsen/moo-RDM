import CoreGraphics
import Foundation

/// Command-line interface.
///
/// Flag names stay close to the original RDM so muscle memory carries over
/// (`-w`, `-h`, `-s`, `-d`, `-lm`, `-ld`), with additions for rotation and JSON
/// output.
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

        /// EDID dump and the derived bandwidth/refresh ceilings.
        var showEDID = false
        var showCapabilities = false
        /// Why a rate is or is not reachable, layer by layer.
        var refreshAudit = false
        /// "3840x2160@75" — a rate that has to be synthesised, not selected.
        var customTiming: String?
        var writeOverride = false
        var keepOverride = false
        var revertOverride = false
        var sleepWake = false
        var overrideTimeout: Double = 20
        /// Where to dump the patched EDID, for inspection with an EDID editor.
        var emitPath: String?

        var includeUnusable = true
        var hiDPIOnly = false
        var json = false
        var permanent = false

        var showHelp = false
        var showVersion = false
        var selfTestTiming = false

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
        if options.selfTestTiming {
            return TimingSelfTest.run(displayIndex: options.displayIndex)
        }
        if options.listDisplays {
            return listDisplays(options)
        }
        if options.listModes {
            return listModes(options)
        }
        if options.showEDID {
            return dumpEDID(options)
        }
        if options.showCapabilities {
            return showCapabilities(options)
        }
        if options.refreshAudit {
            return runRefreshAudit(options)
        }
        if options.customTiming != nil || options.revertOverride {
            return customTiming(options)
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

            case "--edid":
                options.showEDID = true
            case "--capabilities":
                options.showCapabilities = true
            case "--refresh-audit":
                options.refreshAudit = true
            case "--custom-timing":
                options.customTiming = try value(argument)
            case "--write":
                options.writeOverride = true
            case "--keep":
                options.keepOverride = true
            case "--revert":
                options.revertOverride = true
            case "--sleep-wake":
                options.sleepWake = true
            case "--emit-edid":
                options.emitPath = try value(argument)
            case "--timeout":
                options.overrideTimeout = try doubleValue(argument)
            case "--selftest-timing":
                options.selfTestTiming = true

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

    // MARK: - EDID and hardware limits

    private static func dumpEDID(_ options: Options) -> Int32 {
        guard let display = resolveTarget(options) else { return 1 }
        guard let edid = DisplayEDIDReader.read(for: display.id) else {
            writeError(L10n.t("error.timingNoEDID"))
            return 1
        }
        let attributes = DisplayLinkInfo.attributes(vendor: edid.vendor,
                                                    product: edid.product,
                                                    serial: edid.serial)

        print("Display \(display.ordinal): \(display.name)")
        print(String(format: "    vendor      %@ (0x%04X)", edid.manufacturerCode, edid.vendor))
        print(String(format: "    product     0x%04X", edid.product)
              + (edid.productName.map { " (\($0))" } ?? ""))
        print("    serial      \(edid.serial)")
        print("    blocks      \(edid.blockCount), checksums "
              + (edid.hasValidChecksums ? "valid" : "INVALID"))
        if let rate = DisplayLinkInfo.maxPixelRate(productName: edid.productName) {
            print(String(format: "    link        %.0f MHz max pixel rate", Double(rate) / 1_000_000))
        }
        if let low = (attributes?["MinimumRefreshRate"] as? NSNumber)?.doubleValue,
           let high = (attributes?["MaximumRefreshRate"] as? NSNumber)?.doubleValue {
            print(String(format: "    range       %.0f–%.0f Hz (vendor reference)", low, high))
        }
        if let width = (attributes?["NativeFormatHorizontalPixels"] as? NSNumber)?.intValue,
           let height = (attributes?["NativeFormatVerticalPixels"] as? NSNumber)?.intValue {
            print("    native      \(width) × \(height)")
        } else if let native = edid.preferredTiming {
            print("    native      \(native.width) × \(native.height)")
        }

        print("    detailed timings")
        for timing in edid.detailedTimings {
            print("      \(timing.description)")
        }

        let shortFormats = edid.declaredRates.filter { $0.source == .ceaShortFormat }
        if !shortFormats.isEmpty {
            var seen: Set<String> = []
            let unique = shortFormats.filter {
                seen.insert($0.description).inserted
            }
            print("    CEA short formats (\(unique.count))")
            for format in unique.prefix(16) {
                print("      \(format.description)")
            }
            if unique.count > 16 { print("      … \(unique.count - 16) more") }
        }

        if DisplayOverrideInstaller.hasOverride(for: edid) {
            print("    override    installed (\(DisplayOverrideInstaller.target(for: edid).path))")
        }
        return 0
    }

    private static func showCapabilities(_ options: Options) -> Int32 {
        guard let display = resolveTarget(options) else { return 1 }
        let report = DisplayCapabilities.report(for: display.id)
        guard let edid = report.edid else {
            writeError(L10n.t("error.timingNoEDID"))
            return 1
        }

        print("Display \(display.ordinal): \(display.name)")
        if let timing = report.nativeTiming {
            print("    native timing  \(timing.description)")
        }
        print("    budget         \(budgetLine(report))")

        if let native = report.nativeFormat
            ?? report.nativeTiming.map({ PixelSize(width: $0.width, height: $0.height) }),
           let ceiling = report.estimatedMaximumRefresh(width: native.width, height: native.height) {
            print(String(format: "    at %d × %d      up to %.0f Hz by budget",
                         native.width, native.height, ceiling))
        }

        if report.hiddenRates.isEmpty {
            print("    hidden rates   none — every declared rate has a mode")
        } else {
            print("    hidden rates   declared by EDID, not offered by macOS")
            for rate in report.hiddenRates {
                print("      \(rate.description)  [\(rate.source.rawValue)]")
            }
        }

        if DisplayOverrideInstaller.hasOverride(for: edid) {
            print("    override       installed")
            print("                   remove with --revert -d \(display.ordinal)")
        } else if DisplayOverrideInstaller.support.isAvailable {
            print("    beyond         rdm-arm --custom-timing <w>x<h>@<hz> --write -d \(display.ordinal)")
        } else {
            // Recommending a command that is known to be a no-op here would be
            // the same dishonesty as reporting success for it.
            print("    beyond         timing computed, but a display override is ignored on Apple silicon")
        }
        return 0
    }

    // MARK: - Refresh audit

    /// `--refresh-audit`: why the target rate is or is not reachable.
    ///
    /// Gives the narrowest explanation that fits, because the three causes have
    /// nothing in common: macOS hides a mode the panel declared, the panel never
    /// declared the rate but the link has room, or the link cannot carry it. Only
    /// the first two are software problems, and only the first is free.
    private static func runRefreshAudit(_ options: Options) -> Int32 {
        // The audit ends by recommending a `--custom-timing` command, and that
        // command accepts only (1, 1000]. Screening here keeps the advice honest:
        // `-r 0` used to produce "try --custom-timing 3840x2160@0", a command
        // whose own parser rejects it — advice that cannot be followed.
        if let requested = options.refresh, requested <= 1 || requested > 1000 {
            writeError(L10n.t("error.refreshOutOfRange"))
            return 2
        }

        guard let display = resolveTarget(options) else { return 1 }
        let report = DisplayCapabilities.report(for: display.id)
        guard report.edid != nil else {
            writeError(L10n.t("error.timingNoEDID"))
            return 1
        }

        let audit = report.audit(target: options.refresh)
        let target = audit.target

        print("Display \(display.ordinal): \(display.name)")
        if options.refresh == nil {
            print("    target         \(rateText(target)) Hz — highest rate the panel declares")
        } else {
            print("    target         \(rateText(target)) Hz — as requested")
        }
        print("    budget         \(budgetLine(report))")
        if let mode = display.currentMode {
            print("    current        \(mode.detailedTitle)  ·  \(mode.pixelDescription) px")
        }

        guard !audit.geometries.isEmpty else {
            print("    geometry       nothing readable — no modes and no EDID timings")
            return 1
        }

        print("")
        print("    geometry      offered / declared / ceiling")
        // Rows are not in size order, and a reader who is not told why will read
        // 720 × 480 appearing above 3360 × 1890 as a bug. It is the panel's own
        // descriptor outranking a scaling factor.
        print("    order         native → EDID-declared → area, largest first")

        // Eight rows land exactly at the end of the declared group plus the two
        // largest scaled geometries on a 4K panel. Going further only admits 4:3
        // and portrait modes (2688 × 2016, 1920 × 2160) that nobody audits for
        // refresh rate — measured, not guessed.
        let visibleGeometries = 8
        for geometry in audit.geometries.prefix(visibleGeometries) {
            let verdict = geometry.verdict(for: target)
            var parts: [String] = []
            parts.append("offered " + rateList(geometry.offeredRates))
            parts.append("declared " + rateList(geometry.declaredRates))
            if let ceiling = geometry.ceiling {
                parts.append("ceiling \(rateText(ceiling.rounded())) Hz")
            }
            parts.append("→ \(rateText(target)) Hz \(verdictLabel(verdict))")
            print("    \(pad(geometry.pixelDescription, 13)) " + parts.joined(separator: " · "))

            // The trap behind "I picked 1080p and it is still 30 Hz": every HiDPI
            // point size is rendered then scaled down to the same output timing,
            // so the bandwidth and the refresh rate do not change with it.
            let scaled = geometry.pointSizes.filter { $0.scale > 1.01 }
            if let largest = scaled.first, let smallest = scaled.last {
                if scaled.count > 1 {
                    print("      HiDPI   \(smallest.width) × \(smallest.height) … "
                          + "\(largest.width) × \(largest.height) "
                          + "(\(scaled.count) point sizes) — all drive this timing")
                } else {
                    print("      HiDPI   \(largest.width) × \(largest.height) points"
                          + " — drives this timing")
                }
            }
        }
        if audit.geometries.count > visibleGeometries {
            print("      … \(audit.geometries.count - visibleGeometries) more geometries")
        }

        print("")
        if let best = audit.largestReachingTarget {
            switch best.verdict(for: target) {
            case .offered:
                print("    verdict        available now at \(best.pixelDescription)")
            case .hidden:
                print("    verdict        the panel declares it, macOS does not list it")
                if let point = best.pointSizes.first {
                    // `-d` matters as soon as a second display exists: without it
                    // the command silently targets the main display instead of the
                    // one just audited.
                    print("                   rdm-arm -w \(point.width) -h \(point.height)"
                          + " -r \(rateText(target)) -d \(display.ordinal)")
                }
            case .synthesizable:
                print("    verdict        within the link budget at \(best.pixelDescription),"
                      + " but the panel never declared it")
                print("                   rdm-arm --custom-timing "
                      + "\(best.width)x\(best.height)@\(rateText(target)) -d \(display.ordinal)")
                if !DisplayOverrideInstaller.support.isAvailable {
                    print("                   (computes only — Apple silicon ignores the override)")
                }
            case .beyondLink, .unknown:
                break
            }

            // The largest geometry that reaches the rate is not necessarily the
            // one that can be had right now. 75 Hz may need a synthesised timing
            // at 1920 × 1080 while 640 × 480 already lists it; naming only the
            // harder route would walk the reader through an administrator
            // password for something one menu click away.
            if let ready = audit.offeredAtAnyGeometry,
               ready.width != best.width || ready.height != best.height {
                print("                   already offered at \(ready.pixelDescription)")
            }
        } else {
            print("    verdict        no geometry reaches \(rateText(target)) Hz — the link tops out below it")
            // The native timing is not necessarily the cheapest one, so the
            // fallback names whichever geometry actually gets closest.
            let ceilings = audit.geometries.compactMap { geometry in
                geometry.ceiling.map { (geometry: geometry, ceiling: $0) }
            }
            if let best = ceilings.max(by: { $0.ceiling < $1.ceiling }) {
                print("                   best case \(best.geometry.pixelDescription) at about "
                      + "\(rateText(best.ceiling.rounded())) Hz")
            }
        }
        return 0
    }

    /// The same figures as `Report.budgetDescription`, in the CLI's language.
    ///
    /// The menu needs the localised version, but a diagnostic table that switches
    /// from English labels to a Chinese value on the next column is a reading
    /// problem, and this is the only place that hit it.
    private static func budgetLine(_ report: DisplayCapabilities.Report) -> String {
        var parts: [String] = []
        if let rate = report.linkMaxPixelRate {
            parts.append(String(format: "link %.0f MHz", Double(rate) / 1_000_000))
        }
        if let low = report.minRefreshRate, let high = report.maxRefreshRate {
            parts.append(String(format: "vendor range %.0f–%.0f Hz", low, high))
        } else if let high = report.maxRefreshRate {
            parts.append(String(format: "vendor max %.0f Hz", high))
        }
        return parts.isEmpty ? "unreadable — optional module off" : parts.joined(separator: " · ")
    }

    /// "60" for whole rates, "59.94" otherwise. A report full of 59.940000 is
    /// harder to read than the number it is trying to convey.
    private static func rateText(_ rate: Double) -> String {
        abs(rate - rate.rounded()) < 0.02
            ? String(Int(rate.rounded()))
            : String(format: "%.2f", rate)
    }

    private static func rateList(_ rates: [Double]) -> String {
        guard !rates.isEmpty else { return "—" }
        let text = rates.prefix(8).map(rateText).joined(separator: " ")
        return rates.count > 8 ? text + " …" : text
    }

    private static func verdictLabel(_ verdict: DisplayCapabilities.RefreshAudit.Verdict) -> String {
        switch verdict {
        case .offered:       return "offered"
        case .hidden:        return "hidden by macOS"
        case .synthesizable: return "not declared"
        case .beyondLink:    return "beyond link"
        case .unknown:       return "unknown"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Custom timing

    /// "3840x2160@75" → geometry plus a refresh rate that has to be synthesised.
    private struct TimingSpec {
        let width: Int
        let height: Int
        let refresh: Double

        init?(_ text: String) {
            let halves = text.lowercased().split(separator: "@")
            guard halves.count == 2 else { return nil }
            let size = halves[0].split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
            guard size.count == 2,
                  let width = Int(size[0]), let height = Int(size[1]),
                  let refresh = Double(halves[1]),
                  width > 0, height > 0, refresh > 1, refresh <= 1000 else { return nil }
            self.width = width
            self.height = height
            self.refresh = refresh
        }
    }

    private static func customTiming(_ options: Options) -> Int32 {
        guard let display = resolveTarget(options) else { return 1 }

        if options.revertOverride {
            do {
                try CustomTimingEngine.revert(for: display.id)
                print(L10n.t("cli.timingReverted", display.name))
                return 0
            } catch {
                writeError("\(error)")
                return 1
            }
        }

        guard let raw = options.customTiming, let spec = TimingSpec(raw) else {
            writeError(L10n.t("error.timingSyntax"))
            return 2
        }

        let proposal: CustomTimingEngine.Proposal
        switch CustomTimingEngine.propose(width: spec.width, height: spec.height,
                                          refresh: spec.refresh, for: display.id) {
        case .success(let value): proposal = value
        case .failure(let error):
            writeError(error.description)
            return 1
        }

        print("Display \(display.ordinal): \(display.name)")
        print(String(format: "    requested      %d × %d @ %.3f Hz",
                     proposal.width, proposal.height, proposal.requestedRefresh))
        print(String(format: "    encoded        %d × %d @ %.3f Hz  (%.2f MHz, totals %d × %d)",
                     proposal.timing.width, proposal.timing.height, proposal.encodedRefresh,
                     proposal.pixelRateMHz, proposal.timing.hTotal, proposal.timing.vTotal))
        if abs(proposal.quantisationError) > 0.01 {
            print(String(format: "    quantisation   %+.3f Hz from the 10 kHz pixel-clock grid",
                         proposal.quantisationError))
        }
        if let ceiling = proposal.estimatedMaximumRefresh {
            print(String(format: "    ceiling        %.0f Hz by link and vendor range",
                         ceiling))
        }
        if proposal.isSyntheticGeometry {
            print("    note           no descriptor at this geometry — blanking scaled from native")
        }

        if let path = options.emitPath {
            do {
                try proposal.edid.data.write(to: URL(fileURLWithPath: path))
                print("    emitted        \(path) (\(proposal.edid.data.count) bytes, "
                      + "checksums \(proposal.edid.hasValidChecksums ? "valid" : "INVALID"))")
            } catch {
                writeError("\(error)")
                return 1
            }
        }

        // The timing can be computed everywhere; handing it to the system cannot.
        // Saying so here costs nothing and saves an administrator prompt that is
        // guaranteed to end in "mode list unchanged".
        if options.writeOverride, !DisplayOverrideInstaller.support.isAvailable {
            writeError(L10n.t("error.overrideInert"))
            return 3
        }

        guard options.writeOverride else {
            print(L10n.t(DisplayOverrideInstaller.support.isAvailable
                         ? "cli.timingDryRun"
                         : "cli.timingDryRunInert"))
            return 0
        }

        print("    override       \(DisplayOverrideInstaller.target(for: proposal.edid).path)")

        let observedChange: Bool
        do {
            observedChange = try CustomTimingEngine.install(proposal, for: display.id)
        } catch {
            writeError("\(error)")
            return 1
        }

        if observedChange {
            print("    reprobe        mode list changed — the timing was accepted for enumeration")
        } else {
            print("    reprobe        mode list unchanged")
            if options.sleepWake {
                print("    sleep/wake     cycling display power to force re-enumeration")
                sleepWakeCycle()
                print("    sleep/wake     done — check the display")
            } else {
                print("    next           re-plug the display, or re-run with --sleep-wake")
            }
        }

        if options.keepOverride {
            print(L10n.t("cli.timingKept"))
            return 0
        }

        // Anything that can black the screen has to undo itself. The user keeps
        // the override by re-running with --keep, which means the *absence* of a
        // decision always lands on the safe side.
        let seconds = max(3, options.overrideTimeout)
        print(L10n.t("cli.timingWatchdog", Int32(seconds.rounded())))
        Thread.sleep(forTimeInterval: seconds)

        do {
            try CustomTimingEngine.revert(for: display.id)
            print(L10n.t("cli.timingReverted", display.name))
        } catch {
            writeError("\(error)")
            return 1
        }
        return 0
    }

    private static func sleepWakeCycle() {
        func run(_ path: String, _ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            try? process.run()
            process.waitUntilExit()
        }
        run("/usr/bin/pmset", ["displaysleepnow"])
        Thread.sleep(forTimeInterval: 2)
        run("/usr/bin/caffeinate", ["-u", "-t", "2"])
        Thread.sleep(forTimeInterval: 3)
    }

    /// Wraps `targetDisplay` so every new subcommand reports the same way.
    private static func resolveTarget(_ options: Options) -> DisplayInfo? {
        do {
            return try targetDisplay(options)
        } catch let error as ParseError {
            writeError(error.message)
            return nil
        } catch {
            writeError("\(error)")
            return nil
        }
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
