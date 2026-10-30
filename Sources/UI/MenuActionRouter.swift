import AppKit
import CoreGraphics
import Foundation

// MARK: - Represented-object boxes
//
// `NSMenuItem.representedObject` is `Any?`, and Swift structs do not survive the
// round trip as reliably as class instances do. These tiny boxes carry the payload.

final class ModeBox: NSObject {
    let mode: DisplayMode
    init(_ mode: DisplayMode) { self.mode = mode }
}

final class RotationBox: NSObject {
    let displayID: CGDirectDisplayID
    let degrees: Double
    init(displayID: CGDirectDisplayID, degrees: Double) {
        self.displayID = displayID
        self.degrees = degrees
    }
}

final class BrightnessBox: NSObject {
    let displayID: CGDirectDisplayID
    let value: Float
    init(displayID: CGDirectDisplayID, value: Float) {
        self.displayID = displayID
        self.value = value
    }
}

final class DisplayBox: NSObject {
    let displayID: CGDirectDisplayID
    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }
}

/// A set of mode changes (and optional mirror links) committed in one
/// transaction.
final class MatchBox: NSObject {
    let assignments: [ModeController.Assignment]
    let mirroring: [CGDirectDisplayID: CGDirectDisplayID]

    init(assignments: [ModeController.Assignment],
         mirroring: [CGDirectDisplayID: CGDirectDisplayID] = [:]) {
        self.assignments = assignments
        self.mirroring = mirroring
    }
}

/// One `scale-resolutions` entry, for the menu's remove submenu.
final class ResolutionBox: NSObject {
    let displayID: CGDirectDisplayID
    let resolution: ScaledResolution

    init(displayID: CGDirectDisplayID, resolution: ScaledResolution) {
        self.displayID = displayID
        self.resolution = resolution
    }
}

final class PresetBox: NSObject {
    let preset: DisplayPreset
    init(_ preset: DisplayPreset) { self.preset = preset }
}

// MARK: - Router

/// Target for every menu item action.
///
/// A single router keeps the menu construction code free of behaviour and makes
/// the whole action surface auditable in one place.
final class MenuActionRouter: NSObject {

    var onMenuNeedsRebuild: (() -> Void)?
    var onShowPreferences: (() -> Void)?
    var onShowAbout: (() -> Void)?

    let memory: ModeMemoryController

    private var customResolutionWindow: CustomResolutionWindowController?

    init(memory: ModeMemoryController) {
        self.memory = memory
        super.init()
    }

    // MARK: - Helpers

    private func display(_ id: CGDirectDisplayID) -> DisplayInfo? {
        let ids = DisplayManager.onlineDisplayIDs()
        guard let ordinal = ids.firstIndex(of: id) else { return nil }
        return DisplayManager.info(id, ordinal: ordinal)
    }

    private func report(_ error: String) {
        present(error, style: .warning, title: AppInfo.name)
    }

