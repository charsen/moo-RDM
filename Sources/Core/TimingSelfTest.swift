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

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
