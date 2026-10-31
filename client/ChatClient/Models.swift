import Foundation

// MARK: - 服务端数据

struct UserDTO: Codable, Identifiable, Hashable {
    let id: Int64
    let username: String
}

struct AuthResponse: Decodable {
    let token: String
    let user: UserDTO
}

struct ConversationDTO: Codable, Identifiable, Hashable {
    let id: Int64
    let kind: String
    let title: String?
    let lastSeq: Int64
    let members: [UserDTO]
}

struct MessageDTO: Codable, Hashable {
    let id: Int64
    let conversationId: Int64
    let seq: Int64
    let senderId: Int64
    let clientId: String
    let body: String
    let createdAt: Int64 // 毫秒时间戳
}

// MARK: - 请求体

struct LoginBody: Encodable {
    let username: String
    let password: String
}

struct RegisterBody: Encodable {
    let inviteCode: String
    let username: String
    let password: String
}

struct OpenDirectBody: Encodable {
    let userId: Int64
}

// MARK: - WebSocket 协议

struct SendCommand: Encodable {
    let type = "send"
    let clientId: String
    let conversationId: Int64
    let body: String
}

struct SyncCommand: Encodable {
    let type = "sync"
    let conversationId: Int64
    let afterSeq: Int64
}

/// 语音通话：发起
struct CallInviteCommand: Encodable {
    let type = "call_invite"
    let callId: String
    let conversationId: Int64
}

/// 语音通话：接听（call_accept）或挂断/拒绝/取消（call_hangup）
struct CallCommand: Encodable {
    let type: String
    let callId: String
}

enum ServerEvent: Decodable {
    case ack(clientId: String, message: MessageDTO)
    case message(MessageDTO)
    case history(conversationId: Int64, messages: [MessageDTO], hasMore: Bool)
    case error(clientId: String?, error: String)
    case callIncoming(callId: String, conversationId: Int64, from: UserDTO)
    case callAccepted(callId: String)
    case callEnded(callId: String, reason: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, clientId, message, conversationId, messages, hasMore, error, callId, from, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "ack":
            self = .ack(
                clientId: try c.decode(String.self, forKey: .clientId),
                message: try c.decode(MessageDTO.self, forKey: .message)
            )
        case "message":
            self = .message(try c.decode(MessageDTO.self, forKey: .message))
        case "history":
            self = .history(
                conversationId: try c.decode(Int64.self, forKey: .conversationId),
                messages: try c.decode([MessageDTO].self, forKey: .messages),
                hasMore: try c.decode(Bool.self, forKey: .hasMore)
            )
        case "error":
            self = .error(
                clientId: try c.decodeIfPresent(String.self, forKey: .clientId),
                error: try c.decode(String.self, forKey: .error)
            )
        case "call_incoming":
            self = .callIncoming(
                callId: try c.decode(String.self, forKey: .callId),
                conversationId: try c.decode(Int64.self, forKey: .conversationId),
                from: try c.decode(UserDTO.self, forKey: .from)
            )
        case "call_accepted":
            self = .callAccepted(callId: try c.decode(String.self, forKey: .callId))
        case "call_ended":
            self = .callEnded(
                callId: try c.decode(String.self, forKey: .callId),
                reason: try c.decode(String.self, forKey: .reason)
            )
        default:
            self = .unknown
        }
    }
}

// MARK: - 界面上显示的消息

struct ChatItem: Identifiable, Hashable, Codable {
    enum Status: Hashable, Codable {
        case pending          // 已发出，等服务端确认
        case sent             // 服务端已保存
        case failed(String)   // 服务端拒绝，可以重试
    }

    let clientId: String
    var id: String { clientId }
    var seq: Int64?
    let senderId: Int64
    let body: String
    var createdAt: Date
    var status: Status
}

extension ChatItem {
    init(_ m: MessageDTO) {
        self.init(
            clientId: m.clientId,
            seq: m.seq,
            senderId: m.senderId,
            body: m.body,
            createdAt: Date(timeIntervalSince1970: Double(m.createdAt) / 1000),
            status: .sent
        )
    }
}

// MARK: - JSON 编解码（服务端用 snake_case）

enum JSON {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
