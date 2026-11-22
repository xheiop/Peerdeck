import Foundation
import Observation
import SyncEngine
import TorrentKit

struct SidebarCounts: Equatable, Sendable {
    var total = 0, active = 0
    var rejected = 0, unregistered = 0, unreachableLong = 0, unreachableTransient = 0
    var states: [StateGroup: Int] = [:]
    var servers: [String: Int] = [:]
    var sites: [String: Int] = [:]
    var siteProblems: [String: Int] = [:]
    /// 每个站的种子体积、已上传、已下载合计（字节）。同一份数据辅种在两个站会各算一次
    var siteSize: [String: Int64] = [:]
    var siteUploaded: [String: Int64] = [:]
    var siteDownloaded: [String: Int64] = [:]
    var categories: [String: Int] = [:]
    var tags: [String: Int] = [:]
    /// 在不提供 tracker 状态的服务器（qB 5.1.x）上的种子数
    var noHealth = 0
}

/// 总览（分诊台）用的汇总：按 tracker 健康度分堆，只算在线下载器上的种子
struct Triage: Equatable, Sendable {
    struct Pile: Equatable, Sendable {
        var count = 0
        /// tracker 原话 → 种子数
        var messages: [String: Int] = [:]
        var sites: Set<String> = []
        /// 其中有辅种的（清理时会保留）
        var crossSeeded = 0
        /// 最早发现的时间（Unix 秒）
        var since: Int64?

        /// 出现最多的那条原话
        var topMessage: String { messages.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "" }
        var otherMessageCount: Int { max(0, messages.count - 1) }
    }

    var unregistered = Pile()
    /// 被拒绝、但不是疑似未注册的
    var rejected = Pile()
    /// 长时间连不上
    var unreachable = Pile()
    /// 已清理过、因为有辅种保留下来的疑似未注册
    var kept = 0
    var downloading = 0, seeding = 0, stopped = 0, other = 0
    /// 正在上传或下载的（速度不为 0），和上面的状态分堆有重叠
    var active = 0
    var downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0

    /// 有几类问题要处理
    var problemKinds: Int { [unregistered, rejected, unreachable].filter { $0.count > 0 }.count }
}

struct SiteSummary: Equatable, Sendable {
    var siteID: String
    var total = 0, seeding = 0, problems = 0
    var size: Int64 = 0, uploaded: Int64 = 0, uploadSpeed: Int64 = 0
    var byServer: [String: Int] = [:]
    var hosts: [String] = []
}

enum TableUpdate {
    case reloadAll
    case rows(IndexSet)
}

/// 查询需要的上下文，整体传给后台
struct QueryContext: Sendable {
    var sidebar: SidebarItem
    var search: String
    var sort: ColumnKey
    var ascending: Bool
    var rules: ProblemRules
    var ledger: ProblemLedger
    var hostToSite: [String: String]
    var siteNames: [String: String]
    var serverNames: [String: String]
    var noHealthServers: Set<String>
    /// 连不上的下载器：它们的种子不算进总览
    var offlineServers: Set<String>
    var hidden: Set<TorrentRef>
}

/// 所有服务器种子的合并视图（主线程）。
/// 大数组都不进 SwiftUI 观察：SwiftUI 只看计数和版本号，表格（NSTableView / UITableView）通过 observeUpdates 刷新。
@MainActor @Observable
final class TorrentStore {
    private(set) var visibleCount = 0
    private(set) var counts = SidebarCounts()
    private(set) var triage = Triage()
    private(set) var siteSummary: SiteSummary?
    /// 选中的种子任意一个变化就 +1，详情面板靠它刷新
    private(set) var selectionRevision = 0
    /// 每次查询完成 +1
    private(set) var revision = 0

    var sidebar: SidebarItem = .all {
        didSet {
            guard sidebar != oldValue else { return }
            Log.info("sidebar \(oldValue) → \(sidebar)")
            selection = []
            requery(force: true)
        }
    }
    var search = "" { didSet { if search != oldValue { requery(force: true) } } }
    var sortColumn: ColumnKey = .added { didSet { if sortColumn != oldValue { requery(force: true) } } }
    var ascending = false { didSet { if ascending != oldValue { requery(force: true) } } }
    var selection: Set<TorrentRef> = [] { didSet { selectionRevision += 1 } }

