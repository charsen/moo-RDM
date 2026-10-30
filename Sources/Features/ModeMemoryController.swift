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
        remember(display: DisplayManager.info(displayID, ordinal: ordinal))
    }

    /// The mode this display would be restored to, if any.
    func rememberedMode(for display: DisplayInfo) -> RememberedMode? {
        let all = Preferences.shared.rememberedModes
        return all[display.identity.key] ?? all[display.identity.legacyKey]
    }

    /// Stops restoring a mode for this display. The display keeps whatever it is
    /// showing now; only the automatic restore is removed.
    func forget(display: DisplayInfo) {
        Preferences.shared.forgetRememberedMode(for: display.identity.key)
        if display.identity.legacyKey != display.identity.key {
            Preferences.shared.forgetRememberedMode(for: display.identity.legacyKey)
        }
    }

    func forgetAll() {
        Preferences.shared.forgetAllRememberedModes()
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

        let displays = DisplayManager.allInfos()
        var targets: [(displayID: CGDirectDisplayID, target: RememberedMode)] = []
        var rotated = false

        // Rotate every display first: rotation changes which modes exist, so
        // interleaving it with mode application would make each lookup race the
        // previous rotation. A failed rotation is not fatal — the mode is still
        // applied at the current orientation.
        for display in displays {
            guard let target = remembered[display.identity.key]
                    ?? remembered[display.identity.legacyKey]
            else { continue }

            if let rotation = target.rotation, rotation > 0,
               abs(display.rotation - rotation) >= 0.5 {
                if case .success = DisplayRotationController.setRotation(rotation, on: display.id) {
                    rotated = true
                }
            }
            targets.append((display.id, target))
        }
        guard !targets.isEmpty else { return 0 }

        // One re-read after all rotations, instead of one per display.
        let refreshed = rotated ? DisplayManager.allInfos() : displays
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })

        var changed = 0
        for entry in targets {
            guard let display = byID[entry.displayID] else { continue }
            if apply(entry.target, to: display) { changed += 1 }
        }
        return changed
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
