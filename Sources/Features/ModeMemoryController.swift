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
    /// What the last restore had to compromise on, keyed by display ID.
    private(set) var lastRestoreNotes: [CGDirectDisplayID: String] = [:]

    deinit { stop() }

    /// The last restore's note for a display, e.g. "75 Hz → 60 Hz".
    func restoreNote(for displayID: CGDirectDisplayID) -> String? {
        lastRestoreNotes[displayID]
    }

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
        lastRestoreNotes.removeAll()
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
            // A display inside a mirror set follows its master's timing. Applying
            // a per-display remembered mode here would either fail or silently
            // break the mirror; presets are where mirror topology is restored.
            guard !display.isMirrored else { continue }

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

        var publicAssignments: [ModeController.Assignment] = []
        var privateModes: [DisplayMode] = []
        var changedIDs = Set<CGDirectDisplayID>()

        for entry in targets {
            guard let display = byID[entry.displayID] else { continue }
            guard let mode = ModeController.findMode(
                    on: display.id,
                    width: entry.target.width,
                    height: entry.target.height,
                    scale: entry.target.scale,
                    refreshRate: entry.target.refreshRate > 0 ? entry.target.refreshRate : nil,
                    includeUnusable: true)
            else {
                lastRestoreNotes[display.id] = L10n.t("menu.restore.missing")
                continue
            }

            if entry.target.refreshRate > 0,
               abs(mode.refreshRate - entry.target.refreshRate) > 0.5 {
                lastRestoreNotes[display.id] = L10n.t(
                    "menu.restore.rate",
                    Int32(entry.target.refreshRate.rounded()),
                    Int32(mode.refreshRate.rounded()))
            }

            if display.currentMode?.isSame(as: mode) == true { continue }
            changedIDs.insert(display.id)
            if mode.cgMode != nil {
                publicAssignments.append(ModeController.Assignment(displayID: display.id, mode: mode))
            } else {
                privateModes.append(mode)
            }
        }

        // Public modes land in one transaction; a per-display loop would make the
        // desktop reflow between every screen on attach.
        if !publicAssignments.isEmpty {
            switch ModeController.apply(publicAssignments,
                                        permanently: Preferences.shared.permanentChanges) {
            case .success:
                break
            case .failure:
                // One bad mode cancels the batch; retry per display so the rest
                // still lands.
                for assignment in publicAssignments {
                    if case .failure = ModeController.apply(assignment.mode,
                                                            permanently: Preferences.shared.permanentChanges) {
                        changedIDs.remove(assignment.displayID)
                        lastRestoreNotes[assignment.displayID] = L10n.t("menu.restore.failed")
                    }
                }
            }
        }

        // Private-table rows have no CGDisplayMode and open their own transaction.
        for mode in privateModes {
            if case .failure = ModeController.apply(mode,
                                                    permanently: Preferences.shared.permanentChanges) {
                changedIDs.remove(mode.displayID)
                lastRestoreNotes[mode.displayID] = L10n.t("menu.restore.failed")
            }
        }

        return changedIDs.count
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
