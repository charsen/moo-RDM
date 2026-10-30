import AppKit

/// Owns the status item, the menu and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let memory = ModeMemoryController()
    private var router: MenuActionRouter!
    private var settingsWindow: SettingsWindowController?
    private var isMenuOpen = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.language = Preferences.shared.language

        router = MenuActionRouter(memory: memory)
        router.onMenuNeedsRebuild = { [weak self] in self?.requestRebuild() }
        router.onShowPreferences = { [weak self] in self?.showSettings() }
        router.onShowAbout = { [weak self] in self?.showAbout() }

        installStatusItem()
        installMainMenu()
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

        // The menu is built on first open; building it now would be work for a
        // window nobody has asked to see yet.
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

    /// An accessory app has no menu bar, but a main menu is still what makes the
    /// standard ⌘, / ⌘Q key equivalents work while the status menu is closed.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()

        let about = NSMenuItem(title: L10n.t("menu.about"),
                               action: #selector(showAboutFromMainMenu(_:)),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let preferences = NSMenuItem(title: L10n.t("menu.preferences"),
                                     action: #selector(openPreferencesFromMainMenu(_:)),
                                     keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("menu.quit"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func openPreferencesFromMainMenu(_ sender: Any?) {
        showSettings()
    }

    @objc private func showAboutFromMainMenu(_ sender: Any?) {
        showAbout()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Always rebuild here: this is the one place where freshness is cheap and
        // required. Everything else only asks for a rebuild while the menu is
        // actually open.
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu, let router else { return }
        StatusMenuBuilder.build(into: menu, router: router)
    }

    /// Rebuild only if someone can see the result. Mode changes, hot-plug events
    /// and preference writes used to rebuild the whole menu while it was closed;
    /// the next open rebuilds anyway.
    private func requestRebuild() {
        guard isMenuOpen else { return }
        rebuildMenu()
    }

    @objc private func stateChanged() {
        requestRebuild()
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
