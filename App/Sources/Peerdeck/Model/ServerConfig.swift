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
/// 不指定 access group 时用 entitlements 里的第一个组，iOS 上就是 app 和分享扩展共用的 `<Team ID>.dev.peerdeck.shared`。
struct KeychainConfigStore: ConfigStore {
    let service = "dev.peerdeck.mac"
    let account = "servers"
    /// 只有调试时指定（把配置写进别的组，模拟旧版本存的）
    var accessGroup: String? = nil

    static let label = "Peerdeck Server Settings"

    var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    func load() throws -> [ServerConfig] {
        var out: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = out as? Data else { throw ConfigStoreError.keychain(status) }
        return try JSONDecoder().decode([ServerConfig].self, from: data)
    }

    func save(_ configs: [ServerConfig]) throws {
        let data = try JSONEncoder().encode(configs)
        let q = query
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = Self.label
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw ConfigStoreError.keychain(s) }
        } else if status != errSecSuccess {
            throw ConfigStoreError.keychain(status)
        }
    }
}

#if os(iOS)
extension KeychainConfigStore {
    /// 配置不在共享组里时，挪进默认组（也就是共享组），分享扩展才读得到。只在 app 里、读配置之前调用。
    /// 什么时候会这样：之前装的版本签名时没带共享组。比如 TrollStore 装未签名的 ipa，配置存在它补的 TROLLTROLL.* 组里；
    /// 换成带共享组的 tipa 以后，旧配置还在原来的组里（tipa 给 app 留着这个组，才读得到它）。
    func moveToDefaultGroup() {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        func group(_ item: [String: Any]) -> String { item[kSecAttrAccessGroup as String] as? String ?? "" }
        guard !items.contains(where: { group($0).hasSuffix(".dev.peerdeck.shared") }),
              let old = items.first, let data = old[kSecValueData as String] as? Data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = Self.label
        add[kSecReturnAttributes as String] = true
        var added: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &added)
        // errSecDuplicateItem：默认组就是旧组，这次安装也没有共享组，没什么可挪的
        guard status == errSecSuccess else {
            if status != errSecDuplicateItem { Log.info("挪服务器配置失败：\(status)") }
            return
        }
        var del = query
        del[kSecAttrAccessGroup as String] = group(old)
        let s = SecItemDelete(del as CFDictionary)
        Log.info("服务器配置从钥匙串组 \(group(old)) 挪到了 \(group(added as? [String: Any] ?? [:]))，删旧的：\(s)")
    }
}
#endif

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
