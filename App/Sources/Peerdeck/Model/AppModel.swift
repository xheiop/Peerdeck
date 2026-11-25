#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import SyncEngine
import TorrentKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo = false
}

/// 正在 10 秒撤销窗口里的删除
struct PendingDeletion {
    var refs: [TorrentRef]
    /// 这些连文件一起删；其余只删种子（辅种的文件一定保留）
    var dataRefs: Set<TorrentRef>
    /// 这次清理里因为有辅种而标记保留的（撤销时一起取消标记）
    var keptRefs: [TorrentRef] = []
    /// 是总览里「清理疑似未注册」发起的
    var cleanup = false
    var label: String
    var secondsLeft = 10
}

enum ActiveSheet: Identifiable {
    case add(AddDraft)
    case delete(refs: [TorrentRef], cleanup: Bool)
    case retracker(RetrackerDraft)
    /// 更改保存位置（qB setLocation / TR torrent-set-location / Flood move）
    case setLocation(refs: [TorrentRef])
    /// 种子改名
    case renameTorrent(TorrentRef)
    case setup
    /// 清理「疑似未注册」：按原话分组，自动保留有辅种的
    case cleanup

    var id: String {
        switch self {
        case .add(let d): "add-\(d.id)"
        case .delete(let r, let c): "delete-\(c)-\(r.count)"
        case .retracker(let d): "retracker-\(d.id)"
        case .renameTorrent(let r): "rename-\(r.server.rawValue)/\(r.id)"
        case .setLocation(let r): "location-\(r.count)-\(r.first.map { "\($0.server.rawValue)/\($0.id)" } ?? "")"
        case .setup: "setup"
        case .cleanup: "cleanup"
        }
    }
}

struct LocationContext {
    var torrents: [Torrent]
    /// 选中的种子都在同一个目录时是这个目录，否则是 nil
    var commonPath: String?
    var cross: Int
    /// 「只改路径、不移动文件」时会被跳过的个数（qB，以及 Flood 后面不是 rTorrent / TR 的）
    var cannotRelocate: Int

    /// 面板打开时预填的路径：同一个目录就填它，否则填最近用过的
    func initialPath(recent: [String]) -> String { commonPath ?? recent.first ?? "" }

    func canApply(_ path: String, moveFiles: Bool) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !torrents.isEmpty else { return false }
        if p == commonPath { return false }
        return moveFiles || cannotRelocate < torrents.count
    }
}

enum TagMode: String, CaseIterable { case add, remove, replace }

@MainActor @Observable
final class AppModel {
    let store = TorrentStore()
    private(set) var servers: [ServerRuntime] = []
    var prefs = AppPrefs() { didSet { prefsChanged() } }
    /// 用户自己填的 TMDB 密钥（Keychain）。分享扩展用不到，不读
    var tmdbKey = ""
    var sheet: ActiveSheet?
    var toast: Toast?
    var alert: String?
    /// mac：检查更新的结果，主窗口弹出
    var updateNotice: UpdateCheck.Outcome?
    var showInspector = false
    var showSpeedLimits = false
    /// iOS：当前标签页（overview / torrents / sites / servers / search）
    var selectedTab = "overview"
    private(set) var pending: PendingDeletion?

    @ObservationIgnored let configStore: any ConfigStore
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    /// iOS：app 在前台时为 true（由 scenePhase 设置）。mac 直接看 NSApp.isActive
    @ObservationIgnored var foreground = true
    @ObservationIgnored private var messageFetchInFlight = Set<TorrentRef>()
    @ObservationIgnored private var messageFetchTried = Set<TorrentRef>()
    /// 被 tracker 拒绝、但还没查过报错原文的种子数。查完之前「疑似未注册」会继续增加
    private(set) var pendingMessageCount = 0
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var prefsSaveTask: Task<Void, Never>?
    /// 设置窗口里要直接选中的服务器（从横幅「编辑服务器…」进来时）
    var settingsServerFocus: String?
    var settingsTab = "servers"

    /// true：只连接服务器、不同步种子，也不跑后台任务（Share Extension 用）
    @ObservationIgnored let lightweight: Bool

