import Foundation

/// 匿名安装标识：首次运行生成 UUID，之后一直复用。
///
/// 存在 `UserDefaults`：macOS 删除 `.app` 不会删除 `~/Library/Preferences`，
/// 所以升级、重装后还是同一个 ID。若用户清理了偏好或换了机器，后台可以把
/// 新 ID「合并到」旧档案，不要求客户端做设备指纹。
public enum InstallIdentity {

    private static let defaultsKey = "installId"

    /// 稳定的安装标识（小写 UUID）。
    public static let id: String = {
        let defaults = UserDefaults.standard

        if let existing = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: defaultsKey)
        return value
    }()

    /// 界面上展示的短形式，完整值可复制。
    public static var shortID: String {
        String(id.prefix(8))
    }
}
