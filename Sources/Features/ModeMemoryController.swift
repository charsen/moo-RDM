import AppKit
import CoreGraphics
import Foundation

public extension Notification.Name {
    /// Posted when the display topology or any display's mode changed.
    static let rdmDisplayConfigurationChanged = Notification.Name("io.rdmarm.displayConfigurationChanged")
}

/// Remembers a resolution per physical display and restores it when the display
/// comes back.
///
/// Everything here is public API: `CGDisplayRegisterReconfigurationCallback` for
/// topology changes and `NSWorkspace` for wake-from-sleep.
final class ModeMemoryController {

    /// Debounce interval after a display is attached. macOS fires the
    /// reconfiguration callback several times while it settles, and restoring
    /// too early fights the system.
    private static let restoreDelay: TimeInterval = 1.5

    private var isObserving = false
    private var pendingRestore: DispatchWorkItem?

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        guard !isObserving else { return }
        isObserving = true

        CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback,
                                                Unmanaged.passUnretained(self).toOpaque())

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback,
                                              Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pendingRestore?.cancel()
        pendingRestore = nil
    }

    /// Restores remembered modes once after launch.
    ///
    /// `start()` only registers callbacks, so before this a quit-and-relaunch
    /// dropped the "remember" promise until the display was re-attached.
    func restoreAfterLaunch() {
        scheduleRestore()
    }

    // MARK: - Recording

    /// Records the display's current mode as the one to restore later.
    func remember(display: DisplayInfo) {
        guard Preferences.shared.rememberPerDisplay, let mode = display.currentMode else { return }
        let remembered = RememberedMode(displayName: display.name,
                                        width: mode.width,
                                        height: mode.height,
                                        scale: mode.scale,
                                        refreshRate: mode.refreshRate,
                                        rotation: display.rotation == 0 ? nil : display.rotation)
        Preferences.shared.remember(remembered, for: display.identity.key)
    }

    func remember(displayID: CGDirectDisplayID) {
        let ids = DisplayManager.onlineDisplayIDs()
        guard let ordinal = ids.firstIndex(of: displayID) else { return }
        remember(display: DisplayManager.snapshot(displayID, ordinal: ordinal).display)
    }

    // MARK: - Restoring

    /// Applies every remembered mode to its matching connected display.
    ///
    /// - Returns: how many displays were changed.
    @discardableResult
    func restoreRememberedModes() -> Int {
        guard Preferences.shared.rememberPerDisplay else { return 0 }
        let remembered = Preferences.shared.rememberedModes
        guard !remembered.isEmpty else { return 0 }

        var changed = 0
        for display in DisplayManager.allDisplays() {
            // The unit-qualified key is new; fall back once to the key earlier
            // versions wrote so an upgrade does not silently forget everything.
            guard let target = remembered[display.identity.key]
                    ?? remembered[display.identity.legacyKey]
            else { continue }
            if restore(display: display, target: target) { changed += 1 }
        }
        return changed
    }

    private func restore(display: DisplayInfo, target: RememberedMode) -> Bool {
        var current = display

        if let rotation = target.rotation, rotation > 0, abs(current.rotation - rotation) >= 0.5 {
            guard case .success = DisplayRotationController.setRotation(rotation, on: current.id) else {
                return apply(target, to: current)
            }
            if let refreshed = DisplayManager.allDisplays().first(where: { $0.id == current.id }) {
                current = refreshed
            }
        }

        return apply(target, to: current)
    }

    private func apply(_ target: RememberedMode, to display: DisplayInfo) -> Bool {
        if let current = display.currentMode,
           current.width == target.width,
           current.height == target.height,
           abs(current.scale - target.scale) < 0.01,
           target.refreshRate == 0 || abs(current.refreshRate - target.refreshRate) < 0.5 {
            return false
        }

        let result = ModeController.applyResolution(on: display.id,
                                                   width: target.width,
                                                   height: target.height,
                                                   scale: target.scale,
                                                   refreshRate: target.refreshRate > 0 ? target.refreshRate : nil,
                                                   permanently: Preferences.shared.permanentChanges,
                                                   includeUnusable: true)
        if case .success = result { return true }
        return false
    }

    // MARK: - Reacting to system changes

    private func handleReconfiguration(display: CGDirectDisplayID,
                                       flags: CGDisplayChangeSummaryFlags) {
        // The menu has to hear about every topology change, even when mode memory
        // is switched off — the two are unrelated settings.
        NotificationCenter.default.post(name: .rdmDisplayConfigurationChanged, object: nil)

        guard Preferences.shared.rememberPerDisplay else { return }
        // A display was attached: schedule a restore once the topology settles.
        if flags.contains(.addFlag) {
            scheduleRestore()
        }
    }

    private func scheduleRestore() {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard Preferences.shared.rememberPerDisplay else { return }
            if self.restoreRememberedModes() > 0 {
                NotificationCenter.default.post(name: .rdmDisplayConfigurationChanged, object: nil)
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    @objc private func workspaceDidWake() {
        guard Preferences.shared.rememberPerDisplay, Preferences.shared.restoreOnWake else { return }
        scheduleRestore()
    }

    // MARK: - C callback

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = {
        display, flags, userInfo in
        guard let userInfo else { return }
        let controller = Unmanaged<ModeMemoryController>.fromOpaque(userInfo).takeUnretainedValue()
        // The callback can arrive on any thread; hop to main for UI safety.
        DispatchQueue.main.async {
            controller.handleReconfiguration(display: display, flags: flags)
        }
    }
}
