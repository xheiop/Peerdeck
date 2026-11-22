import Foundation

public struct ServerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ClientKind: String, Sendable, Codable {
    case qbittorrent
    case transmission
    case flood

    /// 产品名，不翻译
    public var displayName: String {
        switch self {
        case .qbittorrent: "qBittorrent"
        case .transmission: "Transmission"
        case .flood: "Flood"
        }
    }

    public var shortName: String {
        switch self {
        case .qbittorrent: "qB"
        case .transmission: "TR"
        case .flood: "Flood"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .qbittorrent: 8080
        case .transmission: 9091
        case .flood: 3000
        }
    }

    // 只和下载器种类有关、离线时也要知道的能力（和版本、后端有关的放在 Capabilities）
    public var hasAlternativeSpeedLimits: Bool { self != .flood }
    public var hasTorrentUploadLimit: Bool { self != .flood }
    public var canReplaceTrackers: Bool { self != .flood }
}

/// 种子在全局的唯一标识：服务器 + hash。不能用服务端的序号：TR 的数字 id 重启后会指向别的种子。
public struct TorrentRef: Hashable, Sendable, CustomStringConvertible {
    public let server: ServerID
    public let id: String
    public init(server: ServerID, id: String) {
        self.server = server
        self.id = id
    }
    public var description: String { "\(server)/\(id)" }
}

public enum TorrentState: String, Sendable, Codable, CaseIterable {
    case downloading
    case seeding
    case stalledDownloading
    case stalledSeeding
    case stopped
    case queued
    case checking
    case metadata
    case moving
    case error
    case unknown
}

/// tracker 健康度。只用列表接口就能拿到的粗粒度结论，消息文本要到详情里再查。
public enum TrackerHealth: String, Sendable, Codable {
    /// 至少一个 tracker 正常
    case working
    /// tracker 回了 failure reason（Unregistered torrent 一类就在这里）
    case trackerError
    /// tracker 回了 warning message
    case trackerWarning
    /// 连不上、超时、HTTP 错误
    case unreachable
    /// 没有正常工作的 tracker，但分不清原因（qB ≤ 5.0 只能判断到这一步），要逐个查 trackers
    case notWorking
    /// 还没汇报过、种子已停止，或者服务端版本拿不到这个信息
    case unknown
}

public struct Torrent: Sendable, Identifiable, Equatable {
    public let ref: TorrentRef
    public var id: TorrentRef { ref }

    public var name: String = "" {
        didSet { if name != oldValue { nameSortKey = Self.sortKey(name) } }
    }
    /// 名称排序键：小写 + 数字段补零到 12 位，这样直接用 < 比较就是「自然排序」（E2 < E10）。
    /// 名称变化时算一次，排序时不用再做本地化比较（M0 实测 20k 条按名称排从 190ms 降下来）。
    public private(set) var nameSortKey: String = ""
    public var infoHashV1: String = ""
    public var infoHashV2: String = ""
    public var state: TorrentState = .unknown
    /// 服务端原始状态，排查用（qB 的 state 字符串；TR 的 status 数字）
    public var rawState: String = ""
    public var progress: Double = 0
    public var totalSize: Int64 = 0
    public var downloaded: Int64 = 0
    public var uploaded: Int64 = 0
    public var ratio: Double = 0
    public var downloadSpeed: Int64 = 0
    public var uploadSpeed: Int64 = 0
    /// 秒；-1 表示无穷或未知
    public var eta: Int64 = -1
    public var seeds: Int = 0
    public var peers: Int = 0
    /// Unix 秒；0 表示没有
    public var addedAt: Int64 = 0
    public var completedAt: Int64 = 0
    public var seedingTime: Int64 = 0
    public var savePath: String = ""
    public var category: String = ""
    public var tags: [String] = []
    public var isPrivate: Bool? = nil
    /// qB：当前工作的 tracker（5.3 起出错时也会有值）；TR：第一个 tracker
    public var currentTracker: String = ""
    /// 种子的主 tracker 地址（qB 取 maindata trackers 映射里的第一个，TR 取 trackers[0]），按站点分组用。
    /// 和 currentTracker 分开：qB 4.x 的 tracker 字段在不工作时是空的，不能拿来分组。
    public var announceURL: String = "" {
        didSet { if announceURL != oldValue { trackerHost = Self.host(of: announceURL) } }
    }
    /// 从 announceURL 解析出来的主机名。提前算好，避免每次筛选都解析 URL。
    public private(set) var trackerHost: String = ""
    public var trackerCount: Int = 0
    /// 全部 tracker 地址（按 tier 顺序），替换 tracker 时用
    public var trackerURLs: [String] = []
    /// 单种上传限速，字节/秒，0 表示不限
    public var uploadLimit: Int64 = 0
    public var trackerHealth: TrackerHealth = .unknown
    /// TR 的 errorString；qB 列表接口没有消息文本，保持空
    public var errorMessage: String = ""

