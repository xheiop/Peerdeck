import CommonCrypto
import CryptoKit
import Foundation
import TorrentKit

/// 配置的导出和导入，用来换设备、在 Mac 和 iPhone 之间搬配置。
/// 导出：服务器、站点表、「疑似未注册」关键词、「长时间连不上」的阈值。刷新间隔、列、菜单栏、通知这些各台设备自己的偏好不导出。
/// 不带密码时，密码、API key、反代 Basic Auth 的密码和附加请求头的值都清空；
/// 带密码时整份内容用口令加密（PBKDF2-SHA256 派生密钥，AES-GCM），文件里只有盐和密文。
enum ConfigBackup {
    static let format = "peerdeck-config"
    static let version = 1
    static let rounds = 600_000
    static let minPassphrase = 8

    struct Content: Codable, Sendable, Equatable {
        var servers: [ServerConfig]
        var sites: [SiteConfig]
        var unregisteredKeywords: [String]
        var longUnreachableHours: Int
        /// false：密码这些已经清空，导入时保留本机同一台服务器的
        var includesSecrets: Bool
        /// 影视信息开关。旧版本导出的文件里没有（nil），导入时不动本机的
        var mediaInfo: Bool? = nil
        /// 用户自己填的 TMDB 密钥。只在带密码（加密）的导出里有
        var tmdbKey: String? = nil
    }

    struct Sealed: Codable {
        var kdf = "pbkdf2-sha256"
        var rounds: Int
        var salt: Data
        /// AES-GCM 的 nonce + 密文 + tag
        var box: Data
    }

