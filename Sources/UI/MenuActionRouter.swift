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
        return DisplayManager.snapshot(id, ordinal: ordinal).display
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
        switch ModeController.apply(box.assignments,
                                    mirroring: box.mirroring,
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
        let mirrored = DisplayManager.allDisplays().filter(\.isMirrored)
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