    @ObservationIgnored var rules = ProblemRules(keywords: [], longSeconds: 6 * 3600, now: 0)
    @ObservationIgnored var hostToSite: [String: String] = [:]
    @ObservationIgnored var siteNames: [String: String] = [:]
    @ObservationIgnored var serverNames: [String: String] = [:]
    @ObservationIgnored var noHealthServers: Set<String> = []
    @ObservationIgnored var offlineServers: Set<String> = []
    @ObservationIgnored private(set) var ledger = ProblemLedger()
    @ObservationIgnored var ledgerDirty = false

    @ObservationIgnored private(set) var order: [TorrentRef] = []
    @ObservationIgnored private(set) var all: [TorrentRef: Torrent] = [:]
    /// 出现过的 qB 分类（多选条的分类菜单用）。`all` 不参与观察，单独维护一份才能及时刷新菜单
    private(set) var categories: [String] = []
    @ObservationIgnored private(set) var cross: [TorrentRef: Int] = [:]
    @ObservationIgnored private var rowIndex: [TorrentRef: Int] = [:]
    /// qB 列表接口没有报错原文，单独查回来的存这里，合并时补上
    @ObservationIgnored private var messages: [TorrentRef: String] = [:]
    /// 有 tracker 问题但还没有报错原文的种子（后台补查用）
    @ObservationIgnored private(set) var needsMessage = Set<TorrentRef>()
    /// 等待删除（10 秒撤销窗口）的种子，查询时隐藏
    @ObservationIgnored private(set) var hidden = Set<TorrentRef>()

    /// 表格刷新的监听者。iOS 上「种子」和「搜索」两个标签各有一张表，只留一个回调的话后建的会顶掉先建的，
    /// 先建的那张表就不再刷新（筛选后列表不变、点进去详情对不上行）
    private struct UpdateListener { weak var owner: AnyObject?; let handler: (TableUpdate) -> Void }
    @ObservationIgnored private var updateListeners: [UpdateListener] = []
    /// 下载完成（进度从 <100% 到 100%）。全量同步不算
    @ObservationIgnored var onCompleted: (([Torrent]) -> Void)?
    /// 出现了站点表里没有的 tracker 域名
    @ObservationIgnored var onNewHosts: ((Set<String>) -> Void)?

    @ObservationIgnored private var pendingChanged = Set<TorrentRef>()
    @ObservationIgnored private var queryInFlight = false
    @ObservationIgnored private var queryDirty = false
    @ObservationIgnored private var forceReload = false

    /// 注册表格刷新回调；owner 释放后自动移除，同一个 owner 重复注册会替换
    func observeUpdates(_ owner: AnyObject, _ handler: @escaping (TableUpdate) -> Void) {
        updateListeners.removeAll { $0.owner == nil || $0.owner === owner }
        updateListeners.append(UpdateListener(owner: owner, handler: handler))
    }

    private func emit(_ update: TableUpdate) {
        updateListeners.removeAll { $0.owner == nil }
        for l in updateListeners { l.handler(update) }
    }

    func torrent(_ ref: TorrentRef) -> Torrent? { all[ref] }
    func row(of ref: TorrentRef) -> Int? { rowIndex[ref] }
    func siteID(of t: Torrent) -> String { hostToSite[t.trackerHost] ?? t.trackerHost }
    func firstSeen(_ ref: TorrentRef) -> Int64? { ledger.firstSeen(ref) }
    func loadLedger(_ l: ProblemLedger) { ledger = l }

    // MARK: - 合并