    struct File: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var content: Content?
        var encrypted: Sealed?
    }

    enum Failure: LocalizedError, Equatable {
        case notBackup, newerVersion, needsPassphrase, wrongPassphrase, passphraseTooShort

        var errorDescription: String? {
            switch self {
            case .notBackup: L("This file isn’t a Peerdeck settings export.")
            case .newerVersion: L("This file was exported by a newer version of Peerdeck. Update Peerdeck and try again.")
            case .needsPassphrase: L("This file is encrypted. Enter its password.")
            case .wrongPassphrase: L("Wrong password.")
            case .passphraseTooShort: L("The password needs at least \(ConfigBackup.minPassphrase) characters.")
            }
        }
    }

    // MARK: - 写

    /// passphrase 为 nil 时不带密码、不加密
    static func export(_ content: Content, passphrase: String?, date: Date = .now) throws -> Data {
        var file = File(format: format, version: version, exportedAt: date)
        if let passphrase {
            guard passphrase.count >= minPassphrase else { throw Failure.passphraseTooShort }
            var c = content
            c.includesSecrets = true
            let salt = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
            let key = try key(passphrase, salt: salt, rounds: rounds)
            let box = try AES.GCM.seal(try encoder.encode(c), using: key, authenticating: aad).combined!
            file.encrypted = Sealed(rounds: rounds, salt: salt, box: box)
        } else {
            var c = content
            c.servers = c.servers.map(stripped)
            c.tmdbKey = nil
            c.includesSecrets = false
            file.content = c
        }
        return try encoder.encode(file)
    }

    // MARK: - 读

    /// 加密的文件没给口令时抛 needsPassphrase，调用方问用户要了再读一次
    static func read(_ data: Data, passphrase: String?) throws -> Content {
        guard let file = try? decoder.decode(File.self, from: data), file.format == format else { throw Failure.notBackup }
        guard file.version <= version else { throw Failure.newerVersion }
        if let content = file.content { return content }
        guard let sealed = file.encrypted, sealed.kdf == "pbkdf2-sha256", (1...10_000_000).contains(sealed.rounds), sealed.salt.count >= 16
        else { throw Failure.notBackup }
        guard let passphrase, !passphrase.isEmpty else { throw Failure.needsPassphrase }
        let key = try key(passphrase, salt: sealed.salt, rounds: sealed.rounds)
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: key, authenticating: aad)
        } catch {
            throw Failure.wrongPassphrase
        }
        guard let content = try? decoder.decode(Content.self, from: plain) else { throw Failure.notBackup }
        return content
    }

    // MARK: - 合并

    struct Summary: Equatable {
        var addedServers = 0, updatedServers = 0
        var addedSites = 0, updatedSites = 0
        var addedKeywords = 0
        var includesSecrets = true
        /// 影视信息开关会变成这个值（nil：不变）
        var mediaInfo: Bool?
        /// 会换成文件里的 TMDB 密钥
        var tmdbKeyChanged = false
        var isEmpty: Bool { addedServers + updatedServers + addedSites + updatedSites + addedKeywords == 0 && mediaInfo == nil && !tmdbKeyChanged }
    }

    /// 合并进本机：同一个 id 的服务器和站点用文件里的，没有的加上，本机多出来的不删。
    /// 关键词取并集，阈值用文件里的。文件不带密码时，同一台服务器保留本机的密码。
    /// 影视信息开关用文件里的；TMDB 密钥只在文件里有（带密码导出）时换成文件里的，返回的 tmdbKey 为 nil 表示不变
    static func merge(_ content: Content, into servers: [ServerConfig], prefs: AppPrefs, tmdbKey: String = "") -> (servers: [ServerConfig], prefs: AppPrefs, tmdbKey: String?, summary: Summary) {
        var summary = Summary(includesSecrets: content.includesSecrets)
        var result = servers
        for var incoming in content.servers {
            if let i = result.firstIndex(where: { $0.id == incoming.id }) {
                if !content.includesSecrets { incoming = keepingSecrets(incoming, from: result[i]) }
                if result[i] != incoming { result[i] = incoming; summary.updatedServers += 1 }
            } else {
                result.append(incoming)
                summary.addedServers += 1
            }
        }
        var p = prefs
        for site in content.sites {
            if let i = p.sites.firstIndex(where: { $0.id == site.id }) {
                if p.sites[i] != site { p.sites[i] = site; summary.updatedSites += 1 }
            } else {
                p.sites.append(site)
                summary.addedSites += 1
            }
        }
        for k in content.unregisteredKeywords where !p.unregisteredKeywords.contains(k) {
            p.unregisteredKeywords.append(k)
            summary.addedKeywords += 1
        }
        p.longUnreachableHours = content.longUnreachableHours
        if let m = content.mediaInfo, m != p.mediaInfo {
            p.mediaInfo = m
            summary.mediaInfo = m
        }
        var newKey: String?
        if content.includesSecrets, let k = content.tmdbKey, !k.isEmpty, k != tmdbKey {
            newKey = k
            summary.tmdbKeyChanged = true
        }
        return (result, p, newKey, summary)
    }

    // MARK: - 内部

    static func stripped(_ server: ServerConfig) -> ServerConfig {
        var c = server
        c.password = ""
        c.apiKey = ""
        for i in c.endpoints.indices {
            c.endpoints[i].proxyAuth?.password = ""
            c.endpoints[i].headers = c.endpoints[i].headers.mapValues { _ in "" }
        }
        return c
    }

    /// 文件里清空了的密码这些，用本机同一台服务器的补回去（线路按地址对应）
    static func keepingSecrets(_ incoming: ServerConfig, from local: ServerConfig) -> ServerConfig {
        var c = incoming
        if c.password.isEmpty { c.password = local.password }
        if c.apiKey.isEmpty { c.apiKey = local.apiKey }
        for i in c.endpoints.indices {
            guard let old = local.endpoints.first(where: { $0.baseURL == c.endpoints[i].baseURL }) else { continue }
            if let auth = c.endpoints[i].proxyAuth, auth.password.isEmpty, let o = old.proxyAuth, o.username == auth.username {
                c.endpoints[i].proxyAuth?.password = o.password
            }
            for (k, v) in c.endpoints[i].headers where v.isEmpty {
                if let ov = old.headers[k] { c.endpoints[i].headers[k] = ov }
            }
        }
        return c
    }

    private static let aad = Data("\(format):\(version)".utf8)

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 口令先做 Unicode 规范化：同一个口令在 Mac 和 iPhone 上输入，组合字符的编码可能不一样
    static func key(_ passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = pw.withUnsafeBufferPointer { p in
            salt.withUnsafeBytes { s in
                p.withMemoryRebound(to: CChar.self) { pc in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), pc.baseAddress, pw.count,
                        s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw Failure.notBackup }
        return SymmetricKey(data: out)
    }
}

extension AppModel {
    /// 本机要导出的内容（带密码；不带密码的版本由 ConfigBackup.export 清空）
    var backupContent: ConfigBackup.Content {
        ConfigBackup.Content(
            servers: servers.map(\.config),
            sites: prefs.sites,
            unregisteredKeywords: prefs.unregisteredKeywords,
            longUnreachableHours: prefs.longUnreachableHours,
            includesSecrets: true,
            mediaInfo: prefs.mediaInfo,
            tmdbKey: tmdbKey.isEmpty ? nil : tmdbKey)
    }

    func importPreview(_ content: ConfigBackup.Content) -> ConfigBackup.Summary {
        ConfigBackup.merge(content, into: servers.map(\.config), prefs: prefs, tmdbKey: tmdbKey).summary
    }

    func applyImport(_ content: ConfigBackup.Content) {
        let merged = ConfigBackup.merge(content, into: servers.map(\.config), prefs: prefs, tmdbKey: tmdbKey)
        let current = Dictionary(servers.map { ($0.id, $0.config) }, uniquingKeysWith: { a, _ in a })
        for c in merged.servers where current[c.id] != c { upsert(c) }
        prefs = merged.prefs
        if let k = merged.tmdbKey {
            TMDBKeyStore.save(k)
            tmdbKey = k
        }
        Log.info("导入配置：\(merged.summary)")
    }
}
