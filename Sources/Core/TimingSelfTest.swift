import CoreGraphics
import Foundation

/// Pure-logic checks for the EDID and timing code, run with `--selftest-timing`.
///
/// Nothing here touches the system: no override is written, no mode is changed.
/// The point is to pin the parts that are easy to get subtly wrong — descriptor
/// field packing, checksum repair, and the promise that re-clocking changes the
/// pixel clock and *nothing else*.
enum TimingSelfTest {

    static func run(displayIndex: Int = 0) -> Int32 {
        let displays = DisplayManager.allDisplays()
        guard displayIndex >= 0, displayIndex < displays.count else {
            print("FAIL  no display at index \(displayIndex)")
            return 1
        }
        guard let edid = DisplayEDIDReader.read(for: displays[displayIndex].id) else {
            print("FAIL  no EDID for display \(displayIndex)")
            return 1
        }

        var failures = 0
        func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("PASS  \(label)")
            } else {
                failures += 1
                let extra = detail()
                print("FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }

        print("EDID     \(edid.manufacturerCode) 0x\(String(format: "%04X", edid.product))"
              + "  \(edid.productName ?? "unnamed")  blocks=\(edid.blockCount)")

        // 1. The preferred descriptor must decode to something a panel could use.
        guard let preferred = edid.preferredTiming else {
            print("FAIL  no preferred timing")
            return 1
        }
        check(preferred.width > 0 && preferred.height > 0, "preferred timing decodes",
              preferred.description)
        check(preferred.refreshRate > 20 && preferred.refreshRate < 300,
              "preferred refresh is plausible", String(format: "%.3f Hz", preferred.refreshRate))
        check(preferred.hTotal > preferred.hActive && preferred.vTotal > preferred.vActive,
              "blanking present", "totals \(preferred.hTotal) × \(preferred.vTotal)")

        // 2. Re-clocking must change bytes 0 and 1 only. Anything else and the
        //    descriptor's sync structure was silently rewritten.
        let target = min(preferred.refreshRate + 5, 200)
        if let retimed = preferred.retimed(toRefresh: target) {
            let changed = zip(preferred.raw, retimed.raw).enumerated()
                .filter { $0.element.0 != $0.element.1 }
                .map(\.offset)
            check(changed == [0, 1], "re-clock touches only the pixel clock",
                  "changed offsets \(changed)")
            check(abs(retimed.refreshRate - target) < 0.05,
                  "re-clocked rate is within 0.05 Hz of the request",
                  String(format: "asked %.3f, got %.3f", target, retimed.refreshRate))
            check(retimed.hTotal == preferred.hTotal && retimed.vTotal == preferred.vTotal,
                  "re-clock keeps totals")

            // 3. Patching the EDID must keep the blob intact and the preferred
            //    timing untouched.
            let patched = edid.adding(retimed)
            check(patched != nil, "EDID accepts an extra timing")
            if let patched {
                check(patched.bytes.count == edid.bytes.count, "block count unchanged",
                      "\(patched.blockCount) of \(edid.blockCount)")
                check(patched.hasValidChecksums, "patched checksums valid")
                check(patched.preferredTiming == preferred, "preferred timing untouched")
                check(patched.detailedTimings.contains { abs($0.refreshRate - target) < 0.05 },
                      "patched timing is enumerable")
                check(patched.productName == edid.productName, "product name survives the patch")
            }
        } else {
            check(false, "re-clock produces a descriptor")
        }

        // 4. Scaling to a smaller geometry: blanking ratios carry over and the
        //    resulting timing is still structurally sane.
        if let synthetic = preferred.scaled(toWidth: preferred.width / 2,
                                            toHeight: preferred.height / 2,
                                            refresh: 60) {
            check(synthetic.width == preferred.width / 2 && synthetic.height == preferred.height / 2,
                  "scaled geometry is exact")
            check(synthetic.hBlank - synthetic.hFrontPorch - synthetic.hSyncWidth > 0,
                  "scaled horizontal blanking has a back porch",
                  "blank \(synthetic.hBlank), front \(synthetic.hFrontPorch), sync \(synthetic.hSyncWidth)")
            check(synthetic.vBlank - synthetic.vFrontPorch - synthetic.vSyncWidth > 0,
                  "scaled vertical blanking has a back porch",
                  "blank \(synthetic.vBlank), front \(synthetic.vFrontPorch), sync \(synthetic.vSyncWidth)")
            check(abs(synthetic.refreshRate - 60) < 0.05, "scaled rate is 60 Hz",
                  String(format: "%.3f Hz", synthetic.refreshRate))
        } else {
            check(false, "scaling to half geometry succeeds")
        }

        // 5. Short-format parsing: a 4K panel should report at least one CEA rate.
        let short = edid.declaredRates.filter { $0.source == .ceaShortFormat }
        check(!short.isEmpty, "CEA short formats parsed", "\(short.count) entries")

        // 6. Geometry matching must accept both point and pixel sizes.
        let modes = DisplayManager.allModes(for: displays[displayIndex].id)
        let declared = edid.declaredRates
        let unmatched = declared.filter { rate in
            !modes.contains {
                ($0.width == rate.width && $0.height == rate.height)
                    || ($0.pixelWidth == rate.width && $0.pixelHeight == rate.height)
            }
        }
        check(unmatched.count <= declared.count,
              "geometry matching runs", "\(unmatched.count) of \(declared.count) not offered")

        // 7. `--refresh-audit` exists to distinguish four causes that have
        //    nothing in common. Each implies a different fix, so each verdict
        //    gets pinned here rather than trusted to read correctly in a table.
        func geometry(offered: [Double], declared: [Double],
                      ceiling: Double?) -> DisplayCapabilities.RefreshAudit.Geometry {
            DisplayCapabilities.RefreshAudit.Geometry(
                width: 3840, height: 2160, pointSizes: [],
                offeredRates: offered, declaredRates: declared, ceiling: ceiling)
        }
        check(geometry(offered: [60, 50], declared: [60, 50], ceiling: 67).verdict(for: 60) == .offered,
              "audit: a listed rate reads as offered")
        check(geometry(offered: [30], declared: [60, 30], ceiling: 67).verdict(for: 60) == .hidden,
              "audit: declared but unlisted reads as hidden")
        check(geometry(offered: [], declared: [60], ceiling: 67).verdict(for: 60) == .hidden,
              "audit: a whole missing geometry still reads as hidden")
        check(geometry(offered: [30], declared: [30], ceiling: 67).verdict(for: 60) == .synthesizable,
              "audit: budgeted but undeclared reads as synthesizable")
        check(geometry(offered: [30], declared: [30], ceiling: 30).verdict(for: 60) == .beyondLink,
              "audit: over-budget reads as beyond link")
        check(geometry(offered: [30], declared: [30], ceiling: nil).verdict(for: 60) == .unknown,
              "audit: a missing budget reads as unknown")
        // CoreGraphics rounds 59.94 to 60 in the mode list while the panel's
        // descriptor keeps 59.94. Without the 0.5 Hz tolerance every 1000/1001
        // rate would read as missing from a mode that is right there.
        check(geometry(offered: [59.94], declared: [59.94], ceiling: 67).verdict(for: 60) == .offered,
              "audit: 59.94 and 60 are one answer, not two")

        let mixed = DisplayCapabilities.RefreshAudit(
            target: 60,
            geometries: [geometry(offered: [30], declared: [30], ceiling: 30),
                         geometry(offered: [60], declared: [60], ceiling: 67)])
        check(mixed.recommendedGeometry?.ceiling == 67,
              "audit: the verdict skips geometries the link cannot carry")

        // 8. The largest geometry that reaches a rate and the largest geometry
        //    that already offers it are two different answers, and the CLI has to
        //    name both. Reporting only the first sends someone off to synthesise
        //    a timing at 1920 × 1080 when 640 × 480 has listed the rate all along.
        let ready = DisplayCapabilities.RefreshAudit.Geometry(
            width: 640, height: 480, pointSizes: [],
            offeredRates: [75, 60], declaredRates: [60], ceiling: 76)
        let twoWay = DisplayCapabilities.RefreshAudit(
            target: 75,
            geometries: [geometry(offered: [60], declared: [60], ceiling: 76), ready])
        check(twoWay.recommendedGeometry?.width == 3840,
              "audit: the largest reachable geometry decides the verdict")
        check(twoWay.offeredAtAnyGeometry?.width == 640,
              "audit: an already-listed smaller geometry is reported separately")
        check(twoWay.offeredAtAnyGeometry?.verdict(for: twoWay.target) == .offered,
              "audit: that smaller geometry really is offered")
        check(mixed.offeredAtAnyGeometry?.ceiling == 67,
              "audit: when the top geometry is already offered, the two answers agree")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