    func apply(server: ServerID, changeSet cs: ChangeSet, changed: [Torrent]) {
        if cs.isFull {
            let incoming = Set(changed.map(\.ref))
            for ref in all.keys where ref.server == server && !incoming.contains(ref) { drop(ref) }
            forceReload = true
        }
        for ref in cs.removed { drop(ref) }
        var selectedChanged = false
        var completed: [Torrent] = []
        var newHosts = Set<String>()
        let now = Int64(Date().timeIntervalSince1970)
        for var t in changed {
            if !cs.isFull, let old = all[t.ref], old.progress < 1, t.progress >= 1 { completed.append(t) }
            let problem = rules.isProblem(t) || t.trackerHealth == .trackerWarning
            if problem {
                if t.errorMessage.isEmpty, let m = messages[t.ref] { t.errorMessage = m }
            } else {
                messages[t.ref] = nil
            }
            if problem && t.errorMessage.isEmpty { needsMessage.insert(t.ref) } else { needsMessage.remove(t.ref) }
            // 问题账本：第一次看到有问题时记时间，恢复正常就清掉
            let key = ProblemLedger.key(t.ref)
            if rules.isProblem(t) {
                if ledger.firstSeen[key] == nil { ledger.firstSeen[key] = now; ledgerDirty = true }
            } else if ledger.firstSeen.removeValue(forKey: key) != nil {
                ledgerDirty = true
            }
            if ledger.kept.contains(key), !rules.isUnregistered(t) { ledger.kept.remove(key); ledgerDirty = true }
            if !t.trackerHost.isEmpty, hostToSite[t.trackerHost] == nil { newHosts.insert(t.trackerHost) }
            all[t.ref] = t
            pendingChanged.insert(t.ref)
            if selection.contains(t.ref) { selectedChanged = true }
        }
        if selectedChanged { selectionRevision += 1 }
        noteCategories(changed.lazy.map(\.category))
        if !completed.isEmpty { onCompleted?(completed) }
        if !newHosts.isEmpty { onNewHosts?(newHosts) }
        if !cs.removed.isEmpty { forceReload = true }
        if !changed.isEmpty || !cs.removed.isEmpty || cs.isFull { requery() }
    }

    private func drop(_ ref: TorrentRef) {
        all[ref] = nil
        messages[ref] = nil
        needsMessage.remove(ref)
        hidden.remove(ref)
        if ledger.firstSeen.removeValue(forKey: ProblemLedger.key(ref)) != nil { ledgerDirty = true }
        if ledger.kept.remove(ProblemLedger.key(ref)) != nil { ledgerDirty = true }
    }

    /// 清理时保留的辅种：标记后不再算作待处理
    func markKept(_ refs: some Sequence<TorrentRef>) {
        for r in refs { ledger.kept.insert(ProblemLedger.key(r)) }
        ledgerDirty = true
        requery(force: true)
    }

    func unmarkKept(_ refs: some Sequence<TorrentRef>) {
        for r in refs { ledger.kept.remove(ProblemLedger.key(r)) }
        ledgerDirty = true
        requery(force: true)
    }

    func removeServer(_ server: ServerID) {
        for ref in all.keys where ref.server == server { drop(ref) }
        selection = selection.filter { $0.server != server }
        requery(force: true)
    }

    func setMessage(_ message: String, for ref: TorrentRef) {
        messages[ref] = message
        needsMessage.remove(ref)
        guard var t = all[ref], t.errorMessage != message else { return }
        t.errorMessage = message
        all[ref] = t
        pendingChanged.insert(ref)
        if selection.contains(ref) { selectionRevision += 1 }
        requery()
    }

    /// 本地先改，等下次同步确认（批量操作后让界面立即有反馈）
    func patchLocally(_ refs: some Sequence<TorrentRef>, _ change: (inout Torrent) -> Void) {
        for ref in refs {
            guard var t = all[ref] else { continue }
            change(&t)
            all[ref] = t
            pendingChanged.insert(ref)
            noteCategories(CollectionOfOne(t.category))
        }
        selectionRevision += 1
        requery()
    }

