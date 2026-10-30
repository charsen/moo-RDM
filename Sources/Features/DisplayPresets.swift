import CoreGraphics
import Foundation

/// One display's state inside a saved preset.
public struct PresetDisplay: Codable, Hashable {
    public var name: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var refreshRate: Double
    public var rotation: Double
    /// `nil` when the display does not support software brightness.
    public var brightness: Float?

    public init(name: String, width: Int, height: Int, scale: Double,
                refreshRate: Double, rotation: Double, brightness: Float?) {
        self.name = name
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
        self.rotation = rotation
        self.brightness = brightness
    }
}

/// A named set of per-display modes, rotations and mirror links.
///
/// Keyed by `DisplayIdentity.key` rather than a live display ID, so a preset
/// survives unplugging, rebooting and port changes. Displays that are not
/// connected when the preset is applied are reported and skipped, never
/// silently replaced with whichever panel happens to be attached.
public struct DisplayPreset: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Captured identity key -> state.
    public var displays: [String: PresetDisplay]
    /// Slave identity key -> master identity key.
    public var mirrors: [String: String]

    public init(id: UUID, name: String, createdAt: Date,
                displays: [String: PresetDisplay], mirrors: [String: String]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.displays = displays
        self.mirrors = mirrors
    }
}

/// Captures and applies display presets.
enum DisplayPresetEngine {

    struct ApplyReport {
        var applied: [CGDirectDisplayID] = []
        var missing: [String] = []
        var failures: [String] = []

        var appliedCleanly: Bool { missing.isEmpty && failures.isEmpty }
    }

    /// Snapshots the current topology, modes, rotation, mirror links and
    /// brightness. Returns `nil` when there is nothing to capture.
    static func capture(name: String) -> DisplayPreset? {
        let displays = DisplayManager.allInfos()
        var states: [String: PresetDisplay] = [:]

        for display in displays {
            guard let mode = display.currentMode else { continue }
            let brightness = DisplayBrightnessController.canChangeBrightness(of: display.id)
                ? DisplayBrightnessController.brightness(of: display.id)
                : nil
            states[display.identity.key] = PresetDisplay(
                name: display.name,
                width: mode.width,
                height: mode.height,
                scale: mode.scale,
                refreshRate: mode.refreshRate,
                rotation: display.rotation,
                brightness: brightness
            )
        }
        guard !states.isEmpty else { return nil }

        var mirrors: [String: String] = [:]
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        for display in displays {
            let master = CGDisplayMirrorsDisplay(display.id)
            guard master != kCGNullDirectDisplay, let masterDisplay = byID[master] else { continue }
            mirrors[display.identity.key] = masterDisplay.identity.key
        }

        return DisplayPreset(id: UUID(), name: name, createdAt: Date(),
                             displays: states, mirrors: mirrors)
    }

    /// Applies whatever part of the preset is currently possible.
    ///
    /// Rotation is a separate private call and cannot join the CoreGraphics
    /// transaction, so it runs first; the mode table is re-read afterwards
    /// because rotation changes which timings exist. Modes, unmirroring and the
    /// new mirror links then land in one transaction.
    static func apply(_ preset: DisplayPreset) -> ApplyReport {
        var report = ApplyReport()
        let sorted = preset.displays.sorted { $0.value.name < $1.value.name }

        func resolve(_ key: String, in displays: [DisplayInfo]) -> DisplayInfo? {
            displays.first { $0.identity.key == key || $0.identity.legacyKey == key }
        }

        let initial = DisplayManager.allInfos()

        var rotated = false
        for (key, state) in sorted {
            guard let display = resolve(key, in: initial),
                  abs(display.rotation - state.rotation) >= 0.5 else { continue }
            switch DisplayRotationController.setRotation(state.rotation, on: display.id) {
            case .success:
                rotated = true
            case .failure(let error):
                report.failures.append("\(state.name): \(error.description)")
            }
        }

        let current = rotated ? DisplayManager.allInfos() : initial

        // Resolve every preset entry once. A display that is not connected is
        // reported and skipped; it must never be replaced with a different panel.
        var resolved: [String: DisplayInfo] = [:]
        for (key, state) in sorted {
            if let display = resolve(key, in: current) {
                resolved[key] = display
            } else {
                report.missing.append(state.name)
            }
        }

        var assignments: [ModeController.Assignment] = []
        for (key, state) in sorted {
            guard let display = resolved[key] else { continue }
            let description = ModeController.describe(width: state.width,
                                                      height: state.height,
                                                      scale: state.scale,
                                                      refreshRate: state.refreshRate)
            guard let mode = ModeController.findMode(on: display.id,
                                                     width: state.width,
                                                     height: state.height,
                                                     scale: state.scale,
                                                     refreshRate: state.refreshRate,
                                                     includeUnusable: true) else {
                report.failures.append("\(state.name): \(L10n.t("error.noSuchMode", description))")
                continue
            }
            if state.refreshRate > 0, abs(mode.refreshRate - state.refreshRate) > 0.5 {
                report.failures.append(L10n.t("menu.preset.rate",
                                              state.name,
                                              Int32(state.refreshRate.rounded()),
                                              Int32(mode.refreshRate.rounded())))
            }
            assignments.append(ModeController.Assignment(displayID: display.id, mode: mode))
        }

        var desiredMirrors: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for (slaveKey, masterKey) in preset.mirrors {
            guard let slave = resolve(slaveKey, in: current),
                  let master = resolve(masterKey, in: current),
                  slave.id != master.id else { continue }
            desiredMirrors[slave.id] = master.id
        }

        // Detach every mirrored display this preset owns before assigning modes:
        // setting a mode while a display is still in a mirror set is the case that
        // fails on some GPUs. Desired links are re-established after assignments.
        let presetIDs = Set(resolved.values.map(\.id))
        let unmirror = current
            .filter { $0.isMirrored && presetIDs.contains($0.id) }
            .map(\.id)

        if !assignments.isEmpty || !desiredMirrors.isEmpty || !unmirror.isEmpty {
            switch ModeController.apply(assignments,
                                        mirroring: desiredMirrors,
                                        unmirroring: unmirror,
                                        permanently: Preferences.shared.permanentChanges) {
            case .success:
                report.applied = assignments.map(\.displayID)
            case .failure(let error):
                report.failures.append(error.description)
            }
        }

        // Brightness is per display and independent of the mode transaction.
        // Failures are reported but do not undo the topology change.
        for (key, state) in sorted {
            guard let brightness = state.brightness,
                  let display = resolved[key],
                  DisplayBrightnessController.canChangeBrightness(of: display.id) else { continue }
            if case .failure(let error) = DisplayBrightnessController.setBrightness(brightness,
                                                                                   on: display.id) {
                report.failures.append("\(state.name): \(error.description)")
            }
        }

        return report
    }
}
