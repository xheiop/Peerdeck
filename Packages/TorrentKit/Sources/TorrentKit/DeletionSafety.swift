import Foundation

/// 「连文件一起删」之前的辅种保护。错了就是删掉用户的数据，所以宁可多保留：
/// 同 infohash，或者同名（不看大小：只选了部分文件时大小会不一样），都当作共用同一份数据。
/// 认不出来的情况：改过名字的辅种、文件只有一部分重叠的种子。
public enum SharedData {
    /// `candidates` 里和范围之外的种子共用数据的那些。会传递：和受保护的共用数据的也受保护。
    /// 互为辅种、全都在范围里的不算（它们本来就要一起删）。
    public static func protected(_ candidates: [Torrent], among all: some Sequence<Torrent>) -> Set<TorrentRef> {
        guard !candidates.isEmpty else { return [] }
        let inSet = Set(candidates.map(\.ref))
        let wantedNames = Set(candidates.map(\.name)), wantedHashes = Set(candidates.map(\.infoHashV1))
        var names = Set<String>(), hashes = Set<String>()
        for t in all where !inSet.contains(t.ref) {
            if !t.name.isEmpty, wantedNames.contains(t.name) { names.insert(t.name) }
            if !t.infoHashV1.isEmpty, wantedHashes.contains(t.infoHashV1) { hashes.insert(t.infoHashV1) }
        }
        var out = Set<TorrentRef>()
        guard !names.isEmpty || !hashes.isEmpty else { return out }
        var grew = true
        while grew {
            grew = false
            for t in candidates where !out.contains(t.ref) && (names.contains(t.name) || hashes.contains(t.infoHashV1)) {
                out.insert(t.ref)
                if !t.name.isEmpty { names.insert(t.name) }
                if !t.infoHashV1.isEmpty { hashes.insert(t.infoHashV1) }
                grew = true
            }
        }
        return out
    }
}

/// 撤销窗口结束、真正发删除请求前的最后一次核对。只会让删除变少，不会变多。
public struct DeletionDecision: Sendable, Equatable {
    public var remove: [TorrentRef] = []
    /// `remove` 里连文件一起删的
    public var removeData: Set<TorrentRef> = []
    /// 没法确认、或者已经恢复正常，所以不删的
    public var skipped: [TorrentRef] = []
    /// 本来要连文件删、改成保留文件的个数
    public var filesKept = 0

    public init() {}

    /// - torrents: 现在所有下载器上的种子（包括等待删除的）
    /// - fresh: 刚刚重新同步成功的下载器
    /// - allServers: 配置里所有下载器，包括停用的。有一台没核对到，就不知道它有没有在用这些文件
    /// - stillEligible: 清理时传：现在是不是仍然符合清理条件
    public static func resolve(
        refs: [TorrentRef], wantsData: Set<TorrentRef>, torrents: [TorrentRef: Torrent],
        fresh: Set<ServerID>, allServers: Set<ServerID>, stillEligible: ((Torrent) -> Bool)? = nil
    ) -> DeletionDecision {
        var d = DeletionDecision()
        var removing: [Torrent] = []
        for ref in refs {
            guard let t = torrents[ref] else {
                // 刚核对过而且已经不在了：别处删掉了，不用再发。没核对到的不能当成删好了
                if !fresh.contains(ref.server) { d.skipped.append(ref) }
                continue
            }
            if let stillEligible, !fresh.contains(ref.server) || !stillEligible(t) {
                d.skipped.append(ref)
                continue
            }
            d.remove.append(ref)
            removing.append(t)
        }
        let wanted = wantsData.intersection(d.remove)
        if !wanted.isEmpty, allServers.isSubset(of: fresh) {
            d.removeData = wanted.subtracting(SharedData.protected(removing, among: torrents.values))
        }
        d.filesKept = wanted.count - d.removeData.count
        return d
    }
}
