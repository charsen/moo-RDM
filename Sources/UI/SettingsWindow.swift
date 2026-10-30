import AppKit

// The settings window is written in plain AppKit rather than SwiftUI.
//
// SwiftUI's `@State` / `@Binding` / `@StateObject` are macros, and the
// `SwiftUIMacros` plugin ships only inside Xcode.app — it is absent from the
// Command Line Tools toolchain. Using SwiftUI here would force every user to
// install the full 10 GB Xcode, which defeats the point of this rewrite.

// MARK: - Window controller

final class SettingsWindowController: NSWindowController {

    private let content: SettingsViewController

    init() {
        content = SettingsViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("settings.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        window.contentViewController = content
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Tab host

final class SettingsViewController: NSViewController, NSTabViewDelegate {

    private struct Tab {
        let titleKey: String
        let item: NSTabViewItem
        let scroll: NSScrollView
        let container: NSView
        var built: Bool
    }

    private var tabView: NSTabView!
    private var tabs: [Tab] = []
    private var observers: [NSObjectProtocol] = []
    private var languageRebuildScheduled = false

    // Kept so a preference change updates state in place. Rebuilding all three
    // tabs measured ~20 ms; this path is a handful of assignments.
    private var languagePopup: NSPopUpButton?
    private var showUnusableCheckbox: NSButton?
    private var hiDPIOnlyCheckbox: NSButton?
    private var rememberCheckbox: NSButton?
    private var restoreOnWakeCheckbox: NSButton?
    private var forgetAllButton: NSButton?
    private var permanentCheckbox: NSButton?
    private var optionalModuleCheckbox: NSButton?
    private var rotationStatusLabel: NSTextField?
    private var brightnessStatusLabel: NSTextField?
    private var hiddenHiDPIStatusLabel: NSTextField?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView(frame: view.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self
        view.addSubview(tabView)

        makeTab(titleKey: "settings.general", identifier: "general")
        makeTab(titleKey: "settings.advanced", identifier: "advanced")
        makeTab(titleKey: "settings.about", identifier: "about")
        tabView.selectTabViewItem(at: 0)
        installTab(at: 0)

        let center = NotificationCenter.default
        // Preferences change often (every mode switch writes rememberedModes):
        // update the visible controls instead of rebuilding the window.
        observers.append(center.addObserver(forName: Preferences.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.refreshControls()
        })
        observers.append(center.addObserver(forName: .rdmLanguageChanged,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLanguageRebuild()
        })
        // Hot-plug and rotation change the status rows, not the toggles.
        observers.append(center.addObserver(forName: .rdmDisplayConfigurationChanged,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusRows()
        })
    }

    // MARK: - Tabs

    private func makeTab(titleKey: String, identifier: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])

        let item = NSTabViewItem(identifier: identifier)
        item.label = L10n.t(titleKey)
        item.view = scroll
        tabView.addTabViewItem(item)
        tabs.append(Tab(titleKey: titleKey, item: item, scroll: scroll,
                        container: container, built: false))
    }

    /// Build a tab's content the first time it is selected. The Advanced tab
    /// includes diagnostics and mode counts, so building it eagerly made the
    /// General tab pay for work nobody was looking at.
    private func installTab(at index: Int) {
        guard index >= 0, index < tabs.count, !tabs[index].built else { return }
        let tab = tabs[index]
        for subview in tab.container.subviews { subview.removeFromSuperview() }

        let content: NSView
        switch index {
        case 0: content = generalTab()
        case 1: content = advancedTab()
        default: content = aboutTab()
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        tab.container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: tab.container.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: tab.container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: tab.container.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: tab.container.bottomAnchor, constant: -16),
        ])
        tabs[index].built = true
        refreshControls()
    }

    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        guard let item else { return }
        installTab(at: tabView.indexOfTabViewItem(item))
    }

    private func scheduleLanguageRebuild() {
        guard !languageRebuildScheduled else { return }
        languageRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.languageRebuildScheduled = false
            self.rebuildForLanguage()
        }
    }

    /// Language is the one change that has to rebuild strings; everything else
    /// is handled by `refreshControls`.
    private func rebuildForLanguage() {
        guard isViewLoaded else { return }
        let selected = tabView.selectedTabViewItem
            .flatMap { tabView.indexOfTabViewItem($0) } ?? 0
        view.window?.title = L10n.t("settings.title")
        clearControlReferences()

        for index in tabs.indices {
            tabs[index].item.label = L10n.t(tabs[index].titleKey)
            for subview in tabs[index].container.subviews { subview.removeFromSuperview() }
            tabs[index].built = false
        }

        installTab(at: selected)
        tabView.selectTabViewItem(at: selected)
    }

    private func clearControlReferences() {
        languagePopup = nil
        showUnusableCheckbox = nil
        hiDPIOnlyCheckbox = nil
        rememberCheckbox = nil
        restoreOnWakeCheckbox = nil
        forgetAllButton = nil
        permanentCheckbox = nil
        optionalModuleCheckbox = nil
        rotationStatusLabel = nil
        brightnessStatusLabel = nil
        hiddenHiDPIStatusLabel = nil
    }

    private func refreshControls() {
        languagePopup?.selectItem(at: AppLanguage.allCases.firstIndex(of: Preferences.shared.language) ?? 0)
        showUnusableCheckbox?.state = Preferences.shared.showUnusableModes ? .on : .off
        hiDPIOnlyCheckbox?.state = Preferences.shared.hiDPIOnly ? .on : .off
        rememberCheckbox?.state = Preferences.shared.rememberPerDisplay ? .on : .off
        restoreOnWakeCheckbox?.state = Preferences.shared.restoreOnWake ? .on : .off
        forgetAllButton?.isEnabled = !Preferences.shared.rememberedModes.isEmpty
        permanentCheckbox?.state = Preferences.shared.permanentChanges ? .on : .off
        optionalModuleCheckbox?.state = Preferences.shared.enableOptionalModule ? .on : .off
        refreshStatusRows()
    }

    private func refreshStatusRows() {
        rotationStatusLabel?.stringValue = rotationStatus()
        brightnessStatusLabel?.stringValue = brightnessStatus()
        hiddenHiDPIStatusLabel?.stringValue = hiddenHiDPIStatus()
    }

    // MARK: - General

    private func generalTab() -> NSView {
        let stack = verticalStack()

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.language")))

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for language in AppLanguage.allCases {
            popup.addItem(withTitle: language.displayName)
            popup.lastItem?.representedObject = language.rawValue
        }
        popup.selectItem(at: AppLanguage.allCases.firstIndex(of: Preferences.shared.language) ?? 0)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        languagePopup = popup
        stack.addArrangedSubview(popup)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("menu.resolution")))
        let showUnusable = checkbox(L10n.t("settings.showUnusable"),
                                    on: Preferences.shared.showUnusableModes,
                                    action: #selector(toggleShowUnusable(_:)))
        showUnusableCheckbox = showUnusable
        stack.addArrangedSubview(showUnusable)
        addFullWidth(hint(L10n.t("settings.showUnusable.hint")), to: stack)

        let hiDPIOnly = checkbox(L10n.t("settings.hiDPIOnly"),
                                 on: Preferences.shared.hiDPIOnly,
                                 action: #selector(toggleHiDPIOnly(_:)))
        hiDPIOnlyCheckbox = hiDPIOnly
        stack.addArrangedSubview(hiDPIOnly)
        addFullWidth(hint(L10n.t("settings.hiDPIOnly.hint")), to: stack)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.section.memory")))
        let remember = checkbox(L10n.t("settings.rememberPerDisplay"),
                                on: Preferences.shared.rememberPerDisplay,
                                action: #selector(toggleRemember(_:)))
        rememberCheckbox = remember
        stack.addArrangedSubview(remember)
        addFullWidth(hint(L10n.t("settings.rememberPerDisplay.hint")), to: stack)

        let restore = checkbox(L10n.t("settings.restoreOnWake"),
                               on: Preferences.shared.restoreOnWake,
                               action: #selector(toggleRestoreOnWake(_:)))
        restoreOnWakeCheckbox = restore
        stack.addArrangedSubview(restore)
        addFullWidth(hint(L10n.t("settings.restoreOnWake.hint")), to: stack)

        let forgetAll = NSButton(title: L10n.t("settings.forgetAll"),
                                 target: self,
                                 action: #selector(forgetAllRemembered(_:)))
        forgetAll.bezelStyle = .rounded
        forgetAll.isEnabled = !Preferences.shared.rememberedModes.isEmpty
        forgetAllButton = forgetAll
        stack.addArrangedSubview(forgetAll)
        addFullWidth(hint(L10n.t("settings.forgetAll.hint")), to: stack)

        return stack
    }

    // MARK: - Advanced

    private func advancedTab() -> NSView {
        let stack = verticalStack()

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.section.changes")))
        let permanent = checkbox(L10n.t("settings.permanent"),
                                 on: Preferences.shared.permanentChanges,
                                 action: #selector(togglePermanent(_:)))
        permanentCheckbox = permanent
        stack.addArrangedSubview(permanent)
        addFullWidth(hint(L10n.t("settings.permanent.hint")), to: stack)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.section.private")))
        let optional = checkbox(L10n.t("settings.optionalModule"),
                                on: Preferences.shared.enableOptionalModule,
                                action: #selector(toggleOptionalModule(_:)))
        optionalModuleCheckbox = optional
        stack.addArrangedSubview(optional)
        addFullWidth(hint(L10n.t("settings.optionalModule.hint")), to: stack)

        let rotation = statusRow(L10n.t("menu.rotation"), rotationStatus())
        rotationStatusLabel = rotation.detail
        stack.addArrangedSubview(rotation.view)

        let brightness = statusRow(L10n.t("menu.brightness"), brightnessStatus())
        brightnessStatusLabel = brightness.detail
        stack.addArrangedSubview(brightness.view)

        let hidden = statusRow(L10n.t("settings.hiddenHiDPI"), hiddenHiDPIStatus())
        hiddenHiDPIStatusLabel = hidden.detail
        stack.addArrangedSubview(hidden.view)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.diagnostics.title")))

        let copyButton = NSButton(title: L10n.t("settings.diagnostics"), target: self, action: #selector(copyDiagnostics(_:)))
        copyButton.bezelStyle = .rounded
        stack.addArrangedSubview(copyButton)

        // The diagnostics block is long and expensive to lay out; generate it
        // when the button is pressed instead of on every Advanced-tab visit.
        let diagnosticsHint = NSTextField(wrappingLabelWithString: L10n.t("settings.diagnostics.hint"))
        diagnosticsHint.font = .systemFont(ofSize: 10)
        diagnosticsHint.textColor = .tertiaryLabelColor
        addFullWidth(diagnosticsHint, to: stack)

        return stack
    }

    private func rotationStatus() -> String {
        guard DisplayRotationController.isSymbolPresent else {
            return L10n.t("settings.status.unavailable")
        }
        return Preferences.shared.enableOptionalModule
            ? L10n.t("settings.status.available")
            : L10n.t("settings.status.disabled")
    }

    private func brightnessStatus() -> String {
        let count = DisplayManager.allInfos()
            .filter { DisplayBrightnessController.canChangeBrightness(of: $0.id) }
            .count
        return count > 0
            ? L10n.t("settings.status.brightness", Int32(count))
            : L10n.t("settings.status.unavailable")
    }

    private func hiddenHiDPIStatus() -> String {
        guard PrivateModeTable.isSymbolPresent else {
            return L10n.t("settings.status.unavailable")
        }
        guard Preferences.shared.enableOptionalModule else {
            return L10n.t("settings.status.disabled")
        }
        let count = DisplayManager.allInfos()
            .flatMap { DisplayManager.allModes(for: $0.id) }
            .filter(\.isPrivate)
            .count
        return count > 0
            ? L10n.t("settings.status.hiddenHiDPI", Int32(count))
            : L10n.t("settings.status.none")
    }

    // MARK: - About

    private func aboutTab() -> NSView {
        let stack = verticalStack(spacing: 10)
        stack.alignment = .centerX

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
        icon.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .systemFont(ofSize: 20, weight: .medium)
        stack.addArrangedSubview(name)

        let version = NSTextField(labelWithString: L10n.t("about.version", AppInfo.version))
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)

        stack.addArrangedSubview(divider())

        for text in [L10n.t("about.credits"), L10n.t("about.engine"), L10n.t("about.license")] {
            let label = NSTextField(wrappingLabelWithString: text)
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 380
            stack.addArrangedSubview(label)
        }

        let repoButton = NSButton(title: L10n.t("about.repo"), target: self, action: #selector(openUpstream(_:)))
        repoButton.bezelStyle = .rounded
        stack.addArrangedSubview(repoButton)

        return stack
    }

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        Preferences.shared.language = language
    }

    @objc private func toggleShowUnusable(_ sender: NSButton) {
        Preferences.shared.showUnusableModes = sender.state == .on
    }

    @objc private func toggleHiDPIOnly(_ sender: NSButton) {
        Preferences.shared.hiDPIOnly = sender.state == .on
    }

    @objc private func toggleRemember(_ sender: NSButton) {
        Preferences.shared.rememberPerDisplay = sender.state == .on
    }

    @objc private func toggleRestoreOnWake(_ sender: NSButton) {
        Preferences.shared.restoreOnWake = sender.state == .on
    }

    @objc private func togglePermanent(_ sender: NSButton) {
        Preferences.shared.permanentChanges = sender.state == .on
    }

    @objc private func toggleOptionalModule(_ sender: NSButton) {
        Preferences.shared.enableOptionalModule = sender.state == .on
    }

    @objc private func forgetAllRemembered(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("settings.forgetAll.confirm")
        alert.informativeText = L10n.t("settings.forgetAll.confirm.hint")
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Preferences.shared.forgetAllRememberedModes()
    }

    @objc private func copyDiagnostics(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.diagnostics(), forType: .string)
        sender.title = L10n.t("settings.diagnostics.done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            sender.title = L10n.t("settings.diagnostics")
        }
    }

    @objc private func openUpstream(_ sender: NSButton) {
        NSWorkspace.shared.open(AppInfo.upstreamURL)
    }

    // MARK: - Layout helpers

    private func verticalStack(spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @discardableResult
    private func addFullWidth(_ view: NSView, to stack: NSStackView) -> NSView {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return view
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func statusRow(_ title: String, _ detail: String) -> (view: NSView, detail: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [titleLabel, NSView(), detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        return (row, detailLabel)
    }
}