    init(configStore: any ConfigStore, lightweight: Bool = false) {
        self.configStore = configStore
        self.lightweight = lightweight
        store.onCompleted = { [weak self] torrents in
            guard let self, self.prefs.notifyDone else { return }
            for t in torrents {
                Notifier.post(title: L("Download Complete"), body: t.name, subtitle: self.server(t.ref.server.rawValue)?.config.name)
            }
        }
        store.onNewHosts = { [weak self] hosts in self?.registerHosts(hosts) }
    }

    // MARK: - 加载

    func load() {
        if !lightweight { tmdbKey = TMDBKeyStore.load() }
        var loaded = AppData.load("prefs.json", as: AppPrefs.self) ?? AppPrefs()
        // 站点名猜法改过（a.b.c 取 b）：名字还是旧猜法自动起的就换成新的，用户改过的不动
        for i in loaded.sites.indices {
            let s = loaded.sites[i]
            if s.name == SiteConfig.legacyGuessName(s.id) { loaded.sites[i].name = SiteConfig.guessName(s.id) }
        }
        prefs = loaded
        store.loadLedger(AppData.load("ledger.json", as: ProblemLedger.self) ?? ProblemLedger())
        applyPrefsToStore()
        do {
            let configs = try configStore.load()
            servers.forEach { $0.stop() }
            servers = configs.map(makeRuntime)
            servers.forEach { $0.start() }
            refreshServerMaps()
            Log.info("加载了 \(configs.count) 台服务器")
        } catch {
            alert = L("Couldn’t load server settings: \(String(describing: error))")
        }
        guard !lightweight else { return }
        startBackgroundLoop()
        DebugHooks.install(self)
    }

    /// 轮询间隔：前台用设置里的「前台刷新」，mac 在后台用「后台刷新」，iOS 进后台就不轮询
    var pollInterval: Duration {
        #if os(macOS)
        NSApp.isActive ? .seconds(prefs.refreshForeground) : .seconds(prefs.refreshBackground)
        #else
        // 系统也会挂起 app。回到前台时 setForeground 会立即唤醒
        foreground ? .seconds(prefs.refreshForeground) : .seconds(3600)
        #endif
    }

    private func makeRuntime(_ c: ServerConfig) -> ServerRuntime {
        let rt = ServerRuntime(config: c, store: lightweight ? nil : store) { [weak self] in
            self?.pollInterval ?? .seconds(2)
        }
        rt.onStatusChange = { [weak self] in self?.refreshServerMaps() }
        rt.syncTorrents = !lightweight
        return rt
    }

