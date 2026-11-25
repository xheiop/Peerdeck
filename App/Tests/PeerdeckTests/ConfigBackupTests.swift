import Foundation
import Testing
import TorrentKit
@testable import Peerdeck

/// 配置导出导入：加密往返、口令错误、不带密码时清空和补回、合并规则
@Suite struct ConfigBackupTests {
    static func server(_ id: String, name: String = "NAS", password: String = "pw-secret") -> ServerConfig {
        var c = ServerConfig(
            id: id, name: name, kind: .qbittorrent, username: "admin", password: password,
            endpoints: [Endpoint(
                baseURL: URL(string: "https://nas.example.test:8443/qb/")!, kind: .proxy,
                proxyAuth: Credentials(username: "proxy", password: "proxy-secret"),
                headers: ["CF-Access-Client-Secret": "header-secret"])])
        c.apiKey = "api-secret"
        return c
    }

    static func content(_ servers: [ServerConfig] = [server("a")]) -> ConfigBackup.Content {
        ConfigBackup.Content(
            servers: servers,
            sites: [SiteConfig(id: "tracker.example.test", name: "Example", hosts: ["tracker.example.test"], defaultServer: "a")],
            unregisteredKeywords: ["unregistered", "自定义"],
            longUnreachableHours: 24,
            includesSecrets: true)
    }

    @Test func encryptedRoundTrip() throws {
        let data = try ConfigBackup.export(Self.content(), passphrase: "correct horse")
        let text = String(decoding: data, as: UTF8.self)
        // 密文里不能出现任何明文的密码、地址
        for secret in ["pw-secret", "api-secret", "proxy-secret", "header-secret", "nas.example.test"] {
            #expect(!text.contains(secret))
        }
        #expect(throws: ConfigBackup.Failure.needsPassphrase) { try ConfigBackup.read(data, passphrase: nil) }
        #expect(throws: ConfigBackup.Failure.wrongPassphrase) { try ConfigBackup.read(data, passphrase: "wrong horse") }
        let back = try ConfigBackup.read(data, passphrase: "correct horse")
        #expect(back == Self.content())
    }

    @Test func passphraseIsNormalized() throws {
        // 「é」两种编码：预组合 U+00E9 和 e + U+0301
        let data = try ConfigBackup.export(Self.content(), passphrase: "caf\u{E9}-password")
        #expect(try ConfigBackup.read(data, passphrase: "cafe\u{301}-password") == Self.content())
    }

    @Test func shortPassphraseRejected() {
        #expect(throws: ConfigBackup.Failure.passphraseTooShort) { try ConfigBackup.export(Self.content(), passphrase: "1234567") }
    }

    @Test func plainExportStripsSecrets() throws {
        let data = try ConfigBackup.export(Self.content(), passphrase: nil)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["pw-secret", "api-secret", "proxy-secret", "header-secret"] {
            #expect(!text.contains(secret))
        }
        let back = try ConfigBackup.read(data, passphrase: nil)
        #expect(!back.includesSecrets)
        let s = try #require(back.servers.first)
        #expect(s.password.isEmpty && s.apiKey.isEmpty)
        #expect(s.endpoints[0].proxyAuth?.username == "proxy" && s.endpoints[0].proxyAuth?.password == "")
        #expect(s.endpoints[0].headers == ["CF-Access-Client-Secret": ""])
        #expect(s.endpoints[0].baseURL.host() == "nas.example.test")
    }

