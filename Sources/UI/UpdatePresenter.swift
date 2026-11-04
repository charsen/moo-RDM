import AppKit

/// 自动检查更新：成功检查后记时间，两天内不再自动查；手动检查不受限。
enum UpdateCheckStore {
    private static let lastCheckKey = "lastUpdateCheckAt"
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    /// 三天。
    static let interval: TimeInterval = 3 * 24 * 60 * 60

    static var lastCheck: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    static func isDue(now: Date = Date()) -> Bool {
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    static func recordCheck(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: lastCheckKey)
    }

    /// 同一个版本自动提示过一次就不再打扰；手动检查仍会显示。
    static func shouldNotify(version: String) -> Bool {
        (UserDefaults.standard.string(forKey: lastNotifiedKey) ?? "") != version
    }

    static func recordNotified(version: String) {
        UserDefaults.standard.set(version, forKey: lastNotifiedKey)
    }
}

/// 统一的「检查更新」入口：状态菜单、设置关于页、启动自动检查共用。
enum UpdatePresenter {

    private static var isChecking = false

    /// 手动检查：一定会给出结果弹窗。
    static func present() {
        check(automatic: false)
    }

    /// `automatic` 为 true 时只在发现新版本时打扰，已是最新/失败都静默。
    static func check(automatic: Bool) {
        guard !isChecking else { return }
        isChecking = true

        UpdateChecker.shared.check { outcome in
            DispatchQueue.main.async {
                isChecking = false

                switch outcome {
                case .upToDate:
                    UpdateCheckStore.recordCheck()
                    if !automatic { show(outcome) }

                case .available(let update):
                    UpdateCheckStore.recordCheck()
                    if automatic {
                        guard update.mandatory || UpdateCheckStore.shouldNotify(version: update.version) else {
                            return
                        }
                        UpdateCheckStore.recordNotified(version: update.version)
                    } else {
                        UpdateCheckStore.recordNotified(version: update.version)
                    }
                    show(outcome)

                case .failed:
                    // 失败不记「查过了」，下次启动还会自动重试。
                    if !automatic { show(outcome) }
                }
            }
        }
    }

    private static func show(_ outcome: UpdateCheckOutcome) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L10n.t("update.title")
        alert.alertStyle = .informational

        switch outcome {
        case .upToDate(let latest):
            alert.informativeText = L10n.t("update.upToDate", latest ?? AppInfo.version)
            alert.addButton(withTitle: L10n.t("common.ok"))
            alert.runModal()

        case .available(let update):
            alert.messageText = L10n.t("update.available", update.version)

            let notes = update.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            alert.informativeText = notes.isEmpty ? L10n.t("update.available.hint") : notes

            alert.addButton(withTitle: L10n.t("update.download"))
            if !update.mandatory {
                alert.addButton(withTitle: L10n.t("update.later"))
            }

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.url)
            }

        case .failed(let reason):
            alert.alertStyle = .warning
            alert.informativeText = reason
            alert.addButton(withTitle: L10n.t("common.ok"))
            alert.runModal()
        }
    }
}
