import Foundation
import TorrentKit

public struct TorrentFilter: Sendable, Equatable {
    public var servers: Set<ServerID>?
    public var states: Set<TorrentState>?
    public var health: Set<TrackerHealth>?
    public var trackerHost: String?
    public var search: String

    public init(
        servers: Set<ServerID>? = nil,
        states: Set<TorrentState>? = nil,
        health: Set<TrackerHealth>? = nil,
        trackerHost: String? = nil,
        search: String = ""
    ) {
        self.servers = servers
        self.states = states
        self.health = health
        self.trackerHost = trackerHost
        self.search = search
    }

    public func matches(_ t: Torrent) -> Bool {
        if let servers, !servers.contains(t.ref.server) { return false }
        if let states, !states.contains(t.state) { return false }
        if let health, !health.contains(t.trackerHealth) { return false }
        if let trackerHost, t.trackerHost != trackerHost { return false }
        if !search.isEmpty, !t.name.localizedStandardContains(search) { return false }
        return true
    }
}

public enum SortKey: String, Sendable, CaseIterable {
    case name, addedAt, size, uploadSpeed, downloadSpeed, ratio, progress, seedingTime
}

public enum TorrentQuery {
    /// 过滤 + 排序，返回排好序的 ref 列表。万级种子在后台 actor 里调用。
    /// 只抽出排序键排序，不搬整个 Torrent 结构体（M0 实测：直接排结构体 20k 条要 90–190ms）。
    public static func run(
        _ torrents: some Sequence<Torrent>,
        filter: TorrentFilter,
        sort: SortKey,
        ascending: Bool = true
    ) -> [TorrentRef] {
        let rows = torrents.lazy.filter(filter.matches)
        switch sort {
        case .name:
            // 用预先算好的 nameSortKey 直接比。实测 20k 条：localizedStandardCompare 190ms，
            // compare(options: [.numeric, .caseInsensitive]) 反而要 940ms
            var keyed: [(String, TorrentRef)] = rows.map { ($0.nameSortKey, $0.ref) }
            keyed.sort { a, b in
                if a.0 == b.0 { return tieBreak(a.1, b.1) }
                return (a.0 < b.0) == ascending
            }
            return keyed.map(\.1)
        default:
            var keyed: [(Double, TorrentRef)] = rows.map { (numericKey($0, sort), $0.ref) }
            keyed.sort { a, b in
                if a.0 == b.0 { return tieBreak(a.1, b.1) }
                return (a.0 < b.0) == ascending
            }
            return keyed.map(\.1)
        }
    }

    private static func numericKey(_ t: Torrent, _ sort: SortKey) -> Double {
        switch sort {
        case .name: 0
        case .addedAt: Double(t.addedAt)
        case .size: Double(t.totalSize)
        case .uploadSpeed: Double(t.uploadSpeed)
        case .downloadSpeed: Double(t.downloadSpeed)
        case .ratio: t.ratio
        case .progress: t.progress
        case .seedingTime: Double(t.seedingTime)
        }
    }

    /// 主键相同时按 server + id 排，保证每次刷新顺序稳定，列表不跳
    private static func tieBreak(_ a: TorrentRef, _ b: TorrentRef) -> Bool {
        if a.server.rawValue != b.server.rawValue { return a.server.rawValue < b.server.rawValue }
        return a.id < b.id
    }

    /// 按站点（tracker host）聚合，给 tracker 健康页用
    public static func healthBySite(_ torrents: some Sequence<Torrent>) -> [String: [TrackerHealth: Int]] {
        var out: [String: [TrackerHealth: Int]] = [:]
        for t in torrents {
            out[t.trackerHost.isEmpty ? "(none)" : t.trackerHost, default: [:]][t.trackerHealth, default: 0] += 1
        }
        return out
    }
}
