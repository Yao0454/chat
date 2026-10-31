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

/// 选择用哪个 URLSession。
/// 系统开了 HTTP 代理（比如翻墙软件）时，URLSession 默认把所有请求都交给代理，包括局域网地址。
/// 普通请求代理还能转发，但很多代理会弄坏 WebSocket 握手，App 就一直连不上（错误 -1011）。
/// 所以连局域网里的服务器时不走代理，其他地址仍然按系统设置。
enum Sessions {
    private static let direct: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]   // 空字典 = 不用任何代理
        return URLSession(configuration: config)
    }()

    static func session(for url: URL) -> URLSession {
        isLocalNetwork(url.host()) ? direct : .shared
    }

    /// localhost、.local 域名，以及 10.x / 172.16–31.x / 192.168.x / 169.254.x 这些内网 IPv4 地址
    static func isLocalNetwork(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }
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

        let (data, response) = try await Sessions.session(for: baseURL).data(for: request)
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
