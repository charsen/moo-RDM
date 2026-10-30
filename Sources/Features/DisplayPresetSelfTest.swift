import Foundation

/// Self tests for display presets.
///
/// Kept out of `TimingSelfTest`: that file lives in `Core/` and is deliberately
/// free of Feature/Optional dependencies. The CLI runs both under
/// `--selftest-timing`, so the flag still covers everything headlessly.
enum DisplayPresetSelfTest {

    static func run() -> Int32 {
        var failures = 0

        func check(_ condition: Bool, _ label: String,
                   _ detail: @autoclosure () -> String = "") {
            if condition {
                print("PASS  \(label)")
            } else {
                failures += 1
                let extra = detail()
                print("FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }

        let sampleDisplay = PresetDisplay(name: "Studio Display", width: 2304, height: 1296,
                                          scale: 2, refreshRate: 60, rotation: 0, brightness: 0.5)
        let samplePreset = DisplayPreset(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Work",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            displays: ["edid:0610:AE46:FCA3901D:e": sampleDisplay],
            mirrors: ["edid:09D1:8039:00005445:e": "edid:0610:AE46:FCA3901D:e"])

        if let data = try? JSONEncoder().encode(samplePreset),
           let decoded = try? JSONDecoder().decode(DisplayPreset.self, from: data) {
            check(decoded == samplePreset, "display presets round-trip through JSON")
        } else {
            check(false, "display presets round-trip through JSON")
        }

        let ghost = DisplayPreset(
            id: UUID(),
            name: "Ghost",
            createdAt: Date(timeIntervalSince1970: 0),
            displays: ["edid:FFFF:FFFF:00000000:e": PresetDisplay(
                name: "Ghost", width: 1920, height: 1080, scale: 2,
                refreshRate: 60, rotation: 0, brightness: nil)],
            mirrors: [:])
        let ghostReport = DisplayPresetEngine.apply(ghost)
        check(ghostReport.applied.isEmpty && ghostReport.missing == ["Ghost"],
              "a preset for an unplugged display is reported, not applied",
              "applied \(ghostReport.applied.count), missing \(ghostReport.missing)")

        let displays = DisplayManager.allInfos()
        if displays.isEmpty {
            print("SKIP  no display attached — preset capture not run")
        } else if let preset = DisplayPresetEngine.capture(name: "selftest") {
            check(preset.displays.count == displays.count,
                  "preset capture covers every attached display",
                  "\(preset.displays.count) of \(displays.count)")
        } else {
            check(false, "preset capture succeeds")
        }

        print(failures == 0
              ? "\nall preset checks passed"
              : "\n\(failures) preset check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
