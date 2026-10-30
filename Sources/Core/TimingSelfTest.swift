import CoreGraphics
import Foundation

/// Pure-logic checks for the EDID and timing code, run with `--selftest-timing`.
///
/// Nothing here touches the system: no override is written, no mode is changed.
/// The point is to pin the parts that are easy to get subtly wrong — descriptor
/// field packing, checksum repair, and the promise that re-clocking changes the
/// pixel clock and *nothing else*.
///
/// The suite is in two halves on purpose:
///
/// - **Synthetic** runs everywhere, including a headless CI runner with no
///   display attached. It builds a stand-in panel and pushes it through the real
///   `audit()` assembly, so the verdict logic cannot rot between releases just
///   because nobody happened to open a terminal and run this by hand.
/// - **Real panel** runs only when one is attached, and reports `SKIP` otherwise.
///   A missing display is a legitimate environment, not a defect — but a display
///   that is present and unreadable still fails, because that would mean the IOKit
///   path broke.
enum TimingSelfTest {

    // MARK: - Entry point

    static func run(displayIndex: Int = 0) -> Int32 {
        var checks = Checks()

        syntheticChecks(&checks)
        realPanelChecks(&checks, displayIndex: displayIndex)

        print(checks.failures == 0
              ? "\nall checks passed"
              : "\n\(checks.failures) check(s) failed")
        return checks.failures == 0 ? 0 : 1
    }

    /// Accumulates failures so one wrong answer does not hide the next.
    private struct Checks {
        var failures = 0

