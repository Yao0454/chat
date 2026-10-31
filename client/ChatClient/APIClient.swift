import Foundation
import Security

struct APIError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
    /// token 无效或过期
    var isUnauthorized: Bool { status == 401 }
}

private struct ErrorBody: Decodable {
    let error: String
}

/// 和 ChatStore 一样放在主线程：等待网络时不会卡住界面，请求体也不用跨线程传递
@MainActor
struct APIClient {
    let baseURL: URL
    var token: String?

    func get<T: Decodable>(_ path: String) async throws -> T {
        try JSON.decoder.decode(T.self, from: await send("GET", path, body: nil))
    }

    func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try JSON.decoder.decode(T.self, from: await send("POST", path, body: try JSON.encoder.encode(body)))
    }

    /// 不关心返回内容的 POST
    func post(_ path: String) async throws {
        _ = try await send("POST", path, body: nil)
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "服务器返回了无法识别的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSON.decoder.decode(ErrorBody.self, from: data))?.error
            throw APIError(message: message ?? "请求失败（HTTP \(http.statusCode)）", status: http.statusCode)
        }
        return data
    }
}

/// 把登录 token 存在钥匙串里，而不是 UserDefaults
enum Keychain {
    private static let service = "ChatClient"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
