import FloodClient
import Foundation
import QBittorrentClient
import Security
import TorrentKit
import TransmissionClient

/// 一台下载器的配置。包含密码等敏感信息，整体存 Keychain。
struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var kind: ClientKind
    var username: String = "admin"
    var password: String = ""
    /// qB 5.2+ 的 API key。填了就不用用户名密码
    var apiKey: String = ""
    var endpoints: [Endpoint]
    var enabled: Bool = true

    var serverID: ServerID { ServerID(id) }
    var credentials: Credentials { Credentials(username: username, password: password) }

    /// 线路探测用的路径：qB 未登录返回 403，TR 返回 409，都算「下载器在」
    var probePath: String {
        switch kind {
        case .qbittorrent: "api/v2/app/version"
        case .transmission: "transmission/rpc"
        case .flood: "api/auth/verify" // 没登录时 401，也算「在」
        }
    }

    static func blank(kind: ClientKind = .qbittorrent) -> ServerConfig {
        ServerConfig(
            name: kind.displayName,
            kind: kind,
            endpoints: [Endpoint(baseURL: URL(string: exampleAddress(kind))!)]
        )
    }

    static func exampleAddress(_ kind: ClientKind) -> String { "http://192.168.1.2:\(kind.defaultPort)" }

    /// 切换类型时，地址末尾如果是原类型的默认端口就跟着换
    static func switchingPort(in url: String, from old: ClientKind, to new: ClientKind) -> String {
        let suffix = ":\(old.defaultPort)"
        return url.hasSuffix(suffix) ? url.dropLast(suffix.count) + ":\(new.defaultPort)" : url
    }

    /// 连接和各处「测试连接」都从这里建客户端
    func makeClient(_ ep: Endpoint) -> any TorrentClient {
        switch kind {
        case .qbittorrent:
            QBittorrentClient(serverID: serverID, endpoint: ep, credentials: credentials, apiKey: apiKey.isEmpty ? nil : apiKey)
        case .transmission:
            TransmissionClient(serverID: serverID, endpoint: ep, credentials: credentials)
        case .flood:
            FloodClient(serverID: serverID, endpoint: ep, credentials: credentials)
        }
    }
}

extension ServerInfo {
    /// 添加服务器时「测试连接」结果里的 tracker 状态那一项
    var trackerStatusSummary: String {
        if capabilities.contains(.trackerHealthInList) { return L("✓ Tracker status") }
        if kind == .flood { return L("✗ No reliable tracker status through Flood with this client. For cleanup, connect to the client directly.") }
        return L("✗ No tracker status (qB 5.1.x)")
    }
}

protocol ConfigStore: Sendable {
    func load() throws -> [ServerConfig]
    func save(_ configs: [ServerConfig]) throws
}

enum ConfigStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    var description: String {
        switch self {
        case .keychain(let s): L("Keychain error \(Int(s)): \(SecCopyErrorMessageString(s, nil) as String? ?? "")")
        }
    }
}

/// 默认存储：整个配置数组 JSON 编码后存成一条 Keychain 通用密码。
struct KeychainConfigStore: ConfigStore {
    let service = "dev.peerdeck.mac"
    let account = "servers"

    func load() throws -> [ServerConfig] {
        var out: CFTypeRef?
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = out as? Data else { throw ConfigStoreError.keychain(status) }
        return try JSONDecoder().decode([ServerConfig].self, from: data)
    }

    func save(_ configs: [ServerConfig]) throws {
        let data = try JSONEncoder().encode(configs)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Peerdeck Server Settings"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw ConfigStoreError.keychain(s) }
        } else if status != errSecSuccess {
            throw ConfigStoreError.keychain(status)
        }
    }
}

/// 开发和自动化验证用：明文 JSON 文件。只有设置了 TC_CONFIG_FILE 环境变量才会用。
struct FileConfigStore: ConfigStore {
    let url: URL

    func load() throws -> [ServerConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: url))
    }

    func save(_ configs: [ServerConfig]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(configs).write(to: url, options: .atomic)
    }
}