    private func present(_ text: String, style: NSAlert.Style, title: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L10n.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Mode

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ModeBox else { return }
        let mode = box.mode

        // Picking the mode that is already active is a no-op.
        if display(mode.displayID)?.currentMode?.isSame(as: mode) == true { return }

        // Applied straight away — no confirmation panel. The switch is meant to
        // be immediate: pick a resolution, see the result. Anything that asks a
        // question first turns a one-click action into a dialog.
        switch ModeController.apply(mode, permanently: Preferences.shared.permanentChanges) {
        case .success:
            // Record the mode only once the change actually took effect, so a
            // failed switch does not come back on the next reconnect.
            if let display = display(mode.displayID) { memory.remember(display: display) }
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    @objc func resetToDefault(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox else { return }
        // Deliberately not guarded: this is the recovery action, so it must never
        // be the thing that gets rolled back.
        switch ModeController.resetToDefault(on: box.displayID,
                                             permanently: Preferences.shared.permanentChanges) {
        case .success:
            if let display = display(box.displayID) { memory.remember(display: display) }
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    @objc func forgetRememberedMode(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox,
              let display = display(box.displayID) else { return }
        memory.forget(display: display)
        onMenuNeedsRebuild?()
    }

    // MARK: - Rotation

    @objc func selectRotation(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RotationBox else { return }
        guard abs(DisplayRotationController.currentRotation(of: box.displayID) - box.degrees) >= 0.5
        else { return }

        switch DisplayRotationController.setRotation(box.degrees, on: box.displayID) {
        case .success:
            if let display = display(box.displayID) { memory.remember(display: display) }
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    // MARK: - Brightness

    @objc func selectBrightness(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? BrightnessBox else { return }
        if case .failure(let error) = DisplayBrightnessController.setBrightness(box.value, on: box.displayID) {
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    // MARK: - Multiple displays

    private func applyMatch(_ box: MatchBox) {
        // A mirror link is about to be (re)made for these displays. Detach any
        // that are already mirrored first, so the mode assignment does not happen
        // while the display is still inside a mirror set.
        var unmirror: [CGDirectDisplayID] = []
        if !box.mirroring.isEmpty {
            let targets = Set(box.assignments.map(\.displayID))
            unmirror = DisplayManager.allInfos()
                .filter { targets.contains($0.id) && $0.isMirrored }
                .map(\.id)
        }

        switch ModeController.apply(box.assignments,
                                    mirroring: box.mirroring,
                                    unmirroring: unmirror,
                                    permanently: Preferences.shared.permanentChanges) {
        case .success:
            for assignment in box.assignments {
                memory.remember(displayID: assignment.displayID)
            }
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    @objc func matchDisplays(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MatchBox else { return }
        applyMatch(box)
    }

    @objc func mirrorDisplays(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MatchBox else { return }
        applyMatch(box)
    }

    @objc func stopMirroring(_ sender: NSMenuItem) {
        let mirrored = DisplayManager.allInfos().filter(\.isMirrored)
        guard !mirrored.isEmpty else { return }

        switch ModeController.apply([], unmirroring: mirrored.map(\.id),
                                    permanently: Preferences.shared.permanentChanges) {
        case .success:
            break
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    // MARK: - Scaled resolutions

    @objc func addScaledResolution(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox,
              let display = display(box.displayID) else { return }

        customResolutionWindow?.close()
        let controller = CustomResolutionWindowController(display: display)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.customResolutionWindow === controller else { return }
            self.customResolutionWindow = nil
        }
        customResolutionWindow = controller
        controller.present()
    }

    @objc func removeScaledResolution(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ResolutionBox,
              let edid = DisplayEDIDReader.read(for: box.displayID) else { return }

        let resolution = box.resolution
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DisplayOverrideInstaller.removeScaledResolutions([resolution], for: edid)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.present(L10n.t("window.custom.removed.hint", resolution.label),
                                 style: .informational,
                                 title: L10n.t("window.custom.removed"))
                    self.onMenuNeedsRebuild?()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.report("\(error)")
                }
            }
        }
    }

    // MARK: - Presets

    @objc func savePreset(_ sender: NSMenuItem) {
        let count = Preferences.shared.displayPresets.count
        let defaultName = L10n.t("menu.preset.defaultName", Int32(count + 1))

        let alert = NSAlert()
        alert.messageText = L10n.t("menu.preset.save.title")
        alert.informativeText = L10n.t("menu.preset.save.hint")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? defaultName : typed
        guard let preset = DisplayPresetEngine.capture(name: name) else {
            report(L10n.t("error.presetEmpty"))
            return
        }

        var presets = Preferences.shared.displayPresets
        presets.append(preset)
        Preferences.shared.displayPresets = presets
        onMenuNeedsRebuild?()
    }

    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PresetBox else { return }
        let result = DisplayPresetEngine.apply(box.preset)

        for displayID in result.applied {
            memory.remember(displayID: displayID)
        }

        if !result.appliedCleanly {
            var lines: [String] = []
            if !result.missing.isEmpty {
                lines.append(L10n.t("menu.preset.missing",
                                    result.missing.joined(separator: ", ")))
            }
            lines.append(contentsOf: result.failures)
            present(lines.joined(separator: "\n"),
                    style: .warning,
                    title: L10n.t("menu.preset.partial"))
        }
        onMenuNeedsRebuild?()
    }

    @objc func deletePreset(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PresetBox else { return }
        var presets = Preferences.shared.displayPresets
        presets.removeAll { $0.id == box.preset.id }
        Preferences.shared.displayPresets = presets
        onMenuNeedsRebuild?()
    }

    // MARK: - View toggles

    @objc func toggleShowAllModes(_ sender: NSMenuItem) {
        Preferences.shared.showUnusableModes.toggle()
        onMenuNeedsRebuild?()
    }

    @objc func toggleHiDPIOnly(_ sender: NSMenuItem) {
        Preferences.shared.hiDPIOnly.toggle()
        onMenuNeedsRebuild?()
    }

    // MARK: - App

    @objc func openPreferences(_ sender: NSMenuItem) {
        onShowPreferences?()
    }

    @objc func showAbout(_ sender: NSMenuItem) {
        onShowAbout?()
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
