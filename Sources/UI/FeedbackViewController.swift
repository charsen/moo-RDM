import AppKit

/// 设置页「反馈」Tab：提交新反馈、查看对话、追加回复、30 秒刷新。
final class FeedbackViewController: NSViewController {

    private let scroll = NSScrollView()
    private let threadStack = NSStackView()
    private let input = NSTextView()
    private let submitButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var threads: [FeedbackThread] = []
    private var sending = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let slogan = NSTextField(labelWithString: L10n.t("feedback.slogan"))
        slogan.font = .systemFont(ofSize: 16, weight: .semibold)
        slogan.textColor = .labelColor
        root.addArrangedSubview(slogan)

        let intro = NSTextField(wrappingLabelWithString: L10n.t("feedback.intro"))
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        input.isRichText = false
        input.font = .systemFont(ofSize: 12)
        input.textContainerInset = NSSize(width: 6, height: 6)
        inputScroll.documentView = input
        root.addArrangedSubview(inputScroll)
        inputScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        inputScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        submitButton.title = L10n.t("feedback.submit")
        submitButton.target = self
        submitButton.action = #selector(submitPressed)
        submitButton.bezelStyle = .rounded
        let actionRow = NSStackView(views: [submitButton, NSView(), statusLabel])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        root.addArrangedSubview(actionRow)
        actionRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        let header = NSTextField(labelWithString: L10n.t("feedback.history"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let refresh = NSButton(title: L10n.t("feedback.refresh"), target: self, action: #selector(refreshPressed))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(NSView())
        headerRow.addArrangedSubview(refresh)
        root.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        threadStack.orientation = .vertical
        threadStack.alignment = .leading
        threadStack.spacing = 12
        threadStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = threadStack
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true

        root.topAnchor.constraint(equalTo: view.topAnchor, constant: 14).isActive = true
        root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14).isActive = true
        root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14).isActive = true
        root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14).isActive = true
        threadStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    func start() {
        guard timer == nil else { return }
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    deinit { timer?.invalidate() }

    private func load() {
        FeedbackClient.shared.list { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let threads):
                    self.threads = threads
                    self.render()
                case .failed(let message):
                    self.statusLabel.stringValue = message
                default:
                    break
                }
            }
        }
    }

    private func render() {
        threadStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !threads.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: L10n.t("feedback.empty"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            threadStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: threadStack.widthAnchor).isActive = true
            return
        }

        for thread in threads {
            let card = NSStackView()
            card.orientation = .vertical
            card.alignment = .leading
            card.spacing = 6

            let head = NSStackView()
            head.orientation = .horizontal
            head.alignment = .centerY
            let title = NSTextField(labelWithString: "\(thread.version) · \(thread.platform)\(thread.arch.map { " / \($0)" } ?? "")")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            let status = NSTextField(labelWithString: Self.statusText(thread.status))
            status.font = .systemFont(ofSize: 10)
            status.textColor = Self.statusColor(thread.status)
            let reply = NSButton(title: L10n.t("feedback.reply"), target: self, action: #selector(replyPressed(_:)))
            reply.bezelStyle = .rounded
            reply.controlSize = .small
            reply.identifier = NSUserInterfaceItemIdentifier(thread.id)
            head.addArrangedSubview(title)
            head.addArrangedSubview(status)
            head.addArrangedSubview(NSView())
            head.addArrangedSubview(reply)
            card.addArrangedSubview(head)
            head.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true

            for message in thread.messages {
                let label = NSTextField(wrappingLabelWithString: message.body)
                label.font = .systemFont(ofSize: 11)
                label.textColor = message.role == "admin" ? .labelColor : .secondaryLabelColor
                let prefix = message.role == "admin" ? L10n.t("feedback.roleAdmin") : L10n.t("feedback.roleUser")
                let meta = NSTextField(labelWithString: "\(prefix) · \(message.createdAt ?? "")")
                meta.font = .systemFont(ofSize: 9)
                meta.textColor = .tertiaryLabelColor
                card.addArrangedSubview(meta)
                card.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            }

            let box = NSBox()
            box.boxType = .custom
            box.borderType = .lineBorder
            box.borderWidth = 1
            box.cornerRadius = 6
            box.contentViewMargins = NSSize(width: 10, height: 8)
            box.contentView = card
            threadStack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: threadStack.widthAnchor).isActive = true
        }
    }

    @objc private func submitPressed() {
        let content = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !sending else { return }
        sending = true
        submitButton.isEnabled = false
        statusLabel.stringValue = L10n.t("feedback.sending")
        FeedbackClient.shared.submit(content: content) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                self.submitButton.isEnabled = true
                switch result {
                case .submitted:
                    self.input.string = ""
                    self.statusLabel.stringValue = L10n.t("feedback.sent")
                    self.load()
                case .failed(let message):
                    self.statusLabel.stringValue = message
                default:
                    break
                }
            }
        }
    }

    @objc private func refreshPressed() { load() }

    @objc private func replyPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let thread = threads.first(where: { $0.id == id }),
              thread.status != "closed" else { return }

        let alert = NSAlert()
        alert.messageText = L10n.t("feedback.replyTitle")
        alert.informativeText = L10n.t("feedback.replyHint")
        alert.addButton(withTitle: L10n.t("feedback.replySend"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        text.font = .systemFont(ofSize: 12)
        text.isRichText = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        alert.accessoryView = scroll

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let content = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        FeedbackClient.shared.reply(feedbackID: id, content: content) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success, .submitted:
                    self.load()
                case .failed(let message):
                    self.statusLabel.stringValue = message
                }
            }
        }
    }

    private static func statusText(_ status: String) -> String {
        switch status {
        case "open": return L10n.t("feedback.status.open")
        case "replied": return L10n.t("feedback.status.replied")
        case "resolved": return L10n.t("feedback.status.resolved")
        case "closed": return L10n.t("feedback.status.closed")
        default: return status
        }
    }

    private static func statusColor(_ status: String) -> NSColor {
        switch status {
        case "open": return .systemOrange
        case "replied": return .systemBlue
        case "resolved": return .systemGreen
        default: return .secondaryLabelColor
        }
    }
}
