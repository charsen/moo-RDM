import AppKit

/// Owns the status item, the menu and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let memory = ModeMemoryController()
    private var router: MenuActionRouter!
    private var settingsWindow: SettingsWindowController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.language = Preferences.shared.language

        router = MenuActionRouter(memory: memory)
        router.onMenuNeedsRebuild = { [weak self] in self?.rebuildMenu() }
        router.onShowPreferences = { [weak self] in self?.showSettings() }
        router.onShowAbout = { [weak self] in self?.showAbout() }

        installStatusItem()
        memory.start()
        // `start()` only registers callbacks. Without this, quitting and
        // relaunching silently skipped restoring remembered modes until the
        // display was re-attached.
        memory.restoreAfterLaunch()

        // Keep the menu honest when the world changes underneath us.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(stateChanged),
                                               name: .rdmDisplayConfigurationChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(stateChanged),
                                               name: Preferences.didChangeNotification,
                                               object: nil)

        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        memory.stop()
    }

    // MARK: - Status item

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let image = NSImage(systemSymbolName: "display", accessibilityDescription: AppInfo.name) {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "RDM"
        }
        statusItem.button?.toolTip = AppInfo.versionDescription

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu, let router else { return }
        StatusMenuBuilder.build(into: menu, router: router)
    }

    @objc private func stateChanged() {
        rebuildMenu()
    }

    // MARK: - Windows

    private func showSettings() {
        if let controller = settingsWindow, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController()
        settingsWindow = controller

        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: L10n.t("about.credits") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        credits.append(NSAttributedString(
            string: L10n.t("about.engine") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        credits.append(NSAttributedString(
            string: L10n.t("about.license"),
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits,
        ]

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
