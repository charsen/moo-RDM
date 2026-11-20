import AppKit

/// 设置页「更新」：版本信息、检查状态、更新说明、下载入口和自动检查说明。
final class UpdateSettingsViewController: NSViewController {

    private let versionLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private let lastCheckLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "", target: nil, action: nil)
    private let downloadButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var latest: AvailableUpdate?
    private var checking = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let card = NSBox()
        card.boxType = .custom
        card.borderType = .noBorder
        card.borderWidth = 0
        card.cornerRadius = 10
        card.contentViewMargins = NSSize(width: 18, height: 16)
        root.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        card.contentView = cardStack

        let appName = NSTextField(labelWithString: "RDM-ARM")
        appName.font = .systemFont(ofSize: 22, weight: .semibold)
        cardStack.addArrangedSubview(appName)

        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        cardStack.addArrangedSubview(versionLabel)

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .tertiaryLabelColor
        cardStack.addArrangedSubview(metaLabel)

        let divider = NSBox()
        divider.boxType = .separator
        cardStack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        cardStack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        notesLabel.font = .systemFont(ofSize: 11)
        notesLabel.textColor = .secondaryLabelColor
        notesLabel.isHidden = true
        cardStack.addArrangedSubview(notesLabel)
        notesLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        checkButton.title = L10n.t("update.check")
        checkButton.target = self
        checkButton.action = #selector(checkPressed)
        checkButton.bezelStyle = .rounded
        downloadButton.title = L10n.t("update.download")
        downloadButton.target = self
        downloadButton.action = #selector(downloadPressed)
        downloadButton.bezelStyle = .rounded
        downloadButton.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let actions = NSStackView(views: [checkButton, spinner, downloadButton, NSView()])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        cardStack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        lastCheckLabel.font = .systemFont(ofSize: 10)
        lastCheckLabel.textColor = .tertiaryLabelColor
        cardStack.addArrangedSubview(lastCheckLabel)

        let hint = NSTextField(wrappingLabelWithString: L10n.t("update.autoHint"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        root.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16).isActive = true
        root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18).isActive = true
        root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18).isActive = true

        refresh()
    }

    func start() {
        refresh()
    }

    private func refresh() {
        versionLabel.stringValue = L10n.t("about.version", AppInfo.version)
        metaLabel.stringValue = "macOS · \(AppInfo.architecture) · build \(AppInfo.build)"

        if let last = UpdateCheckStore.lastCheck {
            lastCheckLabel.stringValue = L10n.t("update.lastChecked", Self.dateFormatter.string(from: last))
        } else {
            lastCheckLabel.stringValue = L10n.t("update.neverChecked")
        }

        guard !checking else { return }
        if let latest {
            statusLabel.stringValue = L10n.t("update.available", latest.version)
            statusLabel.textColor = .labelColor
            notesLabel.stringValue = latest.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.t("update.available.hint")
            notesLabel.isHidden = notesLabel.stringValue.isEmpty
            downloadButton.isHidden = false
            downloadButton.title = L10n.t("update.download")
        } else {
            statusLabel.stringValue = L10n.t("update.idle")
            statusLabel.textColor = .secondaryLabelColor
            notesLabel.isHidden = true
            downloadButton.isHidden = true
        }
    }

    @objc private func checkPressed() {
        guard !checking else { return }
        checking = true
        checkButton.isEnabled = false
        downloadButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = L10n.t("update.checking")
        statusLabel.textColor = .secondaryLabelColor
        notesLabel.isHidden = true

        UpdateChecker.shared.check { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.checkButton.isEnabled = true
                self.downloadButton.isEnabled = true
                self.spinner.stopAnimation(nil)

                switch outcome {
                case .upToDate(let latestVersion):
                    UpdateCheckStore.recordCheck()
                    self.latest = nil
                    self.statusLabel.stringValue = L10n.t("update.upToDate", latestVersion ?? AppInfo.version)
                    self.statusLabel.textColor = .secondaryLabelColor
                    self.notesLabel.isHidden = true
                    self.downloadButton.isHidden = true
                    self.refreshLastCheck()

                case .available(let update):
                    UpdateCheckStore.recordCheck()
                    self.latest = update
                    self.statusLabel.stringValue = L10n.t("update.available", update.version)
                    self.statusLabel.textColor = .labelColor
                    self.notesLabel.stringValue = update.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.t("update.available.hint")
                    self.notesLabel.isHidden = self.notesLabel.stringValue.isEmpty
                    self.downloadButton.isHidden = false
                    self.refreshLastCheck()

                case .failed(let reason):
                    self.latest = nil
                    self.statusLabel.stringValue = reason
                    self.statusLabel.textColor = .systemRed
                    self.notesLabel.isHidden = true
                    self.downloadButton.isHidden = true
                }
            }
        }
    }

    private func refreshLastCheck() {
        if let last = UpdateCheckStore.lastCheck {
            lastCheckLabel.stringValue = L10n.t("update.lastChecked", Self.dateFormatter.string(from: last))
        }
    }

    @objc private func downloadPressed() {
        guard let latest else { return }
        NSWorkspace.shared.open(latest.url)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
