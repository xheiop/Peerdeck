import Foundation
import TorrentKit

/// qBittorrent WebUI API v2 适配器。
///
/// 实测行为（dev/compose.yaml 里的容器，2026-11）：
/// - 登录成功：4.6.7 返回 200 "Ok." + `SID`；5.3.0 返回 204 空 body + `QBT_SID_<端口>`
/// - 密码错误：4.6.7 和 5.3.0 都是 401（不是旧文档的 200 "Fails."）
/// - Host 头里的端口和 WebUI 端口不一致时，正确密码也是 401（Docker 端口映射、反代常见）
/// - 未登录或会话失效：403
/// - 5.0 起 pause/resume 改名 stop/start（webapi 2.11.0）
public actor QBittorrentClient: TorrentClient {
    public nonisolated let serverID: ServerID
    public nonisolated let kind: ClientKind = .qbittorrent

    private let transport: HTTPTransport
    private let credentials: Credentials
    /// API key：Authorization: Bearer qbt_…。实测 5.2.4 / 5.3.0 有，5.1.2 没有。
    /// 不需要登录、没有会话过期；但 Host 端口校验照样生效
    private let apiKey: String?
    private var cookie: String?
    private var rid = 0
    private var info: ServerInfo?
    /// 推算 tracker 健康度要用的字段。maindata 增量只下发变化的字段，所以要自己记住上一次的值。
    private var healthInputs: [String: HealthInputs] = [:]
    /// 由第一次全量数据里有没有 has_tracker_error 字段决定。实测 5.0.4 / 5.1.2 没有，5.2.4 / 5.3.0 有
    private var hasTrackerFlags = false
    /// tracker URL -> hash 集合，用来算每个种子的 announceURL
    private var hashesByTracker: [String: Set<String>] = [:]

    public init(serverID: ServerID, endpoint: Endpoint, credentials: Credentials, apiKey: String? = nil) {
        self.serverID = serverID
        self.transport = HTTPTransport(endpoint: endpoint)
        self.credentials = credentials
        self.apiKey = apiKey
    }

    /// 网络层统计（压测用）
    public nonisolated var transportStats: HTTPTransport.Stats { transport.stats }

    // MARK: - 连接

    public func connect() async throws -> ServerInfo {
        if apiKey == nil { try await login() }
        let version = try await string("app/version")
        let api = try await string("app/webapiVersion")
        guard let apiVer = SemVer(parsing: api) else {
            throw ClientError.unexpectedResponse("webapiVersion: \(api)")
        }
        var caps: Capabilities = [.categories, .tags]
        // has_tracker_* 字段：5.2.4（webapi 2.15.1）有、5.1.2（2.11.4）没有，中间版本没测，按 2.12 起算（待确认）
        if apiVer >= SemVer(2, 12, 0) { caps.insert(.trackerHealthInList); caps.insert(.apiKey) }
        let info = ServerInfo(
            kind: .qbittorrent,
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            apiVersion: apiVer,
            capabilities: caps
        )
        self.info = info
        return info
    }

    private func login() async throws {
        var req = transport.request("api/v2/auth/login", method: "POST")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["username": credentials.username, "password": credentials.password])
        let (data, resp) = try await transport.send(req)
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch resp.statusCode {
        case 200, 204:
            if body == "Fails." { throw ClientError.badCredentials }
            guard let c = Self.sessionCookie(resp) else {
                throw ClientError.unexpectedResponse(String(localized: "Logged in but got no session cookie"))
            }
            cookie = c
        case 401:
            // qB 自己的 401 不带 WWW-Authenticate；带了就是反代那层
            if let realm = HTTPTransport.authRealm(resp) { throw TransportError.proxyAuthRequired(realm: realm) }
            throw ClientError.loginRejected
        case 403 where body.localizedCaseInsensitiveContains("banned"):
            throw ClientError.ipBanned(body)
        default:
            throw TransportError.http(status: resp.statusCode, body: body)
        }
    }

    /// 从 Set-Cookie 里找名字带 SID 的那个（SID 或 QBT_SID_<port>）
    static func sessionCookie(_ resp: HTTPURLResponse) -> String? {
        guard let raw = resp.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        // 多个 Set-Cookie 会被合并成逗号分隔；cookie 值里不会有逗号（expires 里有，但不在第一段）
        for piece in raw.components(separatedBy: ",") {
            let pair = piece.split(separator: ";", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if name == "SID" || name.hasPrefix("QBT_SID") { return pair }
        }
        return nil
    }

    // MARK: - 请求

    private func send(_ build: () -> URLRequest) async throws -> Data {
        if let apiKey {
            var req = build()
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await transport.send(req)
            switch resp.statusCode {
            case 200..<300: return data
            case 401: throw ClientError.loginRejected // Host 端口校验同样生效（实测）
            case 403: throw ClientError.badCredentials // API key 无效
            default: throw TransportError.http(status: resp.statusCode, body: String(decoding: data, as: UTF8.self))
            }
        }
        if cookie == nil { try await login() }
        for attempt in 0..<2 {
            var req = build()
            if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (data, resp) = try await transport.send(req)
            switch resp.statusCode {
            case 200..<300:
                return data
            case 401:
                if let realm = HTTPTransport.authRealm(resp) { throw TransportError.proxyAuthRequired(realm: realm) }
                throw ClientError.loginRejected
            case 403 where attempt == 0:
                // 会话失效，重新登录一次
                cookie = nil
                try await login()
            default:
                throw TransportError.http(status: resp.statusCode, body: String(decoding: data, as: UTF8.self))
            }
        }
        throw ClientError.unexpectedResponse(String(localized: "Still 403 after logging in again"))
    }

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> Data {
        try await send { transport.request("api/v2/" + path, query: query) }
    }

    private func post(_ path: String, _ fields: [String: String]) async throws {
        _ = try await send {
            var req = transport.request("api/v2/" + path, method: "POST")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(fields)
            return req
        }
    }

    private func string(_ path: String) async throws -> String {
        String(decoding: try await get(path), as: UTF8.self)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    // MARK: - 同步

    public func resetSync() {
        rid = 0
        healthInputs = [:]
        hashesByTracker = [:]
    }

    public func fetchChanges() async throws -> SyncDelta {
        let data = try await get("sync/maindata", [URLQueryItem(name: "rid", value: String(rid))])
        let main = try JSONDecoder().decode(QBMainData.self, from: data)
        return apply(main)
    }

    /// 把 maindata 转成 SyncDelta，同时更新游标和健康度输入。单独拆出来方便用 fixture 测。
    /// 没有健康度标记时，能不能用「tracker 字段为空」判断不工作。
    /// 实测 4.6.7 / 5.0.4（webapi ≤ 2.11.2）可以；5.1.2（2.11.4）起 tracker 字段出错时也有值，不能用。
    /// 没连接过（单测直接喂 fixture）时按老规则处理。
    var emptyTrackerMeansFailure: Bool {
        guard let v = info?.apiVersion else { return true }
        return v <= SemVer(2, 11, 2)
    }

    func apply(_ main: QBMainData) -> SyncDelta {
        let full = main.full_update ?? false
        if full {
            healthInputs = [:]
            hasTrackerFlags = main.torrents?.values.contains { $0.has_tracker_error != nil } ?? false
        }
        rid = main.rid
        var upserts: [String: TorrentPatch] = [:]
        upserts.reserveCapacity(main.torrents?.count ?? 0)
        for (hash, t) in main.torrents ?? [:] {
            var patch = t.patch()
            var inputs = healthInputs[hash] ?? HealthInputs()
            if inputs.merge(t) || full {
                patch.trackerHealth = inputs.health(flagsSupported: hasTrackerFlags, emptyTrackerMeansFailure: emptyTrackerMeansFailure)
            }
            healthInputs[hash] = inputs
            upserts[hash] = patch
        }
        let removed = Set(main.torrents_removed ?? [])
        for h in removed { healthInputs[h] = nil }

        // tracker 映射：找出受影响的种子，重新算 announceURL
        if full { hashesByTracker = [:] }
        var affected = Set<String>()
        for url in main.trackers_removed ?? [] {
            if let old = hashesByTracker.removeValue(forKey: url) { affected.formUnion(old) }
        }
        for (url, hashes) in main.trackers ?? [:] {
            let new = Set(hashes)
            let old = hashesByTracker[url] ?? []
            affected.formUnion(old.symmetricDifference(new))
            if full { affected.formUnion(new) }
            hashesByTracker[url] = new
        }
        if !affected.isEmpty {
            var urlsByHash: [String: [String]] = [:]
            for (url, hashes) in hashesByTracker {
                for h in hashes where affected.contains(h) { urlsByHash[h, default: []].append(url) }
            }
            for h in affected where !removed.contains(h) {
                // maindata 的映射里没有 tier 信息，按字典序排，保证稳定
                let urls = (urlsByHash[h] ?? []).sorted()
                upserts[h, default: TorrentPatch()].announceURL = urls.first ?? ""
                upserts[h, default: TorrentPatch()].trackerURLs = urls
            }
        }
        return SyncDelta(isFullUpdate: full, upserts: upserts, removed: removed, stats: main.server_state?.patch())
    }

    // MARK: - 操作

    public func perform(_ action: TorrentAction, on ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let hashes = ids.joined(separator: "|")
        let renamed = (info?.apiVersion ?? SemVer(0)) >= SemVer(2, 11, 0)
        switch action {
        case .start: try await post(renamed ? "torrents/start" : "torrents/resume", ["hashes": hashes])
        case .stop: try await post(renamed ? "torrents/stop" : "torrents/pause", ["hashes": hashes])
        case .recheck: try await post("torrents/recheck", ["hashes": hashes])
        case .reannounce: try await post("torrents/reannounce", ["hashes": hashes])
        case .delete(let withData):
            try await post("torrents/delete", ["hashes": hashes, "deleteFiles": withData ? "true" : "false"])
        }
    }

    public func add(_ source: AddSource, options: AddOptions) async throws {
        var mp = Multipart()
        switch source {
        case .url(let u): mp.field("urls", u)
        case .file(let d, let name): mp.file("torrents", filename: name, contentType: "application/x-bittorrent", data: d)
        }
        if let p = options.savePath { mp.field("savepath", p) }
        if let c = options.category { mp.field("category", c) }
        if !options.tags.isEmpty { mp.field("tags", options.tags.joined(separator: ",")) }
        // 4.x 认 paused，5.x 认 stopped，两个都发
        mp.field("paused", options.paused ? "true" : "false")
        mp.field("stopped", options.paused ? "true" : "false")
        let body = mp.finish()
        let data = try await send {
            var req = transport.request("api/v2/torrents/add", method: "POST")
            req.setValue(mp.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            return req
        }
        // 4.x 回 "Ok." / "Fails."；5.3 回 JSON（success_count / failure_count）
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "Fails." {
            throw ClientError.unexpectedResponse(String(localized: "Adding failed"))
        }
        if let r = try? JSONDecoder().decode(QBAddResult.self, from: data), r.failure_count ?? 0 > 0 {
            throw ClientError.unexpectedResponse(String(localized: "\(r.failure_count ?? 0) failed to add"))
        }
    }

    public func trackers(of id: String) async throws -> [Tracker] {
        let data = try await get("torrents/trackers", [URLQueryItem(name: "hash", value: id)])
        return try JSONDecoder().decode([QBTracker].self, from: data)
            .filter { !$0.url.hasPrefix("** [") } // DHT / PeX / LSD 伪条目
            .map { $0.model() }
    }

    public func files(of id: String) async throws -> [ContentFile] {
        let data = try await get("torrents/files", [URLQueryItem(name: "hash", value: id)])
        return try JSONDecoder().decode([QBFile].self, from: data).enumerated().map { $1.model(at: $0) }
    }

    public func peers(of id: String) async throws -> [Peer] {
        let data = try await get("sync/torrentPeers", [URLQueryItem(name: "hash", value: id), URLQueryItem(name: "rid", value: "0")])
        return try JSONDecoder().decode(QBPeerList.self, from: data).model()
    }

    public func setFilePriority(_ priority: FilePriority, files indices: [Int], of id: String) async throws {
        guard !indices.isEmpty else { return }
        let value = switch priority {
        case .skip: "0"
        case .normal: "1"
        case .high: "6"
        case .low: throw ClientError.unsupported(String(localized: "qBittorrent has no low file priority"))
        }
        try await post("torrents/filePrio", ["hash": id, "id": indices.map(String.init).joined(separator: "|"), "priority": value])
    }

    // MARK: - 批量操作

    public func setCategory(_ category: String, on ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let fields = ["hashes": ids.joined(separator: "|"), "category": category]
        do {
            try await post("torrents/setCategory", fields)
        } catch TransportError.http(status: 409, _) where !category.isEmpty {
            // 分类不存在：先创建再设置
            try await post("torrents/createCategory", ["category": category])
            try await post("torrents/setCategory", fields)
        }
    }

    public func updateTags(_ changes: [TagChange]) async throws {
        // 按「要加的标签」「要删的标签」分组，同一组一次请求
        var adds: [String: [String]] = [:], removes: [String: [String]] = [:]
        for c in changes {
            let add = Set(c.final).subtracting(c.current).sorted()
            let rem = Set(c.current).subtracting(c.final).sorted()
            if !add.isEmpty { adds[add.joined(separator: ","), default: []].append(c.id) }
            if !rem.isEmpty { removes[rem.joined(separator: ","), default: []].append(c.id) }
        }
        for (tags, ids) in removes { try await post("torrents/removeTags", ["hashes": ids.joined(separator: "|"), "tags": tags]) }
        for (tags, ids) in adds { try await post("torrents/addTags", ["hashes": ids.joined(separator: "|"), "tags": tags]) }
    }

    public func setUploadLimit(_ bytesPerSecond: Int64, on ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await post("torrents/setUploadLimit", ["hashes": ids.joined(separator: "|"), "limit": String(max(0, bytesPerSecond))])
    }

    public func setLocation(_ path: String, moveFiles: Bool, on ids: [String]) async throws {
        guard moveFiles else { throw ClientError.unsupported(String(localized: "qBittorrent always moves files when changing the save path")) }
        guard !ids.isEmpty else { return }
        try await post("torrents/setLocation", ["hashes": ids.joined(separator: "|"), "location": path])
    }

    public func replaceTrackerURL(on id: String, from old: String, to new: String) async throws {
        // 4.x 叫 origUrl，5.3 改成了 url（实测 5.3.0 只给 origUrl 会报 "Missing required parameters: url"），两个都发
        try await post("torrents/editTracker", ["hash": id, "origUrl": old, "url": old, "newUrl": new])
    }

    public func setAltSpeed(_ enabled: Bool) async throws {
        let current = try await string("transfer/speedLimitsMode").trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        if current != enabled { try await post("transfer/toggleSpeedLimitsMode", [:]) }
    }

    public func speedLimits() async throws -> SpeedLimits {
        // 都是字节/秒（实测 4.6 备用限速默认值返回 10240），0 或 -1 表示不限
        let p = try JSONDecoder().decode(QBSpeedPrefs.self, from: try await get("app/preferences"))
        func v(_ x: Int64?) -> Int64 { max(0, x ?? 0) }
        return SpeedLimits(download: v(p.dl_limit), upload: v(p.up_limit), altDownload: v(p.alt_dl_limit), altUpload: v(p.alt_up_limit))
    }

    public func setSpeedLimits(_ l: SpeedLimits) async throws {
        let prefs: [String: Int64] = [
            "dl_limit": max(0, l.download), "up_limit": max(0, l.upload),
            "alt_dl_limit": max(0, l.altDownload), "alt_up_limit": max(0, l.altUpload),
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: prefs, options: [.sortedKeys]), as: UTF8.self)
        try await post("app/setPreferences", ["json": json])
    }
}

// MARK: - tracker 健康度

struct HealthInputs {
    var state = ""
    var tracker = ""
    var trackersCount = 0
    var hasError = false
    var hasWarning = false
    var hasOther = false

    /// 返回这次是否有相关字段变化
    mutating func merge(_ t: QBTorrent) -> Bool {
        var changed = false
        if let v = t.state { state = v; changed = true }
        if let v = t.tracker { tracker = v; changed = true }
        if let v = t.trackers_count { trackersCount = v; changed = true }
        if let v = t.has_tracker_error { hasError = v; changed = true }
        if let v = t.has_tracker_warning { hasWarning = v; changed = true }
        if let v = t.has_other_announce_error { hasOther = v; changed = true }
        return changed
    }

    func health(flagsSupported: Bool, emptyTrackerMeansFailure: Bool) -> TrackerHealth {
        if flagsSupported {
            if hasError { return .trackerError }
            if hasOther { return .unreachable }
            if hasWarning { return .trackerWarning }
        }
        let inactive = QBState.map(state) == .stopped || QBState.map(state) == .queued
            || QBState.map(state) == .checking || QBState.map(state) == .metadata
        if inactive || trackersCount == 0 { return .unknown }
        if flagsSupported { return tracker.isEmpty ? .unknown : .working }
        // 5.1.x：既没有标记，tracker 字段也不清空，列表接口判断不了，只能逐个查
        guard emptyTrackerMeansFailure else { return .unknown }
        // ≤ 5.0：没有正常工作的 tracker，但分不清是 tracker 报错还是连不上，要逐个查
        return tracker.isEmpty ? .notWorking : .working
    }
}

enum QBState {
    static func map(_ s: String) -> TorrentState {
        switch s {
        case "downloading", "forcedDL": .downloading
        case "uploading", "forcedUP": .seeding
        case "stalledDL": .stalledDownloading
        case "stalledUP": .stalledSeeding
        case "pausedDL", "pausedUP", "stoppedDL", "stoppedUP": .stopped
        case "queuedDL", "queuedUP": .queued
        case "checkingDL", "checkingUP", "checkingResumeData": .checking
        case "metaDL", "forcedMetaDL": .metadata
        case "moving": .moving
        case "error", "missingFiles": .error
        default: .unknown
        }
    }
}
