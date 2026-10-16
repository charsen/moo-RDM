import AppKit
import CoreGraphics
import Foundation

/// Diagnostic mode (`--selftest`).
///
/// Creates the real status item and builds the real menu, then reports what the
/// system actually did with them. This exists because a status item's presence
/// cannot be verified from outside the process — `CGWindowListCopyWindowInfo`
/// does not enumerate menu bar extras, and screen capture needs a permission the
/// app may not have. Running the check from the inside is the only reliable way
/// to answer "did the icon actually make it onto the menu bar?".
enum GUISelfTest {

    static func run(arguments: [String] = []) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        var lines: [String] = []
        func emit(_ line: String) {
            lines.append(line)
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }

        emit("== RDM-ARM self test ==")
        emit("architecture : \(AppInfo.architecture)")
        emit("version      : \(AppInfo.versionDescription)")

        // --- status item ---
        emit("")
        emit("-- status item --")
        guard let button = statusItem.button else {
            emit("FAIL: status item has no button")
            return 1
        }
        emit("created      : true")
        emit("isVisible    : \(statusItem.isVisible)")
        emit("length       : \(statusItem.length)")

        if let image = NSImage(systemSymbolName: "display", accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            emit("icon         : SF Symbol 'display' (\(Int(image.size.width))x\(Int(image.size.height)))")
        } else {
            button.title = "RDM"
            emit("icon         : SF Symbol unavailable, using text fallback")
        }

        // Force layout and pump the run loop briefly so the window server has a
        // chance to attach the button's window before we measure it.
        button.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        button.layoutSubtreeIfNeeded()

        if let window = button.window {
            let frame = window.frame
            let screen = window.screen?.frame ?? .zero
            emit("window frame : \(fmt(frame))")
            emit("screen frame : \(fmt(screen))")
            let onScreen = screen.contains(frame.origin)
            emit("on screen    : \(onScreen)")
            if !onScreen {
                emit("NOTE: the item was created but the window server placed it off screen.")
                emit("      This normally means the menu bar is full — macOS hides")
                emit("      overflow items. Remove another item or widen the bar.")
            }
        } else {
            emit("window       : not attached yet (normal before the run loop starts)")
        }

        // --- menu ---
        emit("")
        emit("-- menu --")
        let memory = ModeMemoryController()
        let router = MenuActionRouter(memory: memory)
        let menu = NSMenu()
        StatusMenuBuilder.build(into: menu, router: router)

        emit("top level items: \(menu.items.count)")
        for item in menu.items {
            dump(item, depth: 1, emit: emit)
        }

        // --- displays ---
        emit("")
        emit("-- displays --")
        let displays = DisplayManager.allDisplays()
        emit("connected: \(displays.count)")
        for display in displays {
            let modes = DisplayManager.allModes(for: display.id,
                                                includeUnusable: Preferences.shared.showUnusableModes)
            let hidpi = modes.filter(\.isHiDPI).count
            emit("  \(display.menuTitle)")
            emit("    current   : \(display.currentDescription)")
            emit("    native    : \(display.nativePixelSize?.description ?? "unknown")")
            emit("    modes     : \(modes.count) (\(hidpi) HiDPI)")
            emit("    rotation  : \(DisplayRotationController.isAvailable ? "available" : "unavailable")")
            emit("    brightness: \(DisplayBrightnessController.canChangeBrightness(of: display.id) ? "available" : "unavailable")")
        }

        // --- modes ---
        //
        // Worth reporting rather than assuming: this is how many of the modes the
        // menu offers are ones macOS itself considers unfit for the desktop GUI.
        emit("")
        emit("-- modes --")
        let everyMode = displays.flatMap { DisplayManager.allModes(for: $0.id, includeUnusable: true) }
        let risky = everyMode.filter { !$0.isUsable }.count
        emit("risky modes  : \(risky) of \(everyMode.count) are flagged not usable for the desktop GUI")

        let hidden = everyMode.filter(\.isPrivate)
        let module = Preferences.shared.enableOptionalModule ? "on" : "off"
        emit("hidden HiDPI : \(hidden.count) extra mode(s) from the private table (optional module \(module))")
        for size in Set(hidden.map { $0.pointDescription }).sorted() {
            emit("                 \(size)")
        }

        if arguments.contains("--roundtrip") {
            guard roundTrip(emit: emit) else { return 1 }
        }

        emit("")
        emit("RESULT: self test completed")

        return 0
    }

    /// Exercises a real mode change for real: switch away, then switch back and
    /// check the display actually returned.
    ///
    /// Opt-in (`--selftest --roundtrip`) because it visibly changes the screen for
    /// a moment. It picks the *closest* usable mode rather than an arbitrary one
    /// so the flicker is as small as the hardware allows, and it always restores
    /// before returning.
    private static func roundTrip(emit: (String) -> Void) -> Bool {
        emit("")
        emit("-- mode round trip --")

        guard let display = DisplayManager.allDisplays().first,
              let current = display.currentMode else {
            emit("FAIL: no display to test against")
            return false
        }

        let usable = DisplayManager.allModes(for: display.id, includeUnusable: false)
            .filter { !$0.isSame(as: current) }
        guard let target = usable.min(by: {
            abs($0.width - current.width) + abs($0.height - current.height)
                < abs($1.width - current.width) + abs($1.height - current.height)
        }) else {
            emit("SKIP: this display only offers one usable mode")
            return true
        }

        emit("from         : \(current.menuTitle)")
        emit("to           : \(target.menuTitle)")

        guard case .success = ModeController.apply(target, permanently: false) else {
            emit("FAIL: could not apply the test mode")
            return false
        }
        emit("applied      : \(DisplayManager.currentMode(for: display.id)?.menuTitle ?? "?")")

        // Put it back by re-applying the mode recorded above.
        guard case .success = ModeController.apply(current, permanently: false) else {
            emit("FAIL: could not restore \(current.menuTitle)")
            return false
        }
        let restored = DisplayManager.currentMode(for: display.id)
        emit("restored     : \(restored?.menuTitle ?? "?")")

        guard let restored, restored.isSame(as: current) else {
            emit("FAIL: the display did not return to \(current.menuTitle)")
            return false
        }
        emit("PASS: the display returned to its original mode")
        return true
    }

    // MARK: - Helpers

    private static func fmt(_ rect: CGRect) -> String {
        String(format: "%.0fx%.0f @ %.0f,%.0f",
               rect.size.width, rect.size.height, rect.origin.x, rect.origin.y)
    }

    private static func dump(_ item: NSMenuItem, depth: Int, emit: (String) -> Void) {
        let pad = String(repeating: "  ", count: depth)
        let mark = item.state == .on ? "[x] " : (item.isEnabled ? "    " : "-   ")
        let key = item.keyEquivalent.isEmpty ? "" : "  (⌘\(item.keyEquivalent))"

        // Resolution entries deliberately omit the refresh rate from their label,
        // because the rate has its own menu now. Printing the payload is the only
        // way to check that each entry really carries the rate it should — for
        // instance that picking a resolution keeps the rate you are already on.
        var detail = ""
        if let box = item.representedObject as? ModeBox {
            detail = "   → \(box.mode.detailedTitle)  [\(box.mode.pixelDescription)]"
        }

        emit("\(pad)\(mark)\(item.title.isEmpty ? "<separator>" : item.title)\(key)\(detail)")

        if let submenu = item.submenu {
            for child in submenu.items {
                dump(child, depth: depth + 1, emit: emit)
            }
        }
    }
}
