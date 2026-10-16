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
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("settings.title")
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Tab host

final class SettingsViewController: NSViewController {

    private var tabView: NSTabView!

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView(frame: view.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder
        view.addSubview(tabView)

        addTab(L10n.t("settings.general"), generalTab())
        addTab(L10n.t("settings.advanced"), advancedTab())
        addTab(L10n.t("settings.about"), aboutTab())
    }

    private func addTab(_ title: String, _ content: NSView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title

        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
        ])

        item.view = container
        tabView.addTabViewItem(item)
    }

    // MARK: - General

    private func generalTab() -> NSView {
        let stack = verticalStack()

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.language")))

        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: Preferences.shared.language) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(languagePopup)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("menu.resolution")))
        stack.addArrangedSubview(checkbox(L10n.t("settings.showUnusable"),
                                          on: Preferences.shared.showUnusableModes,
                                          action: #selector(toggleShowUnusable(_:))))
        addFullWidth(hint(L10n.t("settings.showUnusable.hint")), to: stack)

        stack.addArrangedSubview(checkbox(L10n.t("settings.hiDPIOnly"),
                                          on: Preferences.shared.hiDPIOnly,
                                          action: #selector(toggleHiDPIOnly(_:))))
        addFullWidth(hint(L10n.t("settings.hiDPIOnly.hint")), to: stack)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.rememberPerDisplay")))
        stack.addArrangedSubview(checkbox(L10n.t("settings.rememberPerDisplay"),
                                          on: Preferences.shared.rememberPerDisplay,
                                          action: #selector(toggleRemember(_:))))
        addFullWidth(hint(L10n.t("settings.rememberPerDisplay.hint")), to: stack)

        stack.addArrangedSubview(checkbox(L10n.t("settings.restoreOnWake"),
                                          on: Preferences.shared.restoreOnWake,
                                          action: #selector(toggleRestoreOnWake(_:))))

        return stack
    }

    // MARK: - Advanced

    private func advancedTab() -> NSView {
        let stack = verticalStack()

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.permanent")))
        stack.addArrangedSubview(checkbox(L10n.t("settings.permanent"),
                                          on: Preferences.shared.permanentChanges,
                                          action: #selector(togglePermanent(_:))))
        addFullWidth(hint(L10n.t("settings.permanent.hint")), to: stack)

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.optionalModule")))
        stack.addArrangedSubview(checkbox(L10n.t("settings.optionalModule"),
                                          on: Preferences.shared.enableOptionalModule,
                                          action: #selector(toggleOptionalModule(_:))))
        addFullWidth(hint(L10n.t("settings.optionalModule.hint")), to: stack)

        stack.addArrangedSubview(statusRow(L10n.t("menu.rotation"), rotationStatus()))
        stack.addArrangedSubview(statusRow(L10n.t("menu.brightness"), brightnessStatus()))
        stack.addArrangedSubview(statusRow(L10n.t("settings.hiddenHiDPI"), hiddenHiDPIStatus()))

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.diagnostics")))

        let copyButton = NSButton(title: L10n.t("settings.diagnostics"), target: self, action: #selector(copyDiagnostics(_:)))
        copyButton.bezelStyle = .rounded
        stack.addArrangedSubview(copyButton)

        let diagnostics = NSTextField(wrappingLabelWithString: AppInfo.diagnostics())
        diagnostics.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        diagnostics.textColor = .secondaryLabelColor
        diagnostics.isSelectable = true
        addFullWidth(diagnostics, to: stack)

        return stack
    }

    private func rotationStatus() -> String {
        guard DisplayRotationController.isSymbolPresent else { return "unavailable on this system" }
        return Preferences.shared.enableOptionalModule ? "available" : "disabled"
    }

    private func brightnessStatus() -> String {
        let count = DisplayManager.allDisplays()
            .filter { DisplayBrightnessController.canChangeBrightness(of: $0.id) }
            .count
        return count > 0 ? "available on \(count) display(s)" : "unavailable on this system"
    }

    private func hiddenHiDPIStatus() -> String {
        guard PrivateModeTable.isSymbolPresent else { return "unavailable on this system" }
        guard Preferences.shared.enableOptionalModule else { return "disabled" }
        let count = DisplayManager.allDisplays()
            .flatMap { DisplayManager.allModes(for: $0.id) }
            .filter(\.isPrivate)
            .count
        return count > 0 ? "\(count) extra mode(s) offered" : "none offered"
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

    private func statusRow(_ title: String, _ detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [titleLabel, NSView(), detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }
}
