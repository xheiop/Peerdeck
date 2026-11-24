import Foundation
import TorrentKit

/// Flood 后面接的下载器。API 不直接告诉我们，只能从 /api/client/settings 的特征推断：
/// 各后端在 Flood 的 clientGatewayService 里给不支持的设置填的常量不一样（v4.16.4 源码）。
/// 同一个字段在不同后端含义不同（message、directory、文件路径），所以必须分清。
enum FloodBackend: Sendable, Equatable {
    case rTorrent, qBittorrent, transmission, deluge, neptune, unknown

    static func detect(_ s: FloodSettings) -> FloodBackend {
        if s.trackersNumWant == -1, s.piecesMemoryMax == -1 { return .deluge }
        if (s.networkMaxOpenFiles ?? 0) > 0 || (s.piecesMemoryMax ?? 0) > 0 { return .rTorrent }
        guard let address = s.networkLocalAddress else { return .unknown }
        if s.networkPortOpen == false, s.networkPortRange == "", address.isEmpty { return .neptune }
        guard s.networkPortOpen == true, s.networkMaxOpenFiles == 0, s.trackersNumWant == 0 else { return .unknown }
        return address.isEmpty ? .transmission : .qBittorrent
    }

    var name: String {
        switch self {
        case .rTorrent: "rTorrent"
        case .qBittorrent: "qBittorrent"
        case .transmission: "Transmission"
        case .deluge: "Deluge"
        case .neptune: "Neptune"
        case .unknown: "?"
        }
    }

    /// tracker 状态够不够可靠，可以进「被拒绝 / 连不上」和清理。
    /// - qB：Flood 把报错缓存 1 小时，而且分不出错误和警告。拿它来清理会误删已经恢复的种子
    /// - Deluge：message 不是 tracker 状态
    /// - Neptune、认不出来的：没验证过，按不可靠算
    var reportsTrackerHealth: Bool { self == .rTorrent || self == .transmission }

    /// 其他后端会忽略 moveFiles=false，照样移动文件
    var canRelocateWithoutMove: Bool { self == .rTorrent || self == .transmission }

    /// Deluge 后端的 setTorrentsTags 是空实现：返回成功，实际什么都没做
    var supportsTags: Bool { self != .deluge }
}

/// /api/client/settings 里用得到的字段。rTorrent 缺某个方法时对应字段会没有，所以都是可选的
struct FloodSettings: Decodable {
    var directoryDefault: String?
    var networkLocalAddress: [String]?
    var networkMaxOpenFiles: Double?
    var networkPortOpen: Bool?
    var networkPortRange: String?
    var piecesMemoryMax: Double?
    var trackersNumWant: Double?
    /// B/s，0 表示不限
    var throttleGlobalDownSpeed: Double?
    var throttleGlobalUpSpeed: Double?
}

/// JSON 里的数值可能是小数（eta）、null（NaN / Infinity 序列化的结果）
enum FloodNumber {
    static func double(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
        return d
    }

    static func int(_ v: Any?) -> Int64? {
        guard let d = double(v), abs(d) < 9e18 else { return nil }
        return Int64(d)
    }
}

/// 列表里的一个种子。从 JSON 字典读，不用 Decodable：SSE 增量要先在原始 JSON 上打补丁。
struct FloodTorrent: Sendable, Equatable {
    var hash: String
    var name = ""
    var message = ""
    var status: Set<String> = []
    /// 只有主域名（tldts 的 getDomain），没有完整地址，也没有 passkey
    var trackerDomains: [String] = []
    var tags: [String] = []
    var directory = ""
    var size: Int64 = 0
    var selectedSize: Int64?
    var bytesDone: Int64?
    var percent: Double?
    var downloaded: Int64 = 0
    var uploaded: Int64 = 0
    var downRate: Int64 = 0
    var upRate: Int64 = 0
    var ratio: Double = 0
    var eta: Int64 = -1
    var seeds = 0
    var peers = 0
    var added: Int64 = 0
    var finished: Int64 = 0
    var isPrivate: Bool?

