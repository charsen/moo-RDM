import AppKit
import UniformTypeIdentifiers

// The settings window is written in plain AppKit rather than SwiftUI.
//
// SwiftUI's `@State` / `@Binding` / `@StateObject` are macros, and the
// `SwiftUIMacros` plugin ships only inside Xcode.app — it is absent from the
// Command Line Tools toolchain. Using SwiftUI here would force every user to
// install the full 10 GB Xcode, which defeats the point of this rewrite.

// MARK: - Window controller

final class SettingsWindowController: NSWindowController {

    private let content: SettingsViewController

    init(onHotKeysChanged: @escaping () -> Void) {
        content = SettingsViewController(onHotKeysChanged: onHotKeysChanged)
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

    private let onHotKeysChanged: () -> Void
    private var tabView: NSTabView!
    private var profilesStack: NSStackView!

    init(onHotKeysChanged: @escaping () -> Void) {
        self.onHotKeysChanged = onHotKeysChanged
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
        addTab(L10n.t("settings.hotkeys"), hotkeysTab())
        addTab(L10n.t("settings.profiles"), profilesTab())
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

    // MARK: - Hotkeys

    private func hotkeysTab() -> NSView {
        let stack = verticalStack()
        addFullWidth(hint(L10n.t("settings.hotkeyHint")), to: stack)
        stack.addArrangedSubview(divider())

        for action in HotKeyAction.builtIn {
            stack.addArrangedSubview(hotkeyRow(action: action, title: HotKeyAction.label(for: action)))
        }

        let profiles = ProfileStore.shared.profiles
        if !profiles.isEmpty {
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(sectionLabel(L10n.t("menu.profiles")))
            for profile in profiles {
                stack.addArrangedSubview(hotkeyRow(action: HotKeyAction.profile(profile.id),
                                                   title: profile.name))
            }
        }

        return stack
    }

    private func hotkeyRow(action: String, title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)

        let recorder = HotKeyRecorderButton(spec: Preferences.shared.hotkey(for: action)) { [weak self] spec in
            Preferences.shared.setHotkey(spec, for: action)
            self?.onHotKeysChanged()
        }

        let row = NSStackView(views: [label, NSView(), recorder])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    // MARK: - Profiles

    private func profilesTab() -> NSView {
        let stack = verticalStack()

        let nameField = NSTextField(frame: .zero)
        nameField.placeholderString = L10n.t("profile.name")
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let saveButton = NSButton(title: L10n.t("profile.save"), target: self, action: #selector(saveProfile(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let inputRow = NSStackView(views: [nameField, saveButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        addFullWidth(inputRow, to: stack)

        addFullWidth(hint(L10n.t("profile.empty")), to: stack)
        stack.addArrangedSubview(divider())

        profilesStack = verticalStack(spacing: 4)
        addFullWidth(profilesStack, to: stack)
        rebuildProfileRows()

        stack.addArrangedSubview(divider())

        let exportButton = NSButton(title: L10n.t("menu.exportProfiles"), target: self, action: #selector(exportProfiles(_:)))
        exportButton.bezelStyle = .rounded
        let importButton = NSButton(title: L10n.t("menu.importProfiles"), target: self, action: #selector(importProfiles(_:)))
        importButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [exportButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        return stack
    }

    private func rebuildProfileRows() {
        guard let profilesStack else { return }
        for subview in profilesStack.arrangedSubviews { subview.removeFromSuperview() }

        let profiles = ProfileStore.shared.profiles
        if profiles.isEmpty {
            profilesStack.addArrangedSubview(hint(L10n.t("menu.noProfiles")))
            return
        }

        for profile in profiles {
            let name = NSTextField(labelWithString: profile.name)
            name.font = .systemFont(ofSize: 12, weight: .medium)

            let summary = NSTextField(labelWithString: profile.summary)
            summary.font = .systemFont(ofSize: 10)
            summary.textColor = .secondaryLabelColor

            let text = NSStackView(views: [name, summary])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            let applyButton = NSButton(title: L10n.t("menu.apply"), target: self, action: #selector(applyProfile(_:)))
            applyButton.bezelStyle = .rounded
            applyButton.identifier = NSUserInterfaceItemIdentifier(profile.id.uuidString)

            let deleteButton = NSButton(title: L10n.t("menu.delete"), target: self, action: #selector(deleteProfile(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.identifier = NSUserInterfaceItemIdentifier(profile.id.uuidString)

            let row = NSStackView(views: [text, NSView(), applyButton, deleteButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            addFullWidth(row, to: profilesStack)
        }
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

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionLabel(L10n.t("settings.diagnostics")))

        let copyButton = NSButton(title: L10n.t("settings.diagnostics"), target: self, action: #selector(copyDiagnostics(_:)))
        copyButton.bezelStyle = .rounded
        let revealButton = NSButton(title: L10n.t("settings.revealSupport"), target: self, action: #selector(revealSupport(_:)))
        revealButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [copyButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

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

    @objc private func saveProfile(_ sender: NSButton) {
        guard let field = (sender.superview as? NSStackView)?.arrangedSubviews.first as? NSTextField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { NSSound.beep(); return }
        ProfileStore.shared.upsert(ProfileStore.shared.captureCurrentLayout(named: name))
        field.stringValue = ""
        rebuildProfileRows()
    }

    @objc private func applyProfile(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == id }) else { return }
        let report = ProfileStore.shared.apply(profile)
        if !report.warnings.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.t("profile.partial", "")
            alert.informativeText = report.warnings.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc private func deleteProfile(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        ProfileStore.shared.delete(id: id)
        rebuildProfileRows()
    }

    @objc private func exportProfiles(_ sender: NSButton) {
        guard !ProfileStore.shared.profiles.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RDM-ARM-Profiles.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ProfileStore.shared.export(to: url)
    }

    @objc private func importProfiles(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ProfileStore.shared.importProfiles(from: url)
        rebuildProfileRows()
    }

    @objc private func copyDiagnostics(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.diagnostics(), forType: .string)
        sender.title = L10n.t("settings.diagnostics.done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            sender.title = L10n.t("settings.diagnostics")
        }
    }

    @objc private func revealSupport(_ sender: NSButton) {
        NSWorkspace.shared.activateFileViewerSelecting([Preferences.supportDirectory])
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

// MARK: - Hotkey recorder

/// A button that records the next key combination pressed while active.
final class HotKeyRecorderButton: NSButton {

    private var spec: HotKeySpec?
    private let onChange: (HotKeySpec?) -> Void
    private var monitor: Any?

    init(spec: HotKeySpec?, onChange: @escaping (HotKeySpec?) -> Void) {
        self.spec = spec
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { stop() }

    @objc private func toggleRecording() {
        monitor == nil ? start() : stop()
    }

    private func start() {
        title = "…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 0x35:                        // Esc cancels
                self.stop()
            case 0x33, 0x75:                  // Delete clears
                self.spec = nil
                self.onChange(nil)
                self.stop()
            default:
                if let captured = HotKeySpec.from(event: event) {
                    self.spec = captured
                    self.onChange(captured)
                    self.stop()
                }
            }
            return nil   // never let the combination reach the app
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        updateTitle()
    }

    private func updateTitle() {
        if let spec, !spec.isEmpty {
            title = spec.display
        } else {
            title = "—"
        }
    }
}