    @Test func mediaSettingsAndTMDBKey() throws {
        var content = Self.content()
        content.mediaInfo = true
        content.tmdbKey = "tmdb-secret-key"
        // 不带密码：密钥被清掉，开关保留
        let plain = try ConfigBackup.export(content, passphrase: nil)
        #expect(!String(decoding: plain, as: UTF8.self).contains("tmdb-secret-key"))
        let p = try ConfigBackup.read(plain, passphrase: nil)
        #expect(p.mediaInfo == true && p.tmdbKey == nil)
        let mp = ConfigBackup.merge(p, into: [], prefs: AppPrefs(), tmdbKey: "local-key")
        #expect(mp.prefs.mediaInfo && mp.tmdbKey == nil && mp.summary.mediaInfo == true && !mp.summary.tmdbKeyChanged)

        // 带密码：密钥加密带上，导入时换成文件里的
        let sealed = try ConfigBackup.export(content, passphrase: "correct horse")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("tmdb-secret-key"))
        let back = try ConfigBackup.read(sealed, passphrase: "correct horse")
        #expect(back.tmdbKey == "tmdb-secret-key")
        let m = ConfigBackup.merge(back, into: [], prefs: AppPrefs(), tmdbKey: "local-key")
        #expect(m.tmdbKey == "tmdb-secret-key" && m.summary.tmdbKeyChanged)
        // 本机已经是同一个密钥、开关也一样：没有变化
        var on = AppPrefs()
        on.mediaInfo = true
        let same = ConfigBackup.merge(back, into: [], prefs: on, tmdbKey: "tmdb-secret-key")
        #expect(same.tmdbKey == nil && same.summary.mediaInfo == nil && !same.summary.tmdbKeyChanged)
    }

    @Test func olderFileWithoutMediaSettings() throws {
        // 0.3 导出的文件没有这两个字段：不动本机的开关和密钥
        let data = try ConfigBackup.export(Self.content(), passphrase: nil)
        let back = try ConfigBackup.read(data, passphrase: nil)
        var prefs = AppPrefs()
        prefs.mediaInfo = true
        let m = ConfigBackup.merge(back, into: [], prefs: prefs, tmdbKey: "local-key")
        #expect(m.prefs.mediaInfo && m.tmdbKey == nil && m.summary.mediaInfo == nil)
    }

    @Test func notABackup() {
        #expect(throws: ConfigBackup.Failure.notBackup) { try ConfigBackup.read(Data("{}".utf8), passphrase: nil) }
        #expect(throws: ConfigBackup.Failure.notBackup) { try ConfigBackup.read(Data("not json".utf8), passphrase: nil) }
        let newer = Data(#"{"format":"peerdeck-config","version":99,"exportedAt":"2026-11-23T00:00:00Z"}"#.utf8)
        #expect(throws: ConfigBackup.Failure.newerVersion) { try ConfigBackup.read(newer, passphrase: nil) }
    }

    @Test func mergeAddsUpdatesAndKeepsLocal() {
        var prefs = AppPrefs()
        prefs.sites = [SiteConfig(id: "tracker.example.test", name: "Old name", hosts: ["tracker.example.test"])]
        let localOnly = Self.server("local-only", name: "Only here")
        let renamed = Self.server("a", name: "Old NAS")
        let incoming = Self.content([Self.server("a"), Self.server("b", name: "Seedbox")])
        let r = ConfigBackup.merge(incoming, into: [renamed, localOnly], prefs: prefs)
        #expect(r.servers.map(\.id) == ["a", "local-only", "b"])
        #expect(r.servers[0].name == "NAS")
        #expect(r.summary == ConfigBackup.Summary(addedServers: 1, updatedServers: 1, addedSites: 0, updatedSites: 1, addedKeywords: 1, includesSecrets: true))
        #expect(r.prefs.sites[0].name == "Example")
        #expect(r.prefs.unregisteredKeywords.last == "自定义")
        #expect(r.prefs.longUnreachableHours == 24)
        // 再导入一次没有变化
        let again = ConfigBackup.merge(incoming, into: r.servers, prefs: r.prefs)
        #expect(again.summary.isEmpty)
    }

    @Test func mergeWithoutSecretsKeepsLocalPasswords() throws {
        let data = try ConfigBackup.export(Self.content([Self.server("a", name: "Renamed")]), passphrase: nil)
        let back = try ConfigBackup.read(data, passphrase: nil)
        let r = ConfigBackup.merge(back, into: [Self.server("a")], prefs: AppPrefs())
        let s = r.servers[0]
        #expect(s.name == "Renamed")
        #expect(s.password == "pw-secret" && s.apiKey == "api-secret")
        #expect(s.endpoints[0].proxyAuth?.password == "proxy-secret")
        #expect(s.endpoints[0].headers["CF-Access-Client-Secret"] == "header-secret")
        // 本机没有的服务器，密码就是空的
        let fresh = ConfigBackup.merge(back, into: [], prefs: AppPrefs()).servers[0]
        #expect(fresh.password.isEmpty)
    }
}
