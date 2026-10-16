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

    init(memory: ModeMemoryController) {
        self.memory = memory
        super.init()
    }

    // MARK: - Helpers

    private func display(_ id: CGDirectDisplayID) -> DisplayInfo? {
        DisplayManager.allDisplays().first { $0.id == id }
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
