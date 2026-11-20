import Foundation
import Security

public struct FeedbackMessage: Decodable, Sendable {
    public let id: String
    public let role: String
    public let body: String
    public let createdAt: String?
}

public struct FeedbackThread: Decodable, Sendable {
    public let id: String
    public let version: String
    public let platform: String
    public let arch: String?
    public let status: String
    public let createdAt: String?
    public let lastMessageAt: String?
    public let messages: [FeedbackMessage]
}

public enum FeedbackResult {
    case success([FeedbackThread])
    case submitted(FeedbackThread)
    case failed(String)
}

/// 反馈设备身份：存在 Keychain，删除 App/重装后通常仍在。
/// 只用于同一设备找回反馈，不做跨设备承诺。
public enum FeedbackDeviceIdentity {
    private static let service = "com.mooeen.rdm.feedback-device"
    private static let account = "device-id"

    public static let id: String = {
        if let existing = read(), !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString.lowercased()
        write(value)
        return value
    }()

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// 调云端 `/api/v1/feedback`；token 由构建时注入 Info.plist，身份 = 账号（本应用暂无）或稳定设备 ID。
public final class FeedbackClient {

    public static let shared = FeedbackClient()

    private let session: URLSession
    private let baseURL: String
    private let feedbackToken: String?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
        baseURL = ProcessInfo.processInfo.environment["RDM_FEEDBACK_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["RDM_UPDATE_BASE_URL"]
            ?? "https://c.mooeen.com"

        let envToken = ProcessInfo.processInfo.environment["RDM_FEEDBACK_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistToken = (Bundle.main.object(forInfoDictionaryKey: "RDMFeedbackToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        feedbackToken = (envToken?.isEmpty == false ? envToken : plistToken)
    }

    public func list(completion: @escaping (FeedbackResult) -> Void) {
        guard var components = URLComponents(string: baseURL + "/api/v1/feedback") else {
            completion(.failed(L10n.t("feedback.error.invalid")))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "app", value: "moo-rdm"),
            URLQueryItem(name: "device_id", value: FeedbackDeviceIdentity.id),
            URLQueryItem(name: "install_id", value: InstallIdentity.id),
        ]
        guard let url = components.url else {
            completion(.failed(L10n.t("feedback.error.invalid")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("RDM-ARM/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        Self.authorize(&request, token: feedbackToken)

        session.dataTask(with: request) { data, response, error in
            completion(Self.decodeList(data: data, response: response, error: error))
        }.resume()
    }

    public func submit(content: String, completion: @escaping (FeedbackResult) -> Void) {
        send(path: "/api/v1/feedback", method: "POST", body: [
            "app": "moo-rdm",
            "version": AppInfo.version,
            "platform": "macos",
            "arch": AppInfo.architecture,
            "device_id": FeedbackDeviceIdentity.id,
            "install_id": InstallIdentity.id,
            "content": content,
        ], completion: completion)
    }

    public func reply(feedbackID: String, content: String, completion: @escaping (FeedbackResult) -> Void) {
        send(path: "/api/v1/feedback/\(feedbackID)/messages", method: "POST", body: [
            "app": "moo-rdm",
            "device_id": FeedbackDeviceIdentity.id,
            "install_id": InstallIdentity.id,
            "content": content,
        ], completion: completion)
    }

    private func send(path: String, method: String, body: [String: String], completion: @escaping (FeedbackResult) -> Void) {
        guard let url = URL(string: baseURL + path) else {
            completion(.failed(L10n.t("feedback.error.invalid")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RDM-ARM/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        Self.authorize(&request, token: feedbackToken)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, response, error in
            completion(Self.decodeSubmit(data: data, response: response, error: error))
        }.resume()
    }

    private static func authorize(_ request: inout URLRequest, token: String?) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func decodeList(data: Data?, response: URLResponse?, error: Error?) -> FeedbackResult {
        if error != nil { return .failed(L10n.t("feedback.error.network")) }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failed(L10n.t("feedback.error.invalid"))
        }
        guard http.statusCode == 200 else {
            return .failed(errorMessage(data: data) ?? L10n.t("feedback.error.server"))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(ListPayload.self, from: data) else {
            return .failed(L10n.t("feedback.error.invalid"))
        }
        return .success(payload.feedbacks)
    }

    private static func decodeSubmit(data: Data?, response: URLResponse?, error: Error?) -> FeedbackResult {
        if error != nil { return .failed(L10n.t("feedback.error.network")) }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failed(L10n.t("feedback.error.invalid"))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(errorMessage(data: data) ?? L10n.t("feedback.error.server"))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(SubmitPayload.self, from: data) else {
            return .failed(L10n.t("feedback.error.invalid"))
        }
        return .submitted(payload.feedback)
    }

    private static func errorMessage(data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private struct ListPayload: Decodable {
        let feedbacks: [FeedbackThread]
    }

    private struct SubmitPayload: Decodable {
        let feedback: FeedbackThread
    }
}