        mutating func check(_ condition: Bool, _ label: String,
                            _ detail: @autoclosure () -> String = "") {
            if condition {
                print("PASS  \(label)")
            } else {
                failures += 1
                let extra = detail()
                print("FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }
    }

    // MARK: - Synthetic

    /// The 18-byte descriptor documented in `DetailedTiming`'s header comment.
    ///
    /// Taken from a real panel (BenQ PD2705U: 3840 × 2160, 533.25 MHz,
    /// 4000 × 2222 totals) rather than encoded here by hand. A fixture built with
    /// the same code it is meant to test can be wrong in a way that cancels out;
    /// a byte string lifted from hardware cannot.
    static let fixtureDescriptor: [UInt8] = [
        0x4D, 0xD0, 0x00, 0xA0, 0xF0, 0x70, 0x3E, 0x80, 0x30,
        0x20, 0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1A,
    ]

    /// A stand-in panel: 4K60 preferred, plus 1920 × 1080 @ 75 as a second timing.
    ///
    /// This is not a real blob. Header, descriptor, name and checksum are
    /// genuine; chromaticity, established and standard timings are left at zero
    /// because nothing in this project reads them, and filling them in would only
    /// suggest they had been verified.
    static func fixtureEDID() -> EDID? {
        guard let preferred = DetailedTiming(raw: fixtureDescriptor) else { return nil }

        var bytes = [UInt8](repeating: 0, count: EDID.blockSize)
        for index in 1...6 { bytes[index] = 0xFF }   // header magic, byte 0 already 0
        // Manufacturer "TST", product 0x1234, week 0, year 2020.
        bytes[8] = 0x52
        bytes[9] = 0x74
        bytes[10] = 0x34
        bytes[11] = 0x12
        bytes[17] = 30
        // EDID 1.3, digital input, 52 × 29 cm, gamma 2.2, sRGB-ish feature bits.
        bytes[18] = 1
        bytes[19] = 3
        bytes[20] = 0x80
        bytes[21] = 0x34
        bytes[22] = 0x1D
        bytes[23] = 0x78
        bytes[24] = 0x0F
        // Standard timings: 0x01 0x01 means "unused".
        for index in stride(from: 38, to: 54, by: 2) { bytes[index] = 0x01 }

        bytes.replaceSubrange(54..<72, with: preferred.raw)
        bytes[93] = 0xFC                                 // 0xFC = product name
        let name = Array("FIXTURE".utf8)
        bytes.replaceSubrange(95..<(95 + name.count), with: name)
        bytes[95 + name.count] = 0x0A
        bytes[127] = EDID.checksum(of: bytes, block: 0)

        // `adding` writes to the first blank slot, which is offset 108 here — so
        // the preferred descriptor stays where it is and 1080p becomes a
        // non-preferred timing the way a real panel would carry it.
        guard let base = EDID(bytes: bytes),
              let extra = preferred.scaled(toWidth: 1920, toHeight: 1080, refresh: 75)
        else { return nil }
        return base.adding(extra)
    }

    /// A mode list shaped like a real 4K panel's: the native timing, one HiDPI
    /// point size that drives it, and a plain 1080p mode.
    static func fixtureReport(_ edid: EDID) -> DisplayCapabilities.Report {
        let modes = [
            DisplayMode(displayID: 1, privateModeID: 11, width: 3840, height: 2160,
                        scale: 1, refreshRate: 60, ioFlags: 0),
            DisplayMode(displayID: 1, privateModeID: 12, width: 1920, height: 1080,
                        scale: 2, refreshRate: 60, ioFlags: 0),
            DisplayMode(displayID: 1, privateModeID: 13, width: 1920, height: 1080,
                        scale: 1, refreshRate: 60, ioFlags: 0),
        ]
        return DisplayCapabilities.Report(
            displayID: 1,
            edid: edid,
            nativeTiming: edid.preferredTiming,
            hiddenRates: [],
            linkMaxPixelRate: 594_000_000,
            maxRefreshRate: 76,
            minRefreshRate: 50,
            nativeFormat: PixelSize(width: 3840, height: 2160),
            offeredModes: modes)
    }

    private static func syntheticChecks(_ checks: inout Checks) {
        guard let edid = fixtureEDID(), let preferred = edid.preferredTiming else {
            checks.check(false, "fixture EDID builds")
            return
        }
        print("FIXTURE  \(edid.manufacturerCode) 0x\(String(format: "%04X", edid.product))"
              + "  \(edid.productName ?? "unnamed")  blocks=\(edid.blockCount)")

        // 1. The preferred descriptor must decode to something a panel could use.
        checks.check(preferred.width > 0 && preferred.height > 0, "preferred timing decodes",
                     preferred.description)
        checks.check(preferred.refreshRate > 20 && preferred.refreshRate < 300,
                     "preferred refresh is plausible",
                     String(format: "%.3f Hz", preferred.refreshRate))
        checks.check(preferred.hTotal > preferred.hActive && preferred.vTotal > preferred.vActive,
                     "blanking present", "totals \(preferred.hTotal) × \(preferred.vTotal)")

        // 2. Re-clocking must change bytes 0 and 1 only. Anything else and the
        //    descriptor's sync structure was silently rewritten.
        let target = min(preferred.refreshRate + 5, 200)
        if let retimed = preferred.retimed(toRefresh: target) {
            let changed = zip(preferred.raw, retimed.raw).enumerated()
                .filter { $0.element.0 != $0.element.1 }
                .map(\.offset)
            checks.check(changed == [0, 1], "re-clock touches only the pixel clock",
                         "changed offsets \(changed)")
            checks.check(abs(retimed.refreshRate - target) < 0.05,
                         "re-clocked rate is within 0.05 Hz of the request",
                         String(format: "asked %.3f, got %.3f", target, retimed.refreshRate))
            checks.check(retimed.hTotal == preferred.hTotal && retimed.vTotal == preferred.vTotal,
                         "re-clock keeps totals")

            // 3. Patching the EDID must keep the blob intact and the preferred
            //    timing untouched.
            let patched = edid.adding(retimed)
            checks.check(patched != nil, "EDID accepts an extra timing")
            if let patched {
                checks.check(patched.bytes.count == edid.bytes.count, "block count unchanged",
                             "\(patched.blockCount) of \(edid.blockCount)")
                checks.check(patched.hasValidChecksums, "patched checksums valid")
                checks.check(patched.preferredTiming == preferred, "preferred timing untouched")
                checks.check(patched.detailedTimings.contains { abs($0.refreshRate - target) < 0.05 },
                             "patched timing is enumerable")
                checks.check(patched.productName == edid.productName,
                             "product name survives the patch")
            }
        } else {
            checks.check(false, "re-clock produces a descriptor")
        }

        // 4. Scaling to a smaller geometry: blanking ratios carry over and the
        //    resulting timing is still structurally sane.
        if let synthetic = preferred.scaled(toWidth: preferred.width / 2,
                                            toHeight: preferred.height / 2,
                                            refresh: 60) {
            checks.check(synthetic.width == preferred.width / 2
                         && synthetic.height == preferred.height / 2,
                         "scaled geometry is exact")
            checks.check(synthetic.hBlank - synthetic.hFrontPorch - synthetic.hSyncWidth > 0,
                         "scaled horizontal blanking has a back porch",
                         "blank \(synthetic.hBlank), front \(synthetic.hFrontPorch), "
                         + "sync \(synthetic.hSyncWidth)")
            checks.check(synthetic.vBlank - synthetic.vFrontPorch - synthetic.vSyncWidth > 0,
                         "scaled vertical blanking has a back porch",
                         "blank \(synthetic.vBlank), front \(synthetic.vFrontPorch), "
                         + "sync \(synthetic.vSyncWidth)")
            checks.check(abs(synthetic.refreshRate - 60) < 0.05, "scaled rate is 60 Hz",
                         String(format: "%.3f Hz", synthetic.refreshRate))
        } else {
            checks.check(false, "scaling to half geometry succeeds")
        }

        // 5. `--refresh-audit` exists to distinguish four causes that have
        //    nothing in common. Each implies a different fix, so each verdict
        //    gets pinned here rather than trusted to read correctly in a table.
        func geometry(offered: [Double], declared: [Double],
                      ceiling: Double?) -> DisplayCapabilities.RefreshAudit.Geometry {
            DisplayCapabilities.RefreshAudit.Geometry(
                width: 3840, height: 2160, pointSizes: [],
                offeredRates: offered, declaredRates: declared, ceiling: ceiling)
        }
        checks.check(geometry(offered: [60, 50], declared: [60, 50], ceiling: 67).verdict(for: 60) == .offered,
                     "audit: a listed rate reads as offered")
        checks.check(geometry(offered: [30], declared: [60, 30], ceiling: 67).verdict(for: 60) == .hidden,
                     "audit: declared but unlisted reads as hidden")
        checks.check(geometry(offered: [], declared: [60], ceiling: 50).verdict(for: 60) == .beyondLink,
                     "audit: a declared rate beyond the link reads as beyond link")
        checks.check(geometry(offered: [], declared: [60], ceiling: 67).verdict(for: 60) == .hidden,
                     "audit: a whole missing geometry still reads as hidden")
        checks.check(geometry(offered: [30], declared: [30], ceiling: 67).verdict(for: 60) == .synthesizable,
                     "audit: budgeted but undeclared reads as synthesizable")
        checks.check(geometry(offered: [30], declared: [30], ceiling: 30).verdict(for: 60) == .beyondLink,
                     "audit: over-budget reads as beyond link")
        checks.check(geometry(offered: [30], declared: [30], ceiling: nil).verdict(for: 60) == .unknown,
                     "audit: a missing budget reads as unknown")
        // CoreGraphics rounds 59.94 to 60 in the mode list while the panel's
        // descriptor keeps 59.94. Without the 0.5 Hz tolerance every 1000/1001
        // rate would read as missing from a mode that is right there.
        checks.check(geometry(offered: [59.94], declared: [59.94], ceiling: 67).verdict(for: 60) == .offered,
                     "audit: 59.94 and 60 are one answer, not two")

        let mixed = DisplayCapabilities.RefreshAudit(
            target: 60,
            geometries: [geometry(offered: [30], declared: [30], ceiling: 30),
                         geometry(offered: [60], declared: [60], ceiling: 67)])
        checks.check(mixed.recommendedGeometry?.ceiling == 67,
                     "audit: the verdict skips geometries the link cannot carry")

        // 6. The largest geometry that reaches a rate and the largest geometry
        //    that already offers it are two different answers, and the CLI has to
        //    name both. Reporting only the first sends someone off to synthesise
        //    a timing at 1920 × 1080 when 640 × 480 has listed the rate all along.
        let ready = DisplayCapabilities.RefreshAudit.Geometry(
            width: 640, height: 480, pointSizes: [],
            offeredRates: [75, 60], declaredRates: [60], ceiling: 76)
        let twoWay = DisplayCapabilities.RefreshAudit(
            target: 75,
            geometries: [geometry(offered: [60], declared: [60], ceiling: 76), ready])
        checks.check(twoWay.recommendedGeometry?.width == 3840,
                     "audit: the largest reachable geometry decides the verdict")
        checks.check(twoWay.offeredAtAnyGeometry?.width == 640,
                     "audit: an already-listed smaller geometry is reported separately")
        checks.check(twoWay.offeredAtAnyGeometry?.verdict(for: twoWay.target) == .offered,
                     "audit: that smaller geometry really is offered")
        checks.check(mixed.offeredAtAnyGeometry?.ceiling == 67,
                     "audit: when the top geometry is already offered, the two answers agree")

        // Table order ranks native and panel-declared rows above size, so "the
        // first offered row" is not "the largest offered row": 75 Hz can be
        // listed at 640 × 480 near the top and at 2048 × 1536 further down.
        // Reporting the smaller one answers a question nobody asked.
        let ladder = DisplayCapabilities.RefreshAudit(
            target: 75,
            geometries: [ready,
                         DisplayCapabilities.RefreshAudit.Geometry(
                            width: 2048, height: 1536, pointSizes: [],
                            offeredRates: [75], declaredRates: [], ceiling: 76)])
        checks.check(ladder.offeredAtAnyGeometry?.width == 2048,
                     "audit: already offered means the largest such geometry, not the first row")

        // 7. An unreadable budget is not the same answer as a budget that is too
        //    small. Every row reading `unknown` means nothing was measured, and
        //    "the link tops out below it" would be inventing one.
        let undetermined = DisplayCapabilities.RefreshAudit(
            target: 60,
            geometries: [geometry(offered: [30], declared: [30], ceiling: nil)])
        checks.check(undetermined.isUndetermined,
                     "audit: a report with no readable budget is undetermined, not unreachable")
        checks.check(!mixed.isUndetermined,
                     "audit: one readable row is enough to decide")

        // 8. End to end on the fixture: the whole assembly — grouping modes by
        //    output geometry, collapsing 1000/1001 pairs, ordering, the link
        //    ceiling — not just `verdict()` in isolation.
        let audit = fixtureReport(edid).audit(target: 75)
        func row(_ width: Int, _ height: Int) -> DisplayCapabilities.RefreshAudit.Geometry? {
            audit.geometries.first { $0.width == width && $0.height == height }
        }
        checks.check(audit.geometries.count == 2, "audit end to end: one row per output geometry",
                     "\(audit.geometries.count) rows")
        checks.check(audit.geometries.first?.width == 3840,
                     "audit end to end: the native geometry leads the table")
        checks.check(row(3840, 2160)?.verdict(for: 75) == .beyondLink,
                     "audit end to end: the native row is past the link at 75 Hz")
        checks.check(row(1920, 1080)?.verdict(for: 75) == .hidden,
                     "audit end to end: declared-but-unlisted reads as hidden")
        checks.check(audit.recommendedGeometry?.width == 1920,
                     "audit end to end: the verdict skips the row the link cannot carry")
        checks.check(audit.offeredAtAnyGeometry == nil,
                     "audit end to end: nothing offers 75 Hz yet")
        checks.check(row(3840, 2160)?.verdict(for: 60) == .offered,
                     "audit end to end: the same row reads as offered at 60 Hz")
        checks.check(fixtureReport(edid).audit(target: 60).offeredAtAnyGeometry?.width == 3840,
                     "audit end to end: the zero-work answer is the largest offered row")
        checks.check(fixtureReport(edid).audit().target == 75,
                     "audit end to end: the default target is the highest declared rate")
        checks.check(row(3840, 2160)?.pointSizes.contains {
                         $0.width == 1920 && $0.height == 1080 && $0.scale > 1.01
                     } == true,
                     "audit end to end: an HiDPI point size lands on the timing it drives")

        // 9. Scale-resolution overrides. These bytes are the only thing this app
        //    hands to macOS for a custom size, so the wire format is pinned here
        //    rather than trusted to look right.
        let custom = ScaledResolution(pointWidth: 2304, pointHeight: 1296)
        checks.check([UInt8](custom.entry) == [0x00, 0x00, 0x12, 0x00,
                                               0x00, 0x00, 0x0A, 0x20],
                     "scale entry encodes 4608 × 2592 big-endian",
                     custom.entry.map { String(format: "%02X", $0) }.joined(separator: " "))
        checks.check(ScaledResolution.decode(custom.entry) == custom,
                     "scale entry round-trips")
        let sixteen = Data([0x00, 0x00, 0x12, 0x00,
                            0x00, 0x00, 0x0A, 0x20,
                            0x00, 0x00, 0x00, 0x09,
                            0x00, 0xA0, 0x00, 0x00])
        checks.check(ScaledResolution.decode(sixteen)?.pointWidth == 2304,
                     "16-byte plist form decodes from its first eight bytes")

        let base: [String: Any] = ["DisplayProductName": "Fixture", "IOGFlags": 4]
        let merged = ScaleResolutionStore.merged(payload: base, adding: custom)
        checks.check(merged["DisplayProductName"] as? String == "Fixture",
                     "scale merge keeps unrelated keys")
        checks.check(merged["IOGFlags"] as? Int == 4,
                     "scale merge keeps non-string keys")
        checks.check(ScaleResolutionStore.entries(in: merged).contains(custom),
                     "scale merge adds the entry")
        let mergedTwice = ScaleResolutionStore.merged(payload: merged, adding: custom)
        checks.check(ScaleResolutionStore.rawEntries(in: mergedTwice).count == 1,
                     "scale merge does not duplicate an entry")
        let stripped = ScaleResolutionStore.merged(payload: merged, removing: custom)
        checks.check(stripped["scale-resolutions"] == nil,
                     "scale removal drops the empty array")
        checks.check(stripped["DisplayProductName"] as? String == "Fixture",
                     "scale removal keeps the rest of the payload")

        let other = ScaledResolution(pointWidth: 2048, pointHeight: 1152)
        let baselined = ScaleResolutionStore.customEntries(
            installed: [custom.entry, custom.entry, other.entry],
            baseline: [custom.entry])
        checks.check(baselined == [custom.entry, other.entry],
                     "custom entries are the count-aware difference from Apple's baseline")

        // 10. Rotated displays report point and backing sizes in different
        //     orientations; a single-axis ratio gets the scale wrong and can
        //     make the HiDPI filter drop every row.
        let rotated = DisplayMode(displayID: 1, width: 1440, height: 2560,
                                  pixelWidth: 5120, pixelHeight: 2880)
        checks.check(rotated.isHiDPI, "rotated HiDPI is still detected")
        checks.check(abs(rotated.scale - 2.0) < 0.01,
                     "rotated scale is derived from area, not one axis",
                     String(format: "%.2f", rotated.scale))

        // 11. The plain 1× twin of a custom entry is not a selectable mode.
        let twin = DisplayMode(displayID: 1, width: 4608, height: 2592,
                               pixelWidth: 4608, pixelHeight: 2592)
        checks.check(twin.isCustomStandardTwin(of: PixelSize(width: 4608, height: 2592)),
                     "the 1× twin of a custom entry is recognised")
        checks.check(!twin.isHiDPI, "the twin is not marked HiDPI")
        let ordinary = DisplayMode(displayID: 1, width: 1920, height: 1080,
                                   pixelWidth: 1920, pixelHeight: 1080)
        checks.check(!ordinary.isCustomStandardTwin(of: PixelSize(width: 4608, height: 2592)),
                     "an ordinary 1× mode is not mistaken for a twin")

        // 12. Display identity carries the unit number, so two panels with the
        //     same EDID and serial 0 no longer overwrite each other's memory.
        let first = DisplayIdentity(vendor: 0x09D1, model: 0x8039, serial: 0,
                                    unit: 1, isBuiltin: false, ordinal: 0)
        let second = DisplayIdentity(vendor: 0x09D1, model: 0x8039, serial: 0,
                                     unit: 2, isBuiltin: false, ordinal: 1)
        checks.check(first.key != second.key, "unit number separates identical panels")
        checks.check(first.legacyKey == second.legacyKey,
                     "the old key format is shared, which is why it is only a fallback")
        let serialed = DisplayIdentity(vendor: 0x09D1, model: 0x8039, serial: 1234,
                                       unit: 7, isBuiltin: false, ordinal: 0)
        checks.check(serialed.key == serialed.legacyKey,
                     "a panel with a real serial keeps the stable old key")

        // 13. Cross-display matching: only sizes and rates present on every
        //     display survive the intersection.
        func mode(_ width: Int, _ height: Int, scale: Double, _ rate: Double) -> DisplayMode {
            DisplayMode(displayID: 1, width: width, height: height,
                        pixelWidth: Int(Double(width) * scale),
                        pixelHeight: Int(Double(height) * scale),
                        refreshRate: rate)
        }
        let common = DisplayMode.commonResolutions(
            among: [[mode(2304, 1296, scale: 2, 60), mode(2304, 1296, scale: 2, 50),
                     mode(2560, 1440, scale: 2, 60)],
                    [mode(2304, 1296, scale: 2, 60), mode(2560, 1440, scale: 2, 50)]],
            hiDPIOnly: true)
        checks.check(common.count == 1, "only the shared geometry survives",
                     "\(common.count) entries")
        checks.check(common.first?.choice.width == 2304 && common.first?.refreshRate == 60,
                     "shared geometry keeps the fastest rate both displays offer")
        checks.check(DisplayMode.commonResolutions(among: [], hiDPIOnly: false).isEmpty,
                     "no displays means no common resolutions")

        // 14. Encodability ceiling. The descriptor's clock field, not the link,
        //     is what stops a 5K timing; saying "geometry too large" would send
        //     the user looking at the wrong limit.
        let needed5K = preferred.estimatedPixelRate(width: 5120, height: 2880, refresh: 60)
        checks.check(needed5K != nil && needed5K! > DetailedTiming.maximumPixelClockHz,
                     "a 5K timing is measured above the EDID clock ceiling",
                     needed5K.map { String(format: "%.0f MHz", $0 / 1_000_000) } ?? "nil")
        let needed4K = preferred.estimatedPixelRate(width: 3840, height: 2160, refresh: 60)
        checks.check(needed4K != nil && needed4K! < DetailedTiming.maximumPixelClockHz,
                     "a 4K timing stays inside the descriptor clock field",
                     needed4K.map { String(format: "%.0f MHz", $0 / 1_000_000) } ?? "nil")

        // 15. A link too small for the panel's own minimum must not be rounded up
        //     to that minimum: that would turn "cannot carry it" into a ceiling
        //     the custom-timing path would then try to encode.
        let starved = DisplayCapabilities.Report(
            displayID: 1, edid: edid, nativeTiming: edid.preferredTiming,
            hiddenRates: [], linkMaxPixelRate: 100_000_000,
            maxRefreshRate: 76, minRefreshRate: 50,
            nativeFormat: PixelSize(width: 3840, height: 2160),
            offeredModes: [])
        if let ceiling = starved.estimatedMaximumRefresh(width: 3840, height: 2160) {
            checks.check(ceiling < 50,
                         "a starved link is reported below the vendor minimum",
                         String(format: "%.1f Hz", ceiling))
        } else {
            checks.check(false, "a starved link still yields a ceiling")
        }
        let generous = DisplayCapabilities.Report(
            displayID: 1, edid: edid, nativeTiming: edid.preferredTiming,
            hiddenRates: [], linkMaxPixelRate: 10_000_000_000,
            maxRefreshRate: 76, minRefreshRate: 50,
            nativeFormat: PixelSize(width: 3840, height: 2160),
            offeredModes: [])
        if let ceiling = generous.estimatedMaximumRefresh(width: 3840, height: 2160) {
            checks.check(abs(ceiling - 76) < 0.1,
                         "the vendor maximum still caps a generous link",
                         String(format: "%.1f Hz", ceiling))
        } else {
            checks.check(false, "a generous link yields a ceiling")
        }
    }

    // MARK: - Real panel

    private static func realPanelChecks(_ checks: inout Checks, displayIndex: Int) {
        let displays = DisplayManager.allDisplays()
        guard !displays.isEmpty else {
            print("SKIP  no display attached — real-EDID checks not run")
            return
        }
        guard displayIndex >= 0, displayIndex < displays.count else {
            checks.check(false, "display \(displayIndex) exists", "\(displays.count) attached")
            return
        }
        guard let edid = DisplayEDIDReader.read(for: displays[displayIndex].id) else {
            // A virtual screen (VM, headless runner, screen sharing) shows up in
            // the display list with a transport entry that carries no EDID blob.
            // There is nothing to read, so failing here would make every CI
            // runner red for a reason no code change can fix. When the machine
            // does publish EDIDs and this display still came back empty, the
            // fault is ours and must stay red.
            if !DisplayEDIDReader.anyTransportPublishesEDID() {
                print("SKIP  no EDID anywhere in the I/O registry"
                      + " — virtual screen, real-EDID checks not run")
                return
            }
            checks.check(false, "EDID readable for display \(displayIndex)",
                         "this machine publishes EDIDs but this display yielded none")
            return
        }

        print("EDID     \(edid.manufacturerCode) 0x\(String(format: "%04X", edid.product))"
              + "  \(edid.productName ?? "unnamed")  blocks=\(edid.blockCount)")
        checks.check(edid.hasValidChecksums, "block checksums are valid",
                     "\(edid.blockCount) block(s)")

        if let preferred = edid.preferredTiming {
            checks.check(preferred.refreshRate > 20 && preferred.refreshRate < 300,
                         "panel: preferred refresh is plausible",
                         String(format: "%.3f Hz", preferred.refreshRate))
        } else {
            checks.check(false, "panel: preferred timing decodes")
        }

        // Short-format parsing: a 4K panel should report at least one CEA rate.
        // Apple's own 5K panels declare their modes through detailed timings and
        // DisplayID blocks and carry no CEA short format at all, so "none" is a
        // property of the panel, not a parser failure.
        let short = edid.declaredRates.filter { $0.source == .ceaShortFormat }
        if short.isEmpty {
            print("SKIP  this EDID declares no CEA short formats")
        } else {
            checks.check(true, "CEA short formats parsed", "\(short.count) entries")
        }

        // Geometry matching must accept both point and pixel sizes.
        let modes = DisplayManager.allModes(for: displays[displayIndex].id)
        let declared = edid.declaredRates
        let unmatched = declared.filter { rate in
            !modes.contains {
                ($0.width == rate.width && $0.height == rate.height)
                    || ($0.pixelWidth == rate.width && $0.pixelHeight == rate.height)
            }
        }
        checks.check(unmatched.count <= declared.count,
                     "geometry matching runs", "\(unmatched.count) of \(declared.count) not offered")

        // The public-only path is what the menu uses with hidden modes off; it
        // must not smuggle private rows in through the back door.
        let publicOnly = DisplayManager.allModes(for: displays[displayIndex].id,
                                                 includeUnusable: true,
                                                 includePrivate: false)
        checks.check(publicOnly.allSatisfy { !$0.isPrivate },
                     "public-only enumeration excludes private rows",
                     "\(publicOnly.filter(\.isPrivate).count) private row(s)")
    }
}
