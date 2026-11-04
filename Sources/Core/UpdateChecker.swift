import Foundation

/// 新版本信息，来自云端检查更新接口。
public struct AvailableUpdate {
    public let version: String
    public let notes: String?
    public let url: URL
    public let mandatory: Bool

    public init(version: String, notes: String?, url: URL, mandatory: Bool) {
        self.version = version
        self.notes = notes
        self.url = url
        self.mandatory = mandatory
    }
}

public enum UpdateCheckOutcome {
    case upToDate(latest: String?)
    case available(AvailableUpdate)
    case failed(String)
}

/// 调云端 `/api/v1/updates/check`。
///
/// 只有直装版（DMG）才走这里；App Store 版不能自建更新通道。
public final class UpdateChecker {

    public static let shared = UpdateChecker()

    private let session: URLSession
    private let baseURL: String

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)

        // 本地联调可指向 http://127.0.0.1:8000；生产默认走云端。
        baseURL = ProcessInfo.processInfo.environment["RDM_UPDATE_BASE_URL"] ?? "https://c.mooeen.com"
    }

    /// 完成回调在 URLSession 的后台队列执行；UI 调用方自行切回主线程。
    public func check(completion: @escaping (UpdateCheckOutcome) -> Void) {
        guard var components = URLComponents(string: baseURL + "/api/v1/updates/check") else {
            completion(.failed(L10n.t("update.error.invalid")))
            return
        }

        components.queryItems = [
            URLQueryItem(name: "app", value: "moo-rdm"),
            URLQueryItem(name: "current_version", value: AppInfo.version),
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "arch", value: AppInfo.architecture),
            URLQueryItem(name: "channel", value: "stable"),
            URLQueryItem(name: "install_id", value: InstallIdentity.id),
        ]

        guard let url = components.url else {
            completion(.failed(L10n.t("update.error.invalid")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RDM-ARM/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            completion(Self.outcome(data: data, response: response, error: error))
        }.resume()
    }

    private static func outcome(data: Data?, response: URLResponse?, error: Error?) -> UpdateCheckOutcome {
        if error != nil {
            return .failed(L10n.t("update.error.network"))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed(L10n.t("update.error.invalid"))
        }

        switch http.statusCode {
        case 429:
            return .failed(L10n.t("update.error.rateLimited"))
        case 404:
            return .failed(L10n.t("update.error.notFound"))
        default:
            break
        }

        guard let data, !data.isEmpty else {
            return .failed(L10n.t("update.error.invalid"))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            return .failed(L10n.t("update.error.invalid"))
        }

        if !payload.ok {
            return .failed(payload.error?.message ?? L10n.t("update.error.invalid"))
        }

        if payload.updateAvailable, let latest = payload.latest {
            let target = payload.action == "open_store" ? payload.storeUrl : payload.download?.url
            guard let target, let url = URL(string: target) else {
                return .failed(L10n.t("update.error.noDownload"))
            }

            return .available(AvailableUpdate(
                version: latest.version,
                notes: latest.notes,
                url: url,
                mandatory: payload.mandatory
            ))
        }

        if let reason = payload.reason, !reason.isEmpty, reason != "ahead_of_latest" {
            return .failed(reasonText(reason))
        }

        return .upToDate(latest: payload.latest?.version)
    }

    private static func reasonText(_ reason: String) -> String {
        switch reason {
        case "no_package_for_platform":
            return L10n.t("update.reason.noPackage")
        case "arch_required":
            return L10n.t("update.reason.archRequired")
        case "restricted":
            return L10n.t("update.reason.restricted")
        default:
            return reason
        }
    }

    // MARK: - Wire format

    private struct Payload: Decodable {
        struct Latest: Decodable {
            let version: String
            let notes: String?
        }

        struct Download: Decodable {
            let url: String
        }

        struct APIError: Decodable {
            let message: String?
        }

        let ok: Bool
        let updateAvailable: Bool
        let mandatory: Bool
        let action: String
        let reason: String?
        let latest: Latest?
        let download: Download?
        let storeUrl: String?
        let error: APIError?
    }
}
