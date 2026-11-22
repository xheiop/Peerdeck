import Foundation
import Observation
import TorrentKit

/// 站点：按 tracker 域名识别。换域名后旧域名记进 aliases，站点身份不变。
struct SiteConfig: Codable, Hashable, Identifiable, Sendable {
    /// 第一次见到时的域名，之后不变
    var id: String
    var name: String
    /// 当前域名在 hosts[0]，其余是曾用域名
    var hosts: [String]
    /// 新种子默认添加到哪台服务器（ServerConfig.id）
    var defaultServer: String?

    var currentHost: String { hosts.first ?? id }

    /// 取主域名那一段（a.b.c → b）：去掉公共后缀，再取它前面那一段。
    /// tracker.aurora-pt.example → Aurora-pt；on.springsunday.net → Springsunday；pt.example.com.cn → Example
    static func guessName(_ host: String) -> String {
        let core = siteLabel(host)
        return core.prefix(1).uppercased() + core.dropFirst()
    }

    /// 常见的二级公共后缀（com.cn、co.uk、ne.jp……）里的第二段；顶级是两个字母的国家域名时才认
    private static let secondLevel: Set<String> = ["com", "net", "org", "edu", "gov", "co", "ac", "or", "ne", "go"]

    static func siteLabel(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        // IP、localhost、IPv6 原样返回
        if labels.count < 2 || host.contains(":") || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        var rest = labels.dropLast()
        if let tld = labels.last, tld.count == 2, rest.count >= 2, let sl = rest.last, secondLevel.contains(sl) { rest = rest.dropLast() }
        return rest.last ?? host
    }

    /// 0.1 之前的猜法（去掉 tracker / pt 之类的前缀后取第一段）。只用来识别「名字还是旧猜法、用户没改过」的站点，好在启动时纠正
    static func legacyGuessName(_ host: String) -> String {
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 2, ["tracker", "t", "pt", "www", "announce", "tr"].contains(labels[0]) { labels.removeFirst() }
        let core = labels.first ?? host
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}

/// 应用偏好（不含密码，存普通 JSON 文件）
struct AppPrefs: Codable, Sendable {
    var refreshForeground = 2
    var refreshBackground = 10
    var keepInMenuBar = true
    var notifyDone = true
    var notifyProblems = true
    var notifyServerDown = true
    var longUnreachableHours = 6
    var unregisteredKeywords: [String] = ["unregistered", "not registered", "torrent not found", "torrent does not exist", "未注册", "不存在", "已被删除", "已删除"]
    var sites: [SiteConfig] = []
    /// "normal" / "problem" → 列的 key
    var columns: [String: [String]] = [:]
    var lastAddServer: String?
    var recentPaths: [String] = []

    init() {}

    // 新增字段时旧文件也能读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPrefs()
        refreshForeground = (try? c.decode(Int.self, forKey: .refreshForeground)) ?? d.refreshForeground
        refreshBackground = (try? c.decode(Int.self, forKey: .refreshBackground)) ?? d.refreshBackground
        keepInMenuBar = (try? c.decode(Bool.self, forKey: .keepInMenuBar)) ?? d.keepInMenuBar
        notifyDone = (try? c.decode(Bool.self, forKey: .notifyDone)) ?? d.notifyDone
        notifyProblems = (try? c.decode(Bool.self, forKey: .notifyProblems)) ?? d.notifyProblems
        notifyServerDown = (try? c.decode(Bool.self, forKey: .notifyServerDown)) ?? d.notifyServerDown
        longUnreachableHours = (try? c.decode(Int.self, forKey: .longUnreachableHours)) ?? d.longUnreachableHours
        unregisteredKeywords = (try? c.decode([String].self, forKey: .unregisteredKeywords)) ?? d.unregisteredKeywords
        sites = (try? c.decode([SiteConfig].self, forKey: .sites)) ?? []
        columns = (try? c.decode([String: [String]].self, forKey: .columns)) ?? [:]
        lastAddServer = try? c.decode(String.self, forKey: .lastAddServer)
        recentPaths = (try? c.decode([String].self, forKey: .recentPaths)) ?? []
    }
}

/// 应用数据目录：~/Library/Application Support/Peerdeck；TC_DATA_DIR 覆盖（自动化验证用）
enum AppData {
    static let appGroup = "group.dev.peerdeck"
    static let dir: URL = {
        if let p = ProcessInfo.processInfo.environment["TC_DATA_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        #if os(iOS)
        // iOS：放在 App Group 容器里，Share Extension 也能读到偏好（站点默认服务器、最近路径）
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppData.appGroup) {
            return group.appending(path: "Peerdeck", directoryHint: .isDirectory)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Peerdeck", directoryHint: .isDirectory)
    }()

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(value).write(to: dir.appending(path: name), options: .atomic)
        } catch {
            Log.info("保存 \(name) 失败：\(error)")
        }
    }
}

/// tracker 问题的首次发现时间。下载器不提供这个信息，只能自己记。
struct ProblemLedger: Codable, Sendable {
    var firstSeen: [String: Int64] = [:]
    /// 清理「疑似未注册」时因为有辅种而保留的种子：之后不再算作待处理（恢复正常或被删时清掉）
    var kept: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstSeen = try c.decodeIfPresent([String: Int64].self, forKey: .firstSeen) ?? [:]
        kept = try c.decodeIfPresent(Set<String>.self, forKey: .kept) ?? []
    }

    static func key(_ ref: TorrentRef) -> String { "\(ref.server.rawValue)/\(ref.id)" }
    func firstSeen(_ ref: TorrentRef) -> Int64? { firstSeen[Self.key(ref)] }
    func isKept(_ ref: TorrentRef) -> Bool { kept.contains(Self.key(ref)) }
}