    init(hash: String, json j: [String: Any]) {
        self.hash = hash
        name = j["name"] as? String ?? ""
        message = j["message"] as? String ?? ""
        status = Set((j["status"] as? [Any] ?? []).compactMap { $0 as? String })
        trackerDomains = (j["trackerURIs"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        tags = (j["tags"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        directory = j["directory"] as? String ?? ""
        size = FloodNumber.int(j["sizeBytes"]) ?? 0
        selectedSize = FloodNumber.int(j["selectedSizeBytes"])
        bytesDone = FloodNumber.int(j["bytesDone"])
        percent = FloodNumber.double(j["percentComplete"])
        downloaded = FloodNumber.int(j["downTotal"]) ?? 0
        uploaded = FloodNumber.int(j["upTotal"]) ?? 0
        downRate = FloodNumber.int(j["downRate"]) ?? 0
        upRate = FloodNumber.int(j["upRate"]) ?? 0
        ratio = max(0, FloodNumber.double(j["ratio"]) ?? 0)
        eta = FloodNumber.int(j["eta"]).map { $0 < 0 ? -1 : $0 } ?? -1
        seeds = Int(clamping: FloodNumber.int(j["seedsConnected"]) ?? 0)
        peers = Int(clamping: FloodNumber.int(j["peersConnected"]) ?? 0)
        added = max(0, FloodNumber.int(j["dateAdded"]) ?? 0)
        finished = max(0, FloodNumber.int(j["dateFinished"]) ?? 0)
        isPrivate = j["isPrivate"] as? Bool
    }

    /// 选中要下的大小，和 qB 的 size、TR 的 sizeWhenDone 一个口径：各处显示和统计的口径必须一致
    var wantedSize: Int64 {
        if let s = selectedSize, s > 0 { return s }
        return size
    }

    var progress: Double {
        // 磁力还没拿到元数据时大小是 0；TR 后端这时会标成 complete（0 == 0）
        guard wantedSize > 0 else { return 0 }
        if status.contains("complete") { return 1 }
        // TR 后端的 percentComplete 是按总大小算的，只选了部分文件时永远到不了 100
        if let done = bytesDone { return min(1, max(0, Double(done) / Double(wantedSize))) }
        return min(1, max(0, (percent ?? 0) / 100))
    }

    /// rTorrent 多文件种子的 directory 带着种子目录（/data/Movie），别的后端是它的上一级（/data）
    func includesRootFolder(_ backend: FloodBackend) -> Bool {
        backend == .rTorrent && !name.isEmpty && directory.hasSuffix("/" + name)
    }

    func savePath(_ backend: FloodBackend) -> String {
        guard includesRootFolder(backend) else { return directory }
        let parent = String(directory.dropLast(name.count + 1))
        return parent.isEmpty ? "/" : parent
    }

    func state(localError: Bool) -> TorrentState {
        if localError { return .error }
        if status.contains("checking") { return .checking }
        if status.contains("moving") { return .moving }
        if status.contains("stopped") { return .stopped }
        if status.contains("seeding") { return upRate > 0 ? .seeding : .stalledSeeding }
        if status.contains("downloading") {
            if wantedSize == 0 { return .metadata }
            return downRate > 0 ? .downloading : .stalledDownloading
        }
        return .unknown
    }

    /// announceURL 只是用来按站点分组的「协议://主机/」，不是完整地址，所以 trackerURLs 留空
    func patch(backend: FloodBackend, announceURL: String) -> TorrentPatch {
        let d = FloodHealth.diagnose(self, backend: backend)
        var p = TorrentPatch()
        p.name = name
        // id 用 Flood 原样的大写 hash；infoHashV1 转小写，才能和直连 qB / TR 的同一个种子对上（辅种保护）
        p.infoHashV1 = hash.lowercased()
        p.state = state(localError: d.localError)
        p.rawState = status.sorted().joined(separator: ",")
        p.progress = progress
        p.totalSize = wantedSize
        p.downloaded = downloaded
        p.uploaded = uploaded
        p.ratio = ratio
        p.downloadSpeed = downRate
        p.uploadSpeed = upRate
        p.eta = eta
        p.seeds = seeds
        p.peers = peers
        p.addedAt = added
        p.completedAt = finished
        p.savePath = savePath(backend)
        p.category = ""
        p.tags = tags
        p.isPrivate = isPrivate
        p.currentTracker = announceURL
        p.announceURL = announceURL
        p.trackerCount = trackerDomains.count
        p.trackerURLs = []
        p.trackerHealth = d.health
        p.errorMessage = d.message
        return p
    }
}

struct FloodDisk: Sendable, Decodable, Equatable {
    var target: String
    var avail: Double

    /// 路径所在的挂载点：前缀最长、且断在目录边界上的那个。找不到就是不知道，不猜
    static func free(_ disks: [FloodDisk], for path: String?) -> Int64? {
        guard let path, !path.isEmpty else { return nil }
        let hit = disks.filter { d in
            d.target == "/" || path == d.target || path.hasPrefix(d.target + "/")
        }.max { $0.target.count < $1.target.count }
        return hit.flatMap { FloodNumber.int($0.avail) }
    }
}

struct FloodSummary: Sendable, Decodable, Equatable {
    var downRate: Double?
    var upRate: Double?
}

struct FloodConnectivity: Decodable {
    var isConnected: Bool
}

struct FloodDetails: Decodable {
    struct Entry: Decodable {
        var url: String
        /// 1 HTTP / 2 UDP / 3 DHT
        var type: Int?
    }
    var trackers: [Entry]

    /// 去掉 qB 的 DHT / PeX / LSD 伪 tracker
    var realURLs: [String] { trackers.filter { $0.type != 3 && $0.url.contains("://") }.map(\.url) }
}

/// api/torrents/{hash}/peers 的一项（Flood 4.16.4 TR 后端实测）。没有端口，也没有累计量和连接方式
struct FloodPeer: Decodable {
    var address: String
    var country: String?
    var clientVersion: String?
    /// 0…100
    var completedPercent: Double?
    var downloadRate: Double?
    var uploadRate: Double?
    var isEncrypted: Bool?
    var isIncoming: Bool?

    var model: Peer {
        Peer(address: address, port: 0, client: clientVersion ?? "",
             progress: completedPercent.map { min(1, max(0, $0 / 100)) } ?? 0,
             downloadRate: FloodNumber.int(downloadRate) ?? 0, uploadRate: FloodNumber.int(uploadRate) ?? 0,
             encrypted: isEncrypted, incoming: isIncoming,
             countryCode: country.flatMap { $0.isEmpty ? nil : $0.uppercased() })
    }
}

struct FloodContent: Decodable {
    var index: Int
    var path: String
    var sizeBytes: Double?
    var percentComplete: Double?
    /// 0 不下载 / 1 普通 / 2 高
    var priority: Int?

    /// rootFolder：rTorrent 多文件种子的路径不带根目录，补上后和其他后端一致
    func model(rootFolder: String?) -> ContentFile {
        let priority: FilePriority = switch self.priority {
        case 0: .skip
        case 2: .high
        default: .normal
        }
        return ContentFile(
            index: index, path: rootFolder.map { "\($0)/\(path)" } ?? path,
            size: FloodNumber.int(sizeBytes) ?? 0,
            // 0 字节文件的 percentComplete 是 null
            progress: percentComplete.map { min(1, max(0, $0 / 100)) } ?? 1,
            priority: priority
        )
    }
}