    private func prefsChanged() {
        applyPrefsToStore()
        prefsSaveTask?.cancel()
        let snapshot = prefs
        prefsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { AppData.save(snapshot, as: "prefs.json") }
        }
    }

    private func applyPrefsToStore() {
        store.rules = ProblemRules.current(prefs)
        var hostToSite: [String: String] = [:], names: [String: String] = [:]
        for s in prefs.sites {
            names[s.id] = s.name
            for h in s.hosts { hostToSite[h] = s.id }
        }
        let changed = hostToSite != store.hostToSite || names != store.siteNames
        store.hostToSite = hostToSite
        store.siteNames = names
        if changed { store.requery(force: true) }
    }

    func refreshServerMaps() {
        store.serverNames = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.config.name) })
        // 列表里没有可信的 tracker 状态：qB 5.1.x；Flood 后面接的是 qB（报错缓存 1 小时）、Deluge 等
        store.noHealthServers = Set(servers.filter { rt in
            guard let info = rt.info, !info.capabilities.contains(.trackerHealthInList) else { return false }
            return info.kind == .flood || (info.kind == .qbittorrent && info.apiVersion > SemVer(2, 11, 2))
        }.map(\.id))
        // 连不上 / 证书待确认 / 停用的下载器：它们的种子不算进总览
        let offline = Set(servers.filter { rt in
            switch rt.status {
            case .failed, .needsTrust, .stopped: true
            default: false
            }
        }.map(\.id))
        if offline != store.offlineServers {
            store.offlineServers = offline
            store.requery(force: true)
        }
    }

    // MARK: - 服务器

    func server(_ id: String) -> ServerRuntime? { servers.first { $0.id == id } }
    var onlineServers: [ServerRuntime] { servers.filter { $0.status.isOnline } }
    var failedServers: [ServerRuntime] { servers.filter { if case .failed = $0.status { true } else { false } } }

    private func persistServers() {
        do { try configStore.save(servers.map(\.config)) } catch { alert = L("Couldn’t save server settings: \(String(describing: error))") }
    }

    func upsert(_ config: ServerConfig) {
        if let rt = server(config.id) {
            rt.update(config)
        } else {
            let rt = makeRuntime(config)
            servers.append(rt)
            rt.start()
        }
        persistServers()
        refreshServerMaps()
    }

    func remove(_ id: String) {
        guard let rt = server(id) else { return }
        rt.stop()
        store.removeServer(rt.serverID)
        servers.removeAll { $0.id == id }
        persistServers()
        refreshServerMaps()
    }

    func trust(serverID: String, endpoint: Endpoint, fingerprint: String) {
        guard var c = server(serverID)?.config,
              let i = c.endpoints.firstIndex(where: { $0.baseURL == endpoint.baseURL }) else { return }
        c.endpoints[i].pinnedCertificateSHA256 = fingerprint
        upsert(c)
    }

    var totalDown: Int64 { servers.reduce(0) { $0 + ($1.status.isOnline ? $1.stats.downloadSpeed : 0) } }
    var totalUp: Int64 { servers.reduce(0) { $0 + ($1.status.isOnline ? $1.stats.uploadSpeed : 0) } }
    var altSpeedCount: Int { servers.filter { $0.status.isOnline && $0.stats.altSpeedEnabled }.count }

    func setAltSpeed(_ on: Bool, server id: String? = nil) {
        for rt in servers where rt.status.isOnline && rt.config.kind.hasAlternativeSpeedLimits && (id == nil || rt.id == id) {
            guard let client = rt.client else { continue }
            Task {
                do { try await client.setAltSpeed(on); rt.refreshNow() } catch { self.alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
        }
    }

    // MARK: - 站点

    func site(_ id: String) -> SiteConfig? { prefs.sites.first { $0.id == id } }
    func siteName(_ id: String) -> String { site(id)?.name ?? (id.isEmpty ? "—" : SiteConfig.guessName(id)) }
    func siteID(of t: Torrent) -> String { store.siteID(of: t) }

    private func registerHosts(_ hosts: Set<String>) {
        let known = Set(prefs.sites.flatMap(\.hosts))
        let fresh = hosts.subtracting(known).sorted()
        guard !fresh.isEmpty else { return }
        prefs.sites += fresh.map { SiteConfig(id: $0, name: SiteConfig.guessName($0), hosts: [$0], defaultServer: nil) }
    }

    /// 站点换了域名：新域名放到最前，旧域名留作别名
    func siteMoved(_ siteID: String, from old: String, to new: String) {
        guard let i = prefs.sites.firstIndex(where: { $0.id == siteID }) else { return }
        var hosts = prefs.sites[i].hosts.filter { $0 != new }
        hosts.insert(new, at: 0)
        if !hosts.contains(old) { hosts.append(old) }
        prefs.sites[i].hosts = hosts
        // 如果新域名之前被自动识别成了另一个站点，合并掉
        prefs.sites.removeAll { $0.id != siteID && $0.hosts == [new] }
    }

    // MARK: - 操作

    private func grouped(_ refs: some Collection<TorrentRef>) -> [(ServerRuntime, any TorrentClient, [TorrentRef])] {
        Dictionary(grouping: refs, by: \.server).compactMap { sid, refs in
            guard let rt = server(sid.rawValue), let c = rt.client else { return nil }
            return (rt, c, refs)
        }
    }

    func perform(_ action: TorrentAction, on refs: some Collection<TorrentRef>) {
        let groups = grouped(refs)
        if groups.count < Set(refs.map(\.server)).count { alert = L("Some servers are offline; their torrents weren’t changed.") }
        for (rt, client, refs) in groups {
            Task {
                do { try await client.perform(action, on: refs.map(\.id)); rt.refreshNow() } catch { self.alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
        }
    }

    /// 选中的种子是不是全都停着（决定工具栏显示「开始」还是「停止」）
    var selectionAllStopped: Bool {
        let sel = store.selection.compactMap { store.torrent($0) }
        return !sel.isEmpty && sel.allSatisfy { $0.state == .stopped }
    }

    func toggleRun(_ refs: some Collection<TorrentRef>) {
        let ts = refs.compactMap { store.torrent($0) }
        let start = !ts.isEmpty && ts.allSatisfy { $0.state == .stopped }
        perform(start ? .start : .stop, on: refs)
        showToast(start ? L("Started \(Fmt.torrents(ts.count))") : L("Stopped \(Fmt.torrents(ts.count))"))
    }

    func setCategory(_ category: String, on refs: [TorrentRef]) {
        var done = 0, skipped = 0
        let total = refs.count
        Task {
            for (rt, client, refs) in grouped(refs) {
                guard rt.info?.capabilities.contains(.categories) == true else { skipped += refs.count; continue }
                do {
                    try await client.setCategory(category, on: refs.map(\.id))
                    done += refs.count
                    store.patchLocally(refs) { $0.category = category }
                    rt.refreshNow()
                } catch { alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
            var parts = [category.isEmpty ? L("Cleared the category of \(Fmt.torrents(done))") : L("Moved \(Fmt.torrents(done)) to category \(category)")]
            if skipped > 0 { parts.append(L("skipped \(skipped) (only qBittorrent has categories)")) }
            if done + skipped < total { parts.append(L("some servers are offline")) }
            showToast(parts.joined(separator: L("; ")))
        }
    }

    func updateTags(_ tags: [String], mode: TagMode, on refs: [TorrentRef]) {
        Task {
            var n = 0
            for (rt, client, refs) in grouped(refs) {
                let changes = refs.compactMap { ref -> TagChange? in
                    guard let t = store.torrent(ref) else { return nil }
                    let final: [String] = switch mode {
                    case .add: Array(Set(t.tags).union(tags)).sorted()
                    case .remove: t.tags.filter { !tags.contains($0) }
                    case .replace: tags
                    }
                    return TagChange(id: ref.id, current: t.tags, final: final)
                }
                do {
                    try await client.updateTags(changes)
                    n += changes.count
                    let finals = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.final) })
                    store.patchLocally(refs) { $0.tags = finals[$0.ref.id] ?? $0.tags }
                    rt.refreshNow()
                } catch { alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
            showToast(L("Updated tags on \(Fmt.torrents(n))"))
        }
    }

    func setUploadLimit(_ bps: Int64, on refs: [TorrentRef]) {
        Task {
            var n = 0, skipped = 0
            for (rt, client, refs) in grouped(refs) {
                guard rt.config.kind.hasTorrentUploadLimit else { skipped += refs.count; continue }
                do {
                    try await client.setUploadLimit(bps, on: refs.map(\.id))
                    n += refs.count
                    store.patchLocally(refs) { $0.uploadLimit = bps }
                    rt.refreshNow()
                } catch { alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
            var parts = [bps > 0 ? L("Set upload limit of \(Fmt.torrents(n)) to \(Fmt.speed(bps))") : L("Removed upload limit from \(Fmt.torrents(n))")]
            if skipped > 0 { parts.append(L("skipped \(skipped) (Flood has no per-torrent limits)")) }
            showToast(parts.joined(separator: L("; ")))
        }
    }

    func move(_ path: String, moveFiles: Bool, on refs: [TorrentRef]) {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        Task {
            var n = 0, skipped = 0
            for (rt, client, refs) in grouped(refs) {
                if !moveFiles, rt.info?.capabilities.contains(.relocateWithoutMove) != true { skipped += refs.count; continue }
                do {
                    try await client.setLocation(path, moveFiles: moveFiles, on: refs.map(\.id))
                    n += refs.count
                    rt.refreshNow()
                } catch { alert = Fmt.labeled(rt.config.name, "\(error)") }
            }
            rememberPath(path)
            var parts = [moveFiles ? L("The client is moving \(Fmt.torrents(n)) to \(path)") : L("Changed the path of \(Fmt.torrents(n)) to \(path)")]
            if skipped > 0 { parts.append(L("skipped \(skipped) (the client always moves files when changing the path)")) }
            showToast(parts.joined(separator: L("; ")))
        }
    }

    func requestSetLocation(_ refs: some Collection<TorrentRef>) {
        guard !refs.isEmpty else { return }
        sheet = .setLocation(refs: Array(refs))
    }

    /// 更改保存位置面板要用的信息：当前路径、辅种数、哪些下载器不支持「只改路径」
    func locationContext(_ refs: [TorrentRef]) -> LocationContext {
        let all = refs.compactMap { store.torrent($0) }
        let paths = Set(all.map(\.savePath))
        let cannotRelocate = all.filter { server($0.ref.server.rawValue)?.info?.capabilities.contains(.relocateWithoutMove) != true }.count
        return LocationContext(torrents: all, commonPath: paths.count == 1 ? paths.first : nil,
                               cross: all.filter { store.cross[$0.ref] != nil }.count, cannotRelocate: cannotRelocate)
    }

    func rememberPath(_ path: String) {
        guard !path.isEmpty else { return }
        prefs.recentPaths = [path] + prefs.recentPaths.filter { $0 != path }.prefix(9)
    }

    func trackers(for ref: TorrentRef) async throws -> [Tracker] {
        guard let client = server(ref.server.rawValue)?.client else { throw ClientError.notConnected }
        return try await client.trackers(of: ref.id)
    }

    func files(for ref: TorrentRef) async throws -> [ContentFile] {
        guard let client = server(ref.server.rawValue)?.client else { throw ClientError.notConnected }
        return try await client.files(of: ref.id)
    }

    /// 按显示顺序排好（正在传数据的在前）
    func peers(for ref: TorrentRef) async throws -> [Peer] {
        guard let client = server(ref.server.rawValue)?.client else { throw ClientError.notConnected }
        return try await client.peers(of: ref.id).sorted(by: Peer.displayOrder)
    }

    func setFilePriority(_ priority: FilePriority, files indices: [Int], of ref: TorrentRef) async throws {
        guard let rt = server(ref.server.rawValue), let client = rt.client else { throw ClientError.notConnected }
        try await client.setFilePriority(priority, files: indices, of: ref.id)
        rt.refreshNow()
    }

    // MARK: - 种子改名

    func requestRename(_ ref: TorrentRef) {
        guard supportsRename(ref) else { return }
        sheet = .renameTorrent(ref)
    }

    /// Flood 不能改名
    func supportsRename(_ ref: TorrentRef) -> Bool {
        server(ref.server.rawValue)?.info?.capabilities.contains(.renameTorrent) ?? false
    }

    /// 改名面板里的说明，以及（有辅种且会动磁盘时）的警告
    func renameNotes(_ ref: TorrentRef, newName: String) -> (info: String, warning: String?) {
        if !newName.isEmpty, let problem = TorrentRename.problem(newName) { return (problem, nil) }
        guard server(ref.server.rawValue)?.info?.capabilities.contains(.renameRenamesData) == true else {
            return (L("Only the name shown in the client changes. Files on disk aren’t touched."), nil)
        }
        let info = L("Transmission also renames the top-level file or folder on disk.")
        let warning = store.cross[ref] != nil ? L("This torrent is cross-seeded: after renaming, the other torrents won’t find this data.") : nil
        return (info, warning)
    }

    func canRename(_ ref: TorrentRef, to newName: String) -> Bool {
        guard let t = store.torrent(ref), TorrentRename.problem(newName) == nil else { return false }
        return newName.trimmingCharacters(in: .whitespacesAndNewlines) != t.name
    }

    func renameTorrent(_ ref: TorrentRef, to newName: String) {
        guard let rt = server(ref.server.rawValue), let client = rt.client, let t = store.torrent(ref) else {
            alert = L("Some servers are offline; their torrents weren’t changed."); return
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await client.renameTorrent(ref.id, currentName: t.name, to: name)
                store.patchLocally([ref]) { $0.name = name }
                rt.refreshNow()
                showToast(L("Renamed to \(name)"))
            } catch { alert = Fmt.labeled(rt.config.name, "\(error)") }
        }
    }

    /// 文件优先级有没有「低」这一档（TR 有，qB 没有）
    func supportsLowFilePriority(_ ref: TorrentRef) -> Bool {
        server(ref.server.rawValue)?.info?.capabilities.contains(.lowFilePriority) ?? false
    }

    // MARK: - 删除（10 秒撤销）

    func requestDelete(_ refs: some Collection<TorrentRef>, cleanup: Bool = false) {
        guard !refs.isEmpty else { return }
        sheet = .delete(refs: Array(refs), cleanup: cleanup)
    }

    func scheduleDelete(_ refs: [TorrentRef], deleteDataFor dataRefs: Set<TorrentRef>, label: String, keep keptRefs: [TorrentRef] = [], cleanup: Bool = false) {
        commitPending()
        store.hide(refs)
        if !keptRefs.isEmpty { store.markKept(keptRefs) }
        pending = PendingDeletion(refs: refs, dataRefs: dataRefs, keptRefs: keptRefs, cleanup: cleanup, label: label)
        updatePendingToast()
        pendingTask = Task {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                pending?.secondsLeft -= 1
                updatePendingToast()
            }
            commitPending()
        }
    }

    private func updatePendingToast() {
        guard let p = pending else { return }
        toastTask?.cancel()
        toast = Toast(text: L("Deleting \(p.label) in \(p.secondsLeft) s"), undo: true)
    }

    /// 现在没法核对数据有没有被共用的下载器（离线、停用、还没载入完）。有的话只能保留文件
    var fileCheckBlockers: [String] {
        servers.filter { !$0.status.isOnline || !$0.loaded }.map(\.config.name)
    }

    /// 让这些下载器马上再同步一次，返回确实同步成功的。连不上的不等
    private func freshlySynced(_ ids: Set<ServerID>) async -> Set<ServerID> {
        let asked = ContinuousClock.now
        let deadline = asked + .seconds(15)
        while true {
            var fresh = Set<ServerID>()
            var waiting = false
            for rt in servers where ids.contains(rt.serverID) {
                if rt.status.isOnline, let at = rt.syncedAt, at >= asked {
                    fresh.insert(rt.serverID)
                } else if rt.status.isOnline || rt.status == .connecting {
                    waiting = true
                    rt.refreshNow()
                }
            }
            if !waiting || ContinuousClock.now >= deadline { return fresh }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// 撤销窗口结束（或者又发起了一次删除）：真正发请求
    private func commitPending() {
        pendingTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        Task {
            // 10 秒里（app 被挂起时可能是几小时）什么都可能变：连文件删、清理都要先重新同步，按现在的情况再核对一次
            var fresh = Set<ServerID>()
            if !p.dataRefs.isEmpty {
                fresh = await freshlySynced(Set(servers.map(\.serverID)))
            } else if p.cleanup {
                fresh = await freshlySynced(Set(p.refs.map(\.server)))
            }
            let rules = store.rules
            let plan = DeletionDecision.resolve(
                // 只删种子、不动文件时不用核对（按 hash 删，不会删到别的种子），fresh 是空的：
                // 还在的照删；已经不在列表里的（比如刚改了服务器配置）算没删，不能报成功
                refs: p.refs, wantsData: p.dataRefs, torrents: store.all, fresh: fresh,
                allServers: Set(servers.map(\.serverID)),
                stillEligible: p.cleanup ? { rules.isUnregistered($0) } : nil
            )
            let keep = plan.remove.filter { !plan.removeData.contains($0) }

            // 等请求结果再提示；没删掉的（服务器不在线、请求失败）放回列表，不然会一直藏着
            var failed: [TorrentRef] = []
            var errors: [String] = []
            for (withData, refs) in [(false, keep), (true, Array(plan.removeData))] where !refs.isEmpty {
                let groups = grouped(refs)
                let reachable = Set(groups.flatMap { $0.2 })
                failed += refs.filter { !reachable.contains($0) }
                for (rt, client, rs) in groups {
                    do {
                        try await client.perform(.delete(withData: withData), on: rs.map(\.id))
                        rt.refreshNow()
                    } catch {
                        failed += rs
                        errors.append(Fmt.labeled(rt.config.name, "\(error)"))
                    }
                }
            }
            if !plan.skipped.isEmpty || !failed.isEmpty { store.unhide(plan.skipped + failed) }

            var notes: [String] = []
            if !failed.isEmpty {
                notes.append(L("\(Fmt.torrents(failed.count)) couldn’t be deleted and are back in the list.") + (errors.isEmpty ? L("Their servers are offline.") : "\n" + errors.joined(separator: "\n")))
            }
            if !plan.skipped.isEmpty {
                notes.append(L("\(Fmt.torrents(plan.skipped.count)) weren’t deleted and are back in the list: they have recovered or couldn’t be checked again."))
            }
            if plan.filesKept > 0 {
                notes.append(L("Files of \(Fmt.torrents(plan.filesKept)) were kept: other torrents may use them, or not every server could be checked."))
            }
            if notes.isEmpty {
                showToast(L("Deleted \(p.label)"))
            } else {
                alert = notes.joined(separator: "\n\n")
            }
        }
    }

    func undoDelete() {
        pendingTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        store.unhide(p.refs)
        if !p.keptRefs.isEmpty { store.unmarkKept(p.keptRefs) }
        showToast(L("Undone. Nothing was deleted."))
    }

    func showToast(_ text: String, seconds: Double = 3) {
        if pending != nil { return } // 撤销提示优先
        toastTask?.cancel()
        toast = Toast(text: text)
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }

    /// iOS：前后台切换。回到前台时让每台服务器立刻刷新一次
    func setForeground(_ on: Bool) {
        guard on != foreground else { return }
        foreground = on
        if on { servers.forEach { $0.refreshNow() } } else { saveLedgerNow() }
    }

    // MARK: - 添加

    func beginAdd(text: String = "", files: [URL] = []) {
        sheet = .add(AddDraft(model: self, text: text, files: files))
        #if os(macOS)
        NSApp.activate()
        #endif
        openMainWindow?()
    }

    func handleOpen(_ urls: [URL]) {
        let links = urls.filter { $0.scheme?.lowercased() == "magnet" }.map(\.absoluteString)
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" }
        guard !links.isEmpty || !files.isEmpty else { return }
        if case .add(let d) = sheet {
            d.append(text: links.joined(separator: "\n"), files: files)
        } else {
            beginAdd(text: links.joined(separator: "\n"), files: files)
        }
    }

    // MARK: - 后台：报错原文补查、账本保存

    private func startBackgroundLoop() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.fetchSomeMessages()
                tick += 1
                if tick % 15 == 0, let self, self.store.ledgerDirty {
                    self.store.ledgerDirty = false
                    AppData.save(self.store.ledger, as: "ledger.json")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func saveLedgerNow() {
        AppData.save(store.ledger, as: "ledger.json")
        store.ledgerDirty = false
    }

    /// qB 的列表接口没有 tracker 报错原文。对有问题的种子逐个查一次 trackers，每批 4 个并发
    private func fetchSomeMessages() async {
        updatePendingMessageCount()
        defer { updatePendingMessageCount() }
        let batch = Array(store.needsMessage.lazy
            .filter { !self.messageFetchTried.contains($0) && !self.messageFetchInFlight.contains($0) }
            .prefix(64))
        guard !batch.isEmpty else { return }
        for offset in stride(from: 0, to: batch.count, by: 4) {
            let chunk = batch[offset..<min(offset + 4, batch.count)]
            chunk.forEach { messageFetchInFlight.insert($0) }
            let jobs: [(TorrentRef, any TorrentClient)] = chunk.compactMap { ref in server(ref.server.rawValue)?.client.map { (ref, $0) } }
            let results = await withTaskGroup(of: (TorrentRef, String?).self) { group in
                for (ref, client) in jobs {
                    group.addTask {
                        let trackers = try? await client.trackers(of: ref.id)
                        let msg = trackers?.first { $0.status != .working && !$0.message.isEmpty }?.message
                            ?? trackers?.first { !$0.message.isEmpty }?.message
                        return (ref, msg)
                    }
                }
                var out: [(TorrentRef, String?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for ref in chunk {
                messageFetchInFlight.remove(ref)
                messageFetchTried.insert(ref)
            }
            for (ref, msg) in results { if let msg { store.setMessage(msg, for: ref) } }
        }
    }

    /// 只数被拒绝的：警告类种子不影响「疑似未注册」
    private func updatePendingMessageCount() {
        let rules = store.rules
        let n = store.needsMessage.lazy.filter { ref in
            !self.messageFetchTried.contains(ref) && (self.store.torrent(ref).map(rules.isRejected) ?? false)
        }.count
        if n != pendingMessageCount { pendingMessageCount = n }
    }
}

extension AppModel {
    /// 当前视图的标题（mac 窗口标题、iOS 导航栏共用）
    func title(for item: SidebarItem) -> String {
        switch item {
        case .all: L("All")
        case .active: L("Active")
        case .rejected: L("Rejected by Tracker")
        case .unregistered: L("Likely Unregistered")
        case .unreachable: L("Unreachable for Long")
        case .state(let g): g.title
        case .server(let id): server(id)?.config.name ?? L("Server")
        case .site(let id): siteName(id)
        case .category(let name): name
        case .tag(let name): name
        }
    }
}

/// 清理「疑似未注册」的方案：哪些移除、哪些因为有辅种保留，按原话分组
struct CleanupPlan {
    struct Group: Identifiable {
        var message: String
        var refs: [TorrentRef]
        /// 站点 → 个数，按个数从多到少
        var sites: [(String, Int)]
        var id: String { message }
    }
    var groups: [Group]
    var kept: [TorrentRef]
    /// 保留的辅种的数据还在哪些站做种
    var keptElsewhere: [String]
    var removable: [TorrentRef] { groups.flatMap(\.refs) }
}

extension AppModel {
    /// 在线下载器上、还没标记保留的疑似未注册种子
    func cleanupPlan() -> CleanupPlan {
        let rules = store.rules
        let offline = store.offlineServers
        let all = store.all.values.filter { t in
            !store.hidden.contains(t.ref) && !offline.contains(t.ref.server.rawValue)
                && rules.isUnregistered(t) && !store.ledger.isKept(t.ref)
        }
        let shared = store.sharedWithKept(Array(all))
        let kept = all.filter { shared.contains($0.ref) }
        let removable = all.filter { !shared.contains($0.ref) }
        var byMessage: [String: [Torrent]] = [:]
        for t in removable { byMessage[t.errorMessage, default: []].append(t) }
        let groups = byMessage.map { msg, ts in
            var sites: [String: Int] = [:]
            for t in ts { sites[siteName(store.siteID(of: t)), default: 0] += 1 }
            return CleanupPlan.Group(message: msg, refs: ts.map(\.ref), sites: sites.sorted { ($0.value, $1.key) > ($1.value, $0.key) })
        }.sorted { $0.refs.count > $1.refs.count }
        // 保留的那些：它们的数据还在哪些别的站做种
        let keptNames = Set(kept.map(\.name)), keptHashes = Set(kept.map(\.infoHashV1)).subtracting([""])
        let keptSet = Set(kept.map(\.ref))
        var elsewhere = Set<String>()
        for t in store.all.values where !keptSet.contains(t.ref) {
            if keptNames.contains(t.name) || keptHashes.contains(t.infoHashV1), !rules.isRejected(t) { elsewhere.insert(siteName(store.siteID(of: t))) }
        }
        return CleanupPlan(groups: groups, kept: kept.map(\.ref), keptElsewhere: elsewhere.sorted())
    }
}
