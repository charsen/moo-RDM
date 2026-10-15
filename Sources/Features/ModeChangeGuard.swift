import AppKit
import CoreGraphics
import Foundation

/// Applies a display change, then rolls it back automatically unless the user
/// confirms it within a few seconds.
///
/// Why this exists: a mode the panel cannot actually show leaves the screen
/// black, and the menu bar that would let you undo it is drawn on that same
/// display. There is no way back except waiting or rebooting.
///
/// This is not a theoretical risk for this app. On the display it was developed
/// against, 77 of the 257 modes macOS reports are flagged
/// `kDisplayModeNotGraphicsQuality`-class "not usable for the desktop GUI", and
/// the app shows them by default — that is the whole point of RDM. Offering
/// those modes without a way back would be irresponsible.
///
/// The rollback does not depend on the UI being readable: the timer lives on the
/// run loop, so the revert fires even if the confirmation panel is invisible.
final class ModeChangeGuard {

    static let shared = ModeChangeGuard()

    /// How long the user gets to confirm before the change is undone.
    /// Matches the interval macOS itself uses for its own display confirmation.
    static let timeout: TimeInterval = 15

    private init() {}

    /// A display and the mode it was using.
    fileprivate struct SnapshotEntry {
        let displayID: CGDirectDisplayID
        let mode: DisplayMode
        let rotation: Double
    }

    /// Everything needed to put the displays back the way they were.
    ///
    /// Opaque on purpose: callers should hand it straight back to `rollback(to:)`
    /// rather than inspect it, so the contents can change without breaking them.
    struct Snapshot {
        fileprivate let entries: [SnapshotEntry]
        fileprivate var isEmpty: Bool { entries.isEmpty }
        /// Number of displays that can be restored.
        var count: Int { entries.count }
    }

    /// Records the current mode and rotation of every display.
    ///
    /// Call this *before* changing anything — once the new mode is applied the
    /// previous one is gone.
    func snapshotBefore() -> Snapshot {
        Snapshot(entries: DisplayManager.allDisplays().compactMap { display in
            display.currentMode.map {
                SnapshotEntry(displayID: display.id, mode: $0, rotation: display.rotation)
            }
        })
    }

    /// Puts every display back to the state in `snapshot`.
    func rollback(to snapshot: Snapshot, permanently: Bool) {
        for entry in snapshot.entries {
            _ = ModeController.apply(entry.mode, permanently: permanently)
            // Rotation is part of "put it back how it was" — a wrong angle is
            // just as hard to undo by hand as a wrong resolution.
            if DisplayRotationController.isAvailable {
                _ = DisplayRotationController.setRotation(entry.rotation, on: entry.displayID)
            }
        }
    }

    /// Shows the confirmation panel and waits for an answer.
    ///
    /// - Returns: `true` to keep the new mode, `false` to revert.
    func confirm(description: String) -> Bool {
        askUser(description: description)
    }

    /// Runs `change`, then asks the user to confirm it.
    ///
    /// - Parameters:
    ///   - permanently: whether the change was persisted, so the rollback undoes
    ///     it the same way.
    ///   - description: what the user just switched to, shown in the prompt.
    ///   - change: performs the change and reports whether it took effect.
    /// - Returns: `true` if the change was kept, `false` if it was rolled back or
    ///   never applied.
    @discardableResult
    func perform(permanently: Bool,
                 description: String,
                 change: () -> Bool) -> Bool {
        // Capture the "before" state first — after the change it is gone.
        let before = snapshotBefore()

        guard change() else { return false }

        // Nothing to fall back to; do not block the user for no reason.
        guard !before.isEmpty else { return true }

        guard Preferences.shared.confirmModeChanges else { return true }

        if confirm(description: description) { return true }

        rollback(to: before, permanently: permanently)
        return false
    }

    // MARK: - Confirmation UI

    /// - Returns: `true` to keep the new mode, `false` to revert.
    private func askUser(description: String) -> Bool {
        // `NSApp` is an implicitly-unwrapped optional and traps when nil. The
        // command-line path reaches this code without ever having touched
        // `NSApplication.shared`, so take the reference explicitly.
        let app = NSApplication.shared

        let total = Int(Self.timeout.rounded())
        var remaining = total

        let window = makeWindow()

        let body = NSTextField(wrappingLabelWithString:
            L10n.t("guard.body", description, Int32(total)))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false

        let countdown = NSTextField(labelWithString: "\(remaining)")
        countdown.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        countdown.alignment = .center
        countdown.translatesAutoresizingMaskIntoConstraints = false

        let unit = NSTextField(labelWithString: L10n.t("guard.seconds"))
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor
        unit.alignment = .center
        unit.translatesAutoresizingMaskIntoConstraints = false

        let keep = NSButton(title: L10n.t("guard.keep"), target: nil, action: nil)
        keep.bezelStyle = .rounded
        keep.keyEquivalent = "\r"
        keep.translatesAutoresizingMaskIntoConstraints = false

        let revert = NSButton(title: L10n.t("guard.revert"), target: nil, action: nil)
        revert.bezelStyle = .rounded
        revert.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L10n.t("guard.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return true }
        for view in [title, body, countdown, unit, keep, revert] as [NSView] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            countdown.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            countdown.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            unit.topAnchor.constraint(equalTo: countdown.bottomAnchor, constant: -4),
            unit.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            revert.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            revert.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),

            keep.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            keep.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            keep.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            content.widthAnchor.constraint(equalToConstant: 430),
        ])

        // A modal run loop only pumps `.modalPanel`; `.common` is what makes the
        // timer fire while the panel is up.
        let timer = Timer(timeInterval: 1, repeats: true) { tick in
            remaining -= 1
            if remaining <= 0 {
                tick.invalidate()
                app.stopModal(withCode: .cancel)
            } else {
                countdown.stringValue = "\(remaining)"
            }
        }
        RunLoop.current.add(timer, forMode: .common)

        // Plain target/action: the panel is built without a controller object.
        let bridge = ButtonBridge { response in
            app.stopModal(withCode: response)
        }
        keep.target = bridge
        keep.action = #selector(ButtonBridge.keep(_:))
        revert.target = bridge
        revert.action = #selector(ButtonBridge.revert(_:))

        app.activate(ignoringOtherApps: true)
        window.center()
        let response = app.runModal(for: window)
        timer.invalidate()
        window.orderOut(nil)

        // Keep the bridge alive until the modal loop is over.
        withExtendedLifetime(bridge) {}
        return response == .OK
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        // Above the menu bar and any full-screen app: if the screen is in a bad
        // state, this panel is the only thing the user can reach.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        return window
    }

    /// Small target object so the panel's buttons can drive the modal loop.
    private final class ButtonBridge: NSObject {
        private let stop: (NSApplication.ModalResponse) -> Void
        init(stop: @escaping (NSApplication.ModalResponse) -> Void) { self.stop = stop }
        @objc func keep(_ sender: Any?) { stop(.OK) }
        @objc func revert(_ sender: Any?) { stop(.cancel) }
    }
}
