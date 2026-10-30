import AppKit
import CoreGraphics
import Foundation

/// Small window behind the menu's "Add scaled resolution…" item.
///
/// Adding a size cannot change the current mode — macOS only reads an override
/// when the display is attached — so this window never asks for a confirmation
/// or applies anything. It writes the plist, then says plainly that a reconnect
/// (or restart) is what makes the new size appear.
final class CustomResolutionWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private let display: DisplayInfo
    private var edid: EDID?

    private let displayLabel = NSTextField(labelWithString: "")
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let backingLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let entriesStack = NSStackView()
    private let installedLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private var customEntries: [ScaledResolution] = []
    private var isBusy = false

    var onClose: (() -> Void)?

    init(display: DisplayInfo) {
        self.display = display
        self.edid = DisplayEDIDReader.read(for: display.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.t("window.custom.title", display.name)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 360)
        window.center()
        super.init(window: window)

        window.delegate = self
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        widthField.becomeFirstResponder()
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        displayLabel.font = .systemFont(ofSize: 12)
        displayLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(displayLabel)

        let fields = NSStackView()
        fields.orientation = .horizontal
        fields.alignment = .firstBaseline
        fields.spacing = 8

        let widthLabel = NSTextField(labelWithString: L10n.t("window.custom.width"))
        widthLabel.font = .systemFont(ofSize: 12)
        widthField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        widthField.alignment = .right
        widthField.delegate = self
        widthField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor

        let heightLabel = NSTextField(labelWithString: L10n.t("window.custom.height"))
        heightLabel.font = .systemFont(ofSize: 12)
        heightField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        heightField.alignment = .right
        heightField.delegate = self
        heightField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        for view in [widthLabel, widthField, times, heightLabel, heightField] {
            fields.addArrangedSubview(view)
        }
        root.addArrangedSubview(fields)

        backingLabel.font = .systemFont(ofSize: 11)
        backingLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(backingLabel)

        addButton.target = self
        addButton.action = #selector(addResolution(_:))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        root.addArrangedSubview(addButton)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        installedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        installedLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(installedLabel)

        entriesStack.orientation = .vertical
        entriesStack.alignment = .leading
        entriesStack.spacing = 6
        root.addArrangedSubview(entriesStack)
        entriesStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        root.addArrangedSubview(statusLabel)

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.preferredMaxLayoutWidth = 430
        root.addArrangedSubview(noteLabel)
        noteLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        closeButton.title = L10n.t("window.custom.close")
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), closeButton])
        footer.orientation = .horizontal
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = container

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        window.contentView = scroll
    }

    // MARK: - State

    private func refresh() {
        edid = DisplayEDIDReader.read(for: display.id)
        addButton.title = L10n.t("window.custom.add")
        installedLabel.stringValue = L10n.t("window.custom.installed")
        noteLabel.stringValue = L10n.t("window.custom.note")

        if let native = display.nativePixelSize {
            displayLabel.stringValue = L10n.t("window.custom.display",
                                              display.name, native.description)
        } else {
            displayLabel.stringValue = display.name
        }

        customEntries = edid.map { DisplayOverrideInstaller.scaledResolutions(for: $0) } ?? []
        rebuildEntries()
        validate()
    }

    private func rebuildEntries() {
        for view in entriesStack.arrangedSubviews {
            entriesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !customEntries.isEmpty else {
            let empty = NSTextField(labelWithString: L10n.t("window.custom.none"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            entriesStack.addArrangedSubview(empty)
            return
        }

        for (index, resolution) in customEntries.enumerated() {
            let label = NSTextField(labelWithString: resolution.label)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            let remove = NSButton(title: L10n.t("window.custom.remove"), target: self,
                                  action: #selector(removeResolution(_:)))
            remove.bezelStyle = .inline
            remove.tag = index
            remove.isEnabled = !isBusy

            let row = NSStackView(views: [label, NSView(), remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            entriesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: entriesStack.widthAnchor).isActive = true
        }
    }

    private func validate() {
        guard let edid else {
            statusLabel.stringValue = L10n.t("error.timingNoEDID")
            addButton.isEnabled = false
            backingLabel.stringValue = ""
            return
        }

        let width = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let height = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0

        guard width > 0, height > 0 else {
            backingLabel.stringValue = ""
            statusLabel.stringValue = ""
            addButton.isEnabled = false
            return
        }

        backingLabel.stringValue = L10n.t("window.custom.backing", width * 2, height * 2)

        switch ScaleResolutionStore.validate(pointWidth: width, pointHeight: height,
                                             on: display, edid: edid,
                                             checkOffered: false) {
        case .success:
            statusLabel.stringValue = ""
            addButton.isEnabled = !isBusy
        case .failure(let failure):
            statusLabel.stringValue = failure.description
            addButton.isEnabled = false
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        widthField.isEnabled = !busy
        heightField.isEnabled = !busy
        closeButton.isEnabled = !busy
        addButton.title = busy ? L10n.t("window.custom.busy") : L10n.t("window.custom.add")
        for view in entriesStack.arrangedSubviews {
            (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }
                .forEach { $0.isEnabled = !busy }
        }
        if !busy { validate() } else { addButton.isEnabled = false }
    }

    // MARK: - Actions

    func controlTextDidChange(_ notification: Notification) {
        validate()
    }

    @objc private func addResolution(_ sender: Any) {
        guard !isBusy, let edid else { return }
        let width = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let height = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0

        let resolution: ScaledResolution
        switch ScaleResolutionStore.validate(pointWidth: width, pointHeight: height,
                                             on: display, edid: edid) {
        case .success(let value):
            resolution = value
        case .failure(let failure):
            statusLabel.stringValue = failure.description
            return
        }

        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DisplayOverrideInstaller.installScaledResolutions([resolution], for: edid)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setBusy(false)
                    for field in [self.widthField, self.heightField] { field.stringValue = "" }
                    self.refresh()
                    self.showResult(title: L10n.t("window.custom.written"),
                                    text: L10n.t("window.custom.written.hint", resolution.label))
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setBusy(false)
                    self.showResult(title: AppInfo.name, text: "\(error)")
                }
            }
        }
    }

    @objc private func removeResolution(_ sender: NSButton) {
        guard !isBusy, let edid, sender.tag >= 0, sender.tag < customEntries.count else { return }
        let resolution = customEntries[sender.tag]

        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DisplayOverrideInstaller.removeScaledResolutions([resolution], for: edid)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setBusy(false)
                    self.refresh()
                    self.showResult(title: L10n.t("window.custom.removed"),
                                    text: L10n.t("window.custom.removed.hint", resolution.label))
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setBusy(false)
                    self.showResult(title: AppInfo.name, text: "\(error)")
                }
            }
        }
    }

    @objc private func closeWindow(_ sender: Any) {
        window?.close()
    }

    private func showResult(title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L10n.t("common.ok"))
        if let window { alert.beginSheetModal(for: window) }
    }

    func windowWillClose(_ notification: Notification) {
        isBusy = false
        // Let the close finish before the owner drops its reference: the
        // controller is what is running this method.
        let handler = onClose
        DispatchQueue.main.async { handler?() }
    }
}