    private func noteCategories(_ cats: some Sequence<String>) {
        var new: Set<String> = []
        for c in cats where !c.isEmpty && !categories.contains(c) { new.insert(c) }
        if !new.isEmpty { categories = (categories + new).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    func hide(_ refs: some Sequence<TorrentRef>) {
        hidden.formUnion(refs)
        selection.subtract(hidden)
        requery(force: true)
    }

    func unhide(_ refs: some Sequence<TorrentRef>) {
        hidden.subtract(refs)
        requery(force: true)
    }

    // MARK: - 查询

    var context: QueryContext {
        QueryContext(sidebar: sidebar, search: search, sort: sortColumn, ascending: ascending, rules: rules, ledger: ledger,
                     hostToSite: hostToSite, siteNames: siteNames, serverNames: serverNames,
                     noHealthServers: noHealthServers, offlineServers: offlineServers, hidden: hidden)
    }

    /// 重新过滤排序，放到后台算；正在算的时候再来的请求合并成一次。
    /// `all` 和 `order` 是写时复制的，传给后台是 O(1)。
    func requery(force: Bool = false) {
        if force { forceReload = true }
        if queryInFlight { queryDirty = true; return }
        queryInFlight = true
        rules.now = Int64(Date().timeIntervalSince1970)
        let all = all, oldOrder = order, ctx = context
        let changed = pendingChanged
        pendingChanged = []
        let force = forceReload
        forceReload = false
        Task {
            let r = await Task.detached(priority: .userInitiated) { Self.compute(all: all, oldOrder: oldOrder, ctx: ctx, force: force) }.value
            self.finish(r, changed)
        }
    }

    private struct Result: Sendable {
        var order: [TorrentRef]?
        var rowIndex: [TorrentRef: Int]?
        var counts: SidebarCounts
        var triage: Triage
        var cross: [TorrentRef: Int]
        var siteSummary: SiteSummary?
    }

    nonisolated private static func compute(all: [TorrentRef: Torrent], oldOrder: [TorrentRef], ctx: QueryContext, force: Bool) -> Result {
        let r = ctx.rules
        let site = { (t: Torrent) in ctx.hostToSite[t.trackerHost] ?? t.trackerHost }
        var c = SidebarCounts()
        var byHash: [String: Int] = [:], byName: [String: Int] = [:]
        var sum: SiteSummary?
        if case .site(let sid) = ctx.sidebar { sum = SiteSummary(siteID: sid) }
        var hostsSeen = Set<String>()
        for t in all.values where !ctx.hidden.contains(t.ref) {
            c.total += 1
            if t.uploadSpeed > 0 || t.downloadSpeed > 0 { c.active += 1 }
            let fs = ctx.ledger.firstSeen(t.ref)
            let rejected = r.isRejected(t), longUnreach = r.isLongUnreachable(t, firstSeen: fs)
            if rejected { c.rejected += 1; if r.isUnregistered(t) { c.unregistered += 1 } }
            if t.trackerHealth == .unreachable { if longUnreach { c.unreachableLong += 1 } else { c.unreachableTransient += 1 } }
            if ctx.noHealthServers.contains(t.ref.server.rawValue) { c.noHealth += 1 }
            if let g = StateGroup.of(t.state) { c.states[g, default: 0] += 1 }
            c.servers[t.ref.server.rawValue, default: 0] += 1
            let s = site(t)
            if !s.isEmpty {
                c.sites[s, default: 0] += 1
                if rejected || longUnreach { c.siteProblems[s, default: 0] += 1 }
                c.siteSize[s, default: 0] += t.totalSize
                c.siteUploaded[s, default: 0] += t.uploaded
                c.siteDownloaded[s, default: 0] += t.downloaded
            }
            if !t.category.isEmpty { c.categories[t.category, default: 0] += 1 }
            for tag in t.tags where !tag.isEmpty { c.tags[tag, default: 0] += 1 }
            if !t.infoHashV1.isEmpty { byHash[t.infoHashV1, default: 0] += 1 }
            if !t.name.isEmpty { byName[t.name, default: 0] += 1 }
            if sum != nil, s == sum!.siteID {
                sum!.total += 1
                if StateGroup.of(t.state) == .seeding { sum!.seeding += 1 }
                if rejected || longUnreach { sum!.problems += 1 }
                sum!.size += t.totalSize
                sum!.uploaded += t.uploaded
                sum!.uploadSpeed += t.uploadSpeed
                sum!.byServer[t.ref.server.rawValue, default: 0] += 1
                hostsSeen.insert(t.trackerHost)
            }
        }
        sum?.hosts = hostsSeen.sorted()

        // 辅种：同 infohash（跨服务器同一个种子），或者同名（不同站的同一份数据；不看大小，见 SharedData）
        var cross: [TorrentRef: Int] = [:]
        var tri = Triage()
        // 待清理的疑似未注册：它们之间互为辅种不算，要有清理范围以外的种子共用数据才会被保留（同 sharedWithKept）
        var unreg: [Torrent] = []
        for t in all.values where !ctx.hidden.contains(t.ref) {
            let n = max(byHash[t.infoHashV1] ?? 1, byName[t.name] ?? 1) - 1
            if n > 0 { cross[t.ref] = n }
            // 总览：只算在线的下载器
            guard !ctx.offlineServers.contains(t.ref.server.rawValue) else { continue }
            tri.downloadSpeed += t.downloadSpeed
            tri.uploadSpeed += t.uploadSpeed
            if t.uploadSpeed > 0 || t.downloadSpeed > 0 { tri.active += 1 }
            let fs = ctx.ledger.firstSeen(t.ref)
            let isUnreg = r.isUnregistered(t) && !ctx.ledger.isKept(t.ref)
            if isUnreg { unreg.append(t) }
            func add(_ p: inout Triage.Pile) {
                p.count += 1
                if !t.errorMessage.isEmpty { p.messages[t.errorMessage, default: 0] += 1 }
                let s = site(t)
                if !s.isEmpty { p.sites.insert(s) }
                if n > 0, !isUnreg { p.crossSeeded += 1 }
                if let fs { p.since = min(p.since ?? fs, fs) }
            }
            if r.isUnregistered(t) {
                if ctx.ledger.isKept(t.ref) { tri.kept += 1 } else { add(&tri.unregistered) }
            } else if r.isRejected(t) {
                add(&tri.rejected)
            } else if r.isLongUnreachable(t, firstSeen: fs) {
                add(&tri.unreachable)
            } else {
                switch StateGroup.of(t.state) {
                case .downloading: tri.downloading += 1
                case .seeding: tri.seeding += 1
                case .stopped: tri.stopped += 1
                default: tri.other += 1
                }
            }
        }
        var unregHash: [String: Int] = [:], unregName: [String: Int] = [:]
        for t in unreg {
            if !t.infoHashV1.isEmpty { unregHash[t.infoHashV1, default: 0] += 1 }
            unregName[t.name, default: 0] += 1
        }
        tri.unregistered.crossSeeded = unreg.filter { t in
            let outsideByHash = !t.infoHashV1.isEmpty && (byHash[t.infoHashV1] ?? 0) > (unregHash[t.infoHashV1] ?? 0)
            return outsideByHash || (byName[t.name] ?? 0) > (unregName[t.name] ?? 0)
        }.count

        let q = ctx.search.trimmingCharacters(in: .whitespaces)
        let test: (Torrent) -> Bool = { t in
            if ctx.hidden.contains(t.ref) { return false }
            if !q.isEmpty, !t.name.localizedCaseInsensitiveContains(q) { return false }
            switch ctx.sidebar {
            case .all: return true
            case .active: return t.uploadSpeed > 0 || t.downloadSpeed > 0
            case .rejected: return r.isRejected(t)
            case .unregistered: return r.isUnregistered(t)
            case .unreachable: return r.isLongUnreachable(t, firstSeen: ctx.ledger.firstSeen(t.ref))
            case .state(let g): return g.states.contains(t.state)
            case .server(let id): return t.ref.server.rawValue == id
            case .site(let id): return site(t) == id
            case .category(let name): return t.category == name
            case .tag(let name): return t.tags.contains(name)
            }
        }

        enum K { case n(Double), s(String) }
        func stateRank(_ s: TorrentState) -> Int {
            switch StateGroup.of(s) {
            case .downloading: 4
            case .seeding: 3
            case .waiting: 2
            case .stopped: 1
            default: 0
            }
        }
        // 文字列按不区分大小写排（否则「TR」会排在「qB」前面）
        let siteKey = ctx.siteNames.mapValues { $0.lowercased() }
        let serverKey = ctx.serverNames.mapValues { $0.lowercased() }
        func key(_ t: Torrent) -> K {
            switch ctx.sort {
            case .name: .s(t.nameSortKey)
            case .site: .s(siteKey[site(t)] ?? site(t))
            case .server: .s(serverKey[t.ref.server.rawValue] ?? "")
            case .status: .n(Double(stateRank(t.state)) * 1e12 + Double(t.uploadSpeed + t.downloadSpeed))
            case .uploaded: .n(Double(t.uploaded))
            case .ratio: .n(t.ratio)
            case .seedTime: .n(Double(t.seedingTime))
            case .size: .n(Double(t.totalSize))
            case .added: .n(Double(t.addedAt))
            case .problem: .n((r.isRejected(t) ? 2e12 : t.trackerHealth == .unreachable ? 1e12 : 0) + Double(r.now - (ctx.ledger.firstSeen(t.ref) ?? r.now)))
            case .message: .s(t.errorMessage.lowercased())
            case .cross: .n(Double(cross[t.ref] ?? 0))
            case .category: .s(t.category.lowercased())
            case .tags: .s(t.tags.joined(separator: ",").lowercased())
            case .path: .s(t.savePath)
            case .limit: .n(Double(t.uploadLimit))
            case .speedDown: .n(Double(t.downloadSpeed))
            case .speedUp: .n(Double(t.uploadSpeed))
            // 算不出剩余时间的排在最后（升序时）
            case .eta: .n(t.progress < 1 && t.eta > 0 ? Double(t.eta) : 1e15)
            case .peers: .n(Double(t.seeds) * 1e6 + Double(t.peers))
            }
        }
        var keyed: [(K, TorrentRef)] = all.values.filter(test).map { (key($0), $0.ref) }
        let asc = ctx.ascending
        keyed.sort { a, b in
            switch (a.0, b.0) {
            case (.n(let x), .n(let y)) where x != y: return (x < y) == asc
            case (.s(let x), .s(let y)) where x != y: return (x < y) == asc
            default:
                if a.1.server.rawValue != b.1.server.rawValue { return a.1.server.rawValue < b.1.server.rawValue }
                return a.1.id < b.1.id
            }
        }
        let order = keyed.map(\.1)
        if force || order != oldOrder {
            return Result(order: order, rowIndex: Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) }), counts: c, triage: tri, cross: cross, siteSummary: sum)
        }
        return Result(order: nil, rowIndex: nil, counts: c, triage: tri, cross: cross, siteSummary: sum)
    }

    private func finish(_ r: Result, _ changed: Set<TorrentRef>) {
        if r.counts != counts { counts = r.counts }
        if r.triage != triage { triage = r.triage }
        if r.siteSummary != siteSummary { siteSummary = r.siteSummary }
        cross = r.cross
        if let newOrder = r.order, let index = r.rowIndex {
            order = newOrder
            rowIndex = index
            visibleCount = newOrder.count
            emit(.reloadAll)
        } else if !changed.isEmpty {
            var rows = IndexSet()
            for ref in changed { if let i = rowIndex[ref] { rows.insert(i) } }
            if !rows.isEmpty { emit(.rows(rows)) }
        }
        revision += 1
        queryInFlight = false
        if queryDirty {
            queryDirty = false
            requery()
        }
    }
}

// 删除确认（mac / iOS 共用）
extension TorrentStore {
    /// 和「删除范围之外」的种子共用数据的那些。
    /// 同一个种子在另一台下载器上的副本如果也在删除范围里，就不算（它本来也要一起清理）
    func sharedWithKept(_ ts: [Torrent]) -> Set<TorrentRef> {
        // 不看 cross：它是后台算出来的缓存，刚加进来的辅种还不在里面
        SharedData.protected(ts, among: all.values)
    }
}
