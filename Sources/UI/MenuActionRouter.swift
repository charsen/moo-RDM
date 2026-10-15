import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

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
    let identityKey: String
    init(displayID: CGDirectDisplayID, identityKey: String) {
        self.displayID = displayID
        self.identityKey = identityKey
    }
}

final class ProfileBox: NSObject {
    let profileID: UUID
    init(profileID: UUID) { self.profileID = profileID }
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

    private func notify(_ message: String) {
        present(message, style: .informational, title: AppInfo.name)
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
        switch ModeController.apply(box.mode, permanently: Preferences.shared.permanentChanges) {
        case .success:
            if let display = display(box.mode.displayID) { memory.remember(display: display) }
        case .failure(let error):
            report(error.description)
        }
        onMenuNeedsRebuild?()
    }

    @objc func resetToDefault(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox else { return }
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

    // MARK: - Mode memory

    @objc func rememberCurrentMode(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox,
              let display = display(box.displayID) else { return }
        memory.remember(display: display)
        onMenuNeedsRebuild?()
    }

    @objc func forgetRememberedMode(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplayBox else { return }
        Preferences.shared.forgetMode(for: box.identityKey)
        onMenuNeedsRebuild?()
    }

    @objc func restoreRememberedModes(_ sender: NSMenuItem) {
        memory.restoreRememberedModes()
        onMenuNeedsRebuild?()
    }

    // MARK: - Profiles

    @objc func saveProfile(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = L10n.t("menu.saveProfile")
        alert.informativeText = L10n.t("profile.empty")
        alert.addButton(withTitle: L10n.t("profile.save"))
        alert.addButton(withTitle: L10n.t("profile.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.t("profile.name")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        field.stringValue = formatter.string(from: Date())
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        ProfileStore.shared.upsert(ProfileStore.shared.captureCurrentLayout(named: name))
        onMenuNeedsRebuild?()
    }

    @objc func applyProfile(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ProfileBox,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == box.profileID })
        else { return }
        let outcome = ProfileStore.shared.apply(profile)
        if !outcome.warnings.isEmpty {
            report(outcome.warnings.joined(separator: "\n"))
        }
        onMenuNeedsRebuild?()
    }

    @objc func deleteProfile(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ProfileBox else { return }
        ProfileStore.shared.delete(id: box.profileID)
        onMenuNeedsRebuild?()
    }

    @objc func exportProfiles(_ sender: NSMenuItem) {
        guard !ProfileStore.shared.profiles.isEmpty else {
            report(L10n.t("menu.noProfiles"))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RDM-ARM-Profiles.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = ProfileStore.shared.profiles.count
        do {
            try ProfileStore.shared.export(to: url)
            notify(L10n.t("profile.exported", Int32(count)))
        } catch {
            report(L10n.t("profile.exportFailed", error.localizedDescription))
        }
    }

    @objc func importProfiles(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ProfileStore.shared.importProfiles(from: url)
            notify(L10n.t("profile.imported", Int32(imported)))
        } catch {
            report(L10n.t("profile.importFailed", error.localizedDescription))
        }
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
