import Foundation
import TorrentKit

enum StateGroup: String, CaseIterable, Sendable {
    case downloading, seeding, stopped, waiting, error

    var title: String {
        switch self {
        case .downloading: L("Downloading")
        case .seeding: L("Seeding")
        case .stopped: L("Stopped")
        case .waiting: L("Queued / Checking")
        case .error: L("Local Errors")
        }
    }

    var symbol: String {
        switch self {
        case .downloading: "arrow.down"
        case .seeding: "arrow.up"
        case .stopped: "stop.fill"
        case .waiting: "clock"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var states: Set<TorrentState> {
        switch self {
        case .downloading: [.downloading, .stalledDownloading, .metadata]
        case .seeding: [.seeding, .stalledSeeding]
        case .stopped: [.stopped]
        case .waiting: [.queued, .checking, .moving]
        case .error: [.error]
        }
    }

    static func of(_ s: TorrentState) -> StateGroup? { allCases.first { $0.states.contains(s) } }
}

enum SidebarItem: Hashable, Sendable {
    case all, active
    case rejected, unregistered, unreachable
    case state(StateGroup)
    case server(String)
    case site(String)
    /// qB 的分类；TR 没有
    case category(String)
    /// qB 的标签、TR 的 labels
    case tag(String)

    var isProblemView: Bool {
        switch self {
        case .rejected, .unregistered, .unreachable: true
        default: false
        }
    }
}

/// tracker 问题判断。阈值和关键词来自设置，所以放在 app 层，不在 TorrentKit 里。
struct ProblemRules: Sendable {
    var keywords: [String]
    var longSeconds: Int64
    var now: Int64

    static func current(_ prefs: AppPrefs) -> ProblemRules {
        ProblemRules(keywords: prefs.unregisteredKeywords.map { $0.lowercased() }.filter { !$0.isEmpty },
                     longSeconds: Int64(prefs.longUnreachableHours) * 3600,
                     now: Int64(Date().timeIntervalSince1970))
    }

    /// 被 tracker 拒绝。qB ≤ 5.0 的「不工作」分不清原因，也归到这里，列表里标「待确认」
    func isRejected(_ t: Torrent) -> Bool { t.trackerHealth == .trackerError || t.trackerHealth == .notWorking }

    func isUnregistered(_ t: Torrent) -> Bool {
        guard isRejected(t), !t.errorMessage.isEmpty else { return false }
        let m = t.errorMessage.lowercased()
        return keywords.contains { m.contains($0) }
    }

    func isLongUnreachable(_ t: Torrent, firstSeen: Int64?) -> Bool {
        guard t.trackerHealth == .unreachable, let f = firstSeen else { return false }
        return now - f >= longSeconds
    }

    func isProblem(_ t: Torrent) -> Bool { isRejected(t) || t.trackerHealth == .unreachable }

    /// 下载器本地出错（文件丢失、磁盘满、没权限）。和 tracker 无关，不进问题视图和清理，
    /// 但列表和详情要标出来。例：TR 的 "No data found! Ensure your drives are connected…"
    func isLocalError(_ t: Torrent) -> Bool { t.state == .error }
}

enum LocalErrorCopy {
    static var title: String { L("Local Error") }
    static var explanation: String {
        L("The downloader can’t use this torrent’s files: the drive may be disconnected, the files moved or deleted, or the disk full. Fix it on the server, then use Set Location or Recheck.")
    }
}

/// 表格的列
enum ColumnKey: String, CaseIterable, Sendable {
    case name, site, status, uploaded, ratio, seedTime, size, server, added, problem, message, cross, category, tags, path, limit, speedDown, speedUp, eta, peers

    var title: String {
        switch self {
        case .name: L("Name")
        case .site: L("Site")
        case .status: L("Status")
        case .uploaded: L("Uploaded")
        case .ratio: L("Ratio")
        case .seedTime: L("Seeding Time")
        case .size: L("Size")
        case .server: L("Server")
        case .added: L("Added")
        case .problem: L("Problem")
        case .message: L("Tracker Message")
        case .cross: L("Cross-seeds")
        case .category: L("Category")
        case .tags: L("Tags")
        case .path: L("Save Path")
        case .limit: L("Upload Limit")
        case .speedDown: L("Download Speed")
        case .speedUp: L("Upload Speed")
        case .eta: L("Time Left")
        case .peers: L("Seeds / Peers")
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 300
        case .site, .server: 90
        case .status: 150
        case .problem: 170
        case .message: 200
        case .uploaded, .size, .limit, .seedTime, .speedDown, .speedUp, .eta: 82
        case .peers: 90
        case .ratio, .cross: 60
        case .added: 125
        case .category: 80
        case .tags: 110
        case .path: 150
        }
    }

    var rightAligned: Bool { [.uploaded, .ratio, .seedTime, .size, .cross, .limit, .speedDown, .speedUp, .eta, .peers].contains(self) }
    /// 数值列默认降序；剩余时间默认升序（快完成的在上面）
    var defaultDescending: Bool { self != .eta && (rightAligned || [.status, .added, .problem].contains(self)) }

    static let normalDefault: [ColumnKey] = [.name, .site, .status, .uploaded, .ratio, .seedTime, .size, .server]
    static let normalAll: [ColumnKey] = normalDefault + [.added, .category, .tags, .path, .cross, .limit, .speedDown, .speedUp, .eta, .peers]
    static let problemDefault: [ColumnKey] = [.name, .site, .problem, .message, .cross, .seedTime, .ratio, .server]
    static let problemAll: [ColumnKey] = problemDefault + [.status, .uploaded, .size, .added, .category, .tags, .path]
    /// 「下载中」视图：做种相关的列（上传量、分享率、做种时间）在这里都是 0，换成下载要看的
    static let downloadingDefault: [ColumnKey] = [.name, .site, .status, .eta, .speedDown, .peers, .size, .server]
    static let downloadingAll: [ColumnKey] = downloadingDefault + [.added, .category, .tags, .path, .uploaded, .ratio, .speedUp]

    /// 列集：normal / problem / downloading，各自记住用户选的列
    static func defaults(for set: String) -> [ColumnKey] {
        switch set {
        case "problem": problemDefault
        case "downloading": downloadingDefault
        default: normalDefault
        }
    }

    static func all(for set: String) -> [ColumnKey] {
        switch set {
        case "problem": problemAll
        case "downloading": downloadingAll
        default: normalAll
        }
    }
}
