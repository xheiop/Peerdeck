import Foundation
import TorrentKit

/// 一次同步后哪些种子变了。UI 只需要刷新这些行。
public struct ChangeSet: Sendable, Equatable {
    public var isFull: Bool
    public var changed: Set<TorrentRef>
    public var removed: Set<TorrentRef>
    public var statsChanged: Bool

    public static let empty = ChangeSet(isFull: false, changed: [], removed: [], statsChanged: false)
}

/// 一台服务器的本地镜像：拉增量、合并、记录变化。
public actor ServerSync {
    public nonisolated let serverID: ServerID
    public let client: any TorrentClient
    public private(set) var torrents: [String: Torrent] = [:]
    public private(set) var stats = ServerStats()

    public init(client: any TorrentClient) {
        self.client = client
        self.serverID = client.serverID
    }

    @discardableResult
    public func refresh() async throws -> ChangeSet {
        let delta = try await client.fetchChanges()
        return apply(delta)
    }

    /// 合并一次增量。不做网络请求，方便单测和压测。
    @discardableResult
    public func apply(_ delta: SyncDelta) -> ChangeSet {
        Self.merge(delta, into: &torrents, stats: &stats, server: serverID)
    }

    public func snapshot() -> [Torrent] { Array(torrents.values) }

    /// 取一部分种子（UI 只拿这次变化的那些）
    public func torrents(_ ids: some Sequence<String>) -> [Torrent] {
        ids.compactMap { torrents[$0] }
    }

    static func merge(
        _ delta: SyncDelta,
        into torrents: inout [String: Torrent],
        stats: inout ServerStats,
        server: ServerID
    ) -> ChangeSet {
        var changed = Set<TorrentRef>()
        var removed = Set<TorrentRef>()

        if delta.isFullUpdate {
            var fresh = [String: Torrent](minimumCapacity: delta.upserts.count)
            for (id, patch) in delta.upserts {
                var t = Torrent(ref: TorrentRef(server: server, id: id))
                t.apply(patch)
                fresh[id] = t
            }
            for id in torrents.keys where fresh[id] == nil {
                removed.insert(TorrentRef(server: server, id: id))
            }
            changed = Set(fresh.values.map(\.ref))
            torrents = fresh
        } else {
            for (id, patch) in delta.upserts {
                let ref = TorrentRef(server: server, id: id)
                var t = torrents[id] ?? Torrent(ref: ref)
                let before = t
                t.apply(patch)
                if t != before || torrents[id] == nil {
                    torrents[id] = t
                    changed.insert(ref)
                }
            }
            for id in delta.removed where torrents.removeValue(forKey: id) != nil {
                removed.insert(TorrentRef(server: server, id: id))
            }
        }

        var statsChanged = false
        if let sp = delta.stats {
            let before = stats
            stats.apply(sp)
            statsChanged = stats != before
        }
        return ChangeSet(isFull: delta.isFullUpdate, changed: changed, removed: removed, statsChanged: statsChanged)
    }
}