    public init(ref: TorrentRef) { self.ref = ref }

    static func sortKey(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        var digits = ""
        func flush() {
            if !digits.isEmpty {
                if digits.count < 12 { out += String(repeating: "0", count: 12 - digits.count) }
                out += digits
                digits = ""
            }
        }
        for ch in s.lowercased() {
            if ch.isASCII, ch.isNumber { digits.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    /// 比 URLComponents 快得多的主机名提取，只处理 tracker URL 这种简单情况
    static func host(of url: String) -> String {
        guard let scheme = url.range(of: "://") else { return "" }
        let rest = url[scheme.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == ":" || $0 == "?" } ?? rest.endIndex
        return String(rest[..<end]).lowercased()
    }

    public mutating func apply(_ p: TorrentPatch) {
        if let v = p.name { name = v }
        if let v = p.infoHashV1 { infoHashV1 = v }
        if let v = p.infoHashV2 { infoHashV2 = v }
        if let v = p.state { state = v }
        if let v = p.rawState { rawState = v }
        if let v = p.progress { progress = v }
        if let v = p.totalSize { totalSize = v }
        if let v = p.downloaded { downloaded = v }
        if let v = p.uploaded { uploaded = v }
        if let v = p.ratio { ratio = v }
        if let v = p.downloadSpeed { downloadSpeed = v }
        if let v = p.uploadSpeed { uploadSpeed = v }
        if let v = p.eta { eta = v }
        if let v = p.seeds { seeds = v }
        if let v = p.peers { peers = v }
        if let v = p.addedAt { addedAt = v }
        if let v = p.completedAt { completedAt = v }
        if let v = p.seedingTime { seedingTime = v }
        if let v = p.savePath { savePath = v }
        if let v = p.category { category = v }
        if let v = p.tags { tags = v }
        if let v = p.isPrivate { isPrivate = v }
        if let v = p.currentTracker { currentTracker = v }
        if let v = p.announceURL { announceURL = v }
        if let v = p.trackerCount { trackerCount = v }
        if let v = p.trackerURLs { trackerURLs = v }
        if let v = p.uploadLimit { uploadLimit = v }
        if let v = p.trackerHealth { trackerHealth = v }
        if let v = p.errorMessage { errorMessage = v }
    }
}

/// 增量更新：nil 表示这个字段没变。
public struct TorrentPatch: Sendable, Equatable {
    public var name: String?
    public var infoHashV1: String?
    public var infoHashV2: String?
    public var state: TorrentState?
    public var rawState: String?
    public var progress: Double?
    public var totalSize: Int64?
    public var downloaded: Int64?
    public var uploaded: Int64?
    public var ratio: Double?
    public var downloadSpeed: Int64?
    public var uploadSpeed: Int64?
    public var eta: Int64?
    public var seeds: Int?
    public var peers: Int?
    public var addedAt: Int64?
    public var completedAt: Int64?
    public var seedingTime: Int64?
    public var savePath: String?
    public var category: String?
    public var tags: [String]?
    public var isPrivate: Bool?
    public var currentTracker: String?
    public var announceURL: String?
    public var trackerCount: Int?
    public var trackerURLs: [String]?
    public var uploadLimit: Int64?
    public var trackerHealth: TrackerHealth?
    public var errorMessage: String?

    public init() {}
}

public struct ServerStats: Sendable, Equatable {
    public var downloadSpeed: Int64 = 0
    public var uploadSpeed: Int64 = 0
    public var freeSpace: Int64? = nil
    public var altSpeedEnabled: Bool = false
    /// 下载器自己记的历史总量（qB alltime_ul/alltime_dl，TR cumulative-stats），字节。还没拿到时是 nil
    public var allTimeUploaded: Int64? = nil
    public var allTimeDownloaded: Int64? = nil
    public init() {}

    public mutating func apply(_ p: ServerStatsPatch) {
        if let v = p.downloadSpeed { downloadSpeed = v }
        if let v = p.uploadSpeed { uploadSpeed = v }
        if let v = p.freeSpace { freeSpace = v }
        if let v = p.altSpeedEnabled { altSpeedEnabled = v }
        if let v = p.allTimeUploaded { allTimeUploaded = v }
        if let v = p.allTimeDownloaded { allTimeDownloaded = v }
    }
}

/// 全局限速。字节/秒，0 表示不限。
/// 备用限速（qB 的「备用速度限制」、TR 的「乌龟模式」）开关在 ServerStats.altSpeedEnabled，这里只管数值。
public struct SpeedLimits: Sendable, Equatable {
    public var download: Int64
    public var upload: Int64
    public var altDownload: Int64
    public var altUpload: Int64
    public init(download: Int64 = 0, upload: Int64 = 0, altDownload: Int64 = 0, altUpload: Int64 = 0) {
        self.download = download
        self.upload = upload
        self.altDownload = altDownload
        self.altUpload = altUpload
    }
}

public struct ServerStatsPatch: Sendable, Equatable {
    public var downloadSpeed: Int64?
    public var uploadSpeed: Int64?
    public var freeSpace: Int64?
    public var altSpeedEnabled: Bool?
    public var allTimeUploaded: Int64?
    public var allTimeDownloaded: Int64?
    public init() {}
}

public struct SyncDelta: Sendable {
    /// true 时调用方要丢掉旧状态，用 upserts 整体替换
    public var isFullUpdate: Bool
    public var upserts: [String: TorrentPatch]
    public var removed: Set<String>
    public var stats: ServerStatsPatch?

    public init(isFullUpdate: Bool, upserts: [String: TorrentPatch] = [:], removed: Set<String> = [], stats: ServerStatsPatch? = nil) {
        self.isFullUpdate = isFullUpdate
        self.upserts = upserts
        self.removed = removed
        self.stats = stats
    }
}

public enum TrackerStatus: String, Sendable {
    case disabled, notContacted, working, updating, notWorking, trackerError, unreachable, unknown
}

/// 文件下载优先级。qB 没有「低」（只有不下载 / 普通 / 高 / 最高，读到「最高」按「高」算）
public enum FilePriority: String, Sendable, CaseIterable {
    case skip, low, normal, high
}

/// 种子里的一个文件
public struct ContentFile: Sendable, Equatable, Identifiable {
    /// 下载器里的文件序号，改优先级时用
    public var index: Int
    /// 种子内的相对路径（多文件种子带根目录）
    public var path: String
    public var size: Int64
    /// 0…1
    public var progress: Double
    public var priority: FilePriority
    public var id: Int { index }

    public init(index: Int, path: String, size: Int64, progress: Double, priority: FilePriority) {
        self.index = index
        self.path = path
        self.size = size
        self.progress = progress
        self.priority = priority
    }
}

public struct Tracker: Sendable, Equatable {
    public var url: String
    public var tier: Int
    public var status: TrackerStatus
    public var message: String
    public var seeds: Int?
    public var leeches: Int?

    public init(url: String, tier: Int, status: TrackerStatus, message: String, seeds: Int? = nil, leeches: Int? = nil) {
        self.url = url
        self.tier = tier
        self.status = status
        self.message = message
        self.seeds = seeds
        self.leeches = leeches
    }
}

public enum TorrentAction: Sendable, Equatable {
    case start
    case stop
    case recheck
    case reannounce
    case delete(withData: Bool)
}

/// 一个种子的标签变化：从 current 改成 final。qB 按增删调用，TR 直接设置 labels。
public struct TagChange: Sendable, Equatable {
    public var id: String
    public var current: [String]
    public var final: [String]
    public init(id: String, current: [String], final: [String]) {
        self.id = id
        self.current = current
        self.final = final
    }
}

public enum AddSource: Sendable {
    /// magnet: 或 http(s) 链接
    case url(String)
    case file(Data, filename: String)
}

public struct AddOptions: Sendable {
    public var savePath: String?
    public var category: String?
    public var tags: [String]
    public var paused: Bool

    public init(savePath: String? = nil, category: String? = nil, tags: [String] = [], paused: Bool = false) {
        self.savePath = savePath
        self.category = category
        self.tags = tags
        self.paused = paused
    }
}

public struct ServerInfo: Sendable, Equatable {
    public var kind: ClientKind
    /// 例如 "5.3.0" / "4.1.4 (a6d907d9ea)"
    public var version: String
    /// qB 的 webapiVersion 或 TR 的 rpc-version-semver
    public var apiVersion: SemVer
    public var capabilities: Capabilities

    public init(kind: ClientKind, version: String, apiVersion: SemVer, capabilities: Capabilities) {
        self.kind = kind
        self.version = version
        self.apiVersion = apiVersion
        self.capabilities = capabilities
    }
}

public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 列表接口里直接带 tracker 健康度（qB 5.2+ 的 has_tracker_* 字段；TR 的 error 字段）
    public static let trackerHealthInList = Capabilities(rawValue: 1 << 0)
    public static let categories = Capabilities(rawValue: 1 << 1)
    public static let tags = Capabilities(rawValue: 1 << 2)
    /// TR 4.0+ 的 trackerStats.sitename
    public static let trackerSiteName = Capabilities(rawValue: 1 << 3)
    /// 改保存路径时可以选择不移动文件（TR 的 torrent-set-location move=false；qB 总会移动）
    public static let relocateWithoutMove = Capabilities(rawValue: 1 << 4)
    /// qB 5.2+ 的 API key 认证
    public static let apiKey = Capabilities(rawValue: 1 << 5)
    /// 文件优先级有「低」这一档（TR 有，qB 没有）
    public static let lowFilePriority = Capabilities(rawValue: 1 << 6)
}

public struct SemVer: Comparable, Sendable, Hashable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 宽松解析："v5.3.0"、"2.16.2"、"4.1.4 (a6d907d9ea)" 都能读出来
    public init?(parsing s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        self.init(first, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
