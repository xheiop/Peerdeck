import Foundation
import Security

/// 用户自己填的 TMDB 密钥，存在 Keychain（和服务器配置分开的一条）。
/// 放在 Model 里而不是 Media 里：配置导出导入也要读写它，而 Model 会编进分享扩展（扩展不链接 MediaKit）。
/// 调试（TC_CONFIG_FILE）时不碰 Keychain：读环境变量 TMDB_API_KEY，写只留在内存里
enum TMDBKeyStore {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.peerdeck.tmdb",
        kSecAttrAccount as String: "api-key",
    ] }

    private static var debug: Bool { ProcessInfo.processInfo.environment["TC_CONFIG_FILE"] != nil }

    static func load() -> String {
        if debug { return ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? "" }
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 空字符串表示删掉
    static func save(_ key: String) {
        guard !debug else { return }
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Peerdeck TMDB API Key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.info("保存 TMDB 密钥失败：\(status)") }
    }
}
