import Foundation

/// 存在本地的聊天记录。下次启动先显示这些，只向服务端同步之后的新消息；
/// 服务器暂时连不上时也能直接进入、看到以前的消息。
struct CacheSnapshot: Codable {
    var serverURL: String
    var me: UserDTO
    var users: [UserDTO]
    var conversations: [ConversationDTO]
    var items: [Int64: [ChatItem]]
    var syncedSeq: [Int64: Int64]
    /// 会话 id → 用户 id → 读到哪里。旧缓存里没有
    var reads: [Int64: [Int64: ReadStateDTO]]?
}

/// 同一时间只有一个登录账号，所以只存一个文件；换账号或退出登录时删掉
enum MessageCache {
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ChatClient/cache.json")
    }

    static func load() -> CacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CacheSnapshot.self, from: data)
    }

    static func save(_ snapshot: CacheSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("保存本地缓存失败: \(error)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
