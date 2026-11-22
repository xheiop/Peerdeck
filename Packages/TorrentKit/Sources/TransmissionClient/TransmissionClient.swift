import Foundation
import TorrentKit

/// Transmission RPC 适配器（旧协议，3.x / 4.0 / 4.1 通用）。
///
/// 实测行为（dev/compose.yaml 里的容器，2026-11）：
/// - 第一次请求 409，带 X-Transmission-Session-Id；4.1.4 还多一个 X-Transmission-Rpc-Version: 6.0.1
/// - 4.1.4 的旧协议仍然返回 kebab/camelCase 字段，可以不切 JSON-RPC 2.0
/// - 种子级 error=2 + errorString 就带 tracker 的报错原文（Unregistered torrent），一次 torrent-get 拿全
public actor TransmissionClient: TorrentClient {
    public nonisolated let serverID: ServerID
    public nonisolated let kind: ClientKind = .transmission

    private let transport: HTTPTransport
    private let credentials: Credentials
    private var sessionID = ""
    private var synced = false
    private var rpcVersion = 0
    /// 剩余空间不用每次轮询都查：记下上次的值和时间
    private var freeSpace: Int64?
    private var freeSpaceAt = ContinuousClock.now - .seconds(3600)

    static let listFields = [
        "id", "hashString", "name", "status", "error", "errorString", "isStalled",
        "percentDone", "sizeWhenDone", "downloadedEver", "uploadedEver", "uploadRatio",
        "rateDownload", "rateUpload", "eta", "peersSendingToUs", "peersGettingFromUs",
        "addedDate", "doneDate", "secondsSeeding", "downloadDir", "labels", "isPrivate", "trackers",
        "uploadLimit", "uploadLimited",
    ]

    public init(serverID: ServerID, endpoint: Endpoint, credentials: Credentials) {
        self.serverID = serverID
        self.transport = HTTPTransport(endpoint: endpoint)
        self.credentials = credentials
    }

    /// 网络层统计（压测用）
    public nonisolated var transportStats: HTTPTransport.Stats { transport.stats }

    // MARK: - RPC

    /// 发一个 RPC，返回 arguments 部分的原始 JSON。
    private func call(_ method: String, _ arguments: [String: Any] = [:]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
        for _ in 0..<3 {
            var req = transport.request("transmission/rpc", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // TR 自己的认证会覆盖反代层的 Basic Auth（两者都用 Authorization 头）
            req.setValue(HTTPTransport.basicAuth(credentials), forHTTPHeaderField: "Authorization")
            req.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
            req.httpBody = body
            let (data, resp) = try await transport.send(req)
            switch resp.statusCode {
            case 200:
                let env = try JSONDecoder().decode(TREnvelopeHeader.self, from: data)
                guard env.result == "success" else {
                    throw ClientError.unexpectedResponse("\(method): \(env.result)")
                }
                return data
            case 409:
                guard let sid = resp.value(forHTTPHeaderField: "X-Transmission-Session-Id") else {
                    throw ClientError.unexpectedResponse(String(localized: "409 without a session id"))
                }
                sessionID = sid
            case 401:
                if let realm = HTTPTransport.authRealm(resp), realm != "Transmission" {
                    throw TransportError.proxyAuthRequired(realm: realm)
                }
                throw ClientError.badCredentials
            case 403:
                // rpc-whitelist 拦截
                throw ClientError.unexpectedResponse(String(localized: "403: this IP isn’t in Transmission’s rpc-whitelist"))
            default:
                throw TransportError.http(status: resp.statusCode, body: String(decoding: data, as: UTF8.self))
            }
        }
        throw ClientError.unexpectedResponse(String(localized: "409 loop"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(TREnvelope<T>.self, from: data).arguments
    }

    // MARK: - 连接

    public func connect() async throws -> ServerInfo {
        let s = try decode(TRSessionInfo.self, try await call("session-get", [
            "fields": ["version", "rpc-version", "rpc-version-semver"],
        ]))
        let api = s.semver.flatMap(SemVer.init(parsing:)) ?? SemVer(0, s.rpcVersion ?? 0)
        rpcVersion = s.rpcVersion ?? 0
        var caps: Capabilities = [.trackerHealthInList, .relocateWithoutMove, .lowFilePriority]
        if (s.rpcVersion ?? 0) >= 16 { caps.insert(.tags) } // labels 从 3.0 就有，sitename 从 4.0
        if (s.rpcVersion ?? 0) >= 17 { caps.insert(.trackerSiteName) }
        return ServerInfo(kind: .transmission, version: s.version, apiVersion: api, capabilities: caps)
    }

    // MARK: - 同步

    public func resetSync() { synced = false }

    public func fetchChanges() async throws -> SyncDelta {
        var args: [String: Any] = ["fields": Self.listFields]
        let full = !synced
        if !full { args["ids"] = "recently-active" }
        let list = try decode(TRTorrentList.self, try await call("torrent-get", args))
        var upserts: [String: TorrentPatch] = [:]
        upserts.reserveCapacity(list.torrents.count)
        for t in list.torrents { upserts[String(t.id)] = t.patch() }
        let removed = Set((list.removed ?? []).map(String.init))

        let stats = try decode(TRSessionStats.self, try await call("session-stats"))
        let session = try decode(TRSessionInfo.self, try await call("session-get", ["fields": ["alt-speed-enabled", "version", "download-dir"]]))
        var sp = ServerStatsPatch()
        sp.downloadSpeed = stats.downloadSpeed
        sp.uploadSpeed = stats.uploadSpeed
        sp.allTimeUploaded = stats.cumulative?.uploadedBytes
        sp.allTimeDownloaded = stats.cumulative?.downloadedBytes
        sp.altSpeedEnabled = session.altSpeedEnabled
        // 默认下载目录所在磁盘的剩余空间（free-space 从 rpc 15 / TR 2.80 起有），30 秒查一次
        if let dir = session.downloadDir, ContinuousClock.now - freeSpaceAt > .seconds(30) {
            freeSpaceAt = .now
            freeSpace = await freeSpace(at: dir)
        }
        sp.freeSpace = freeSpace

        synced = true
        return SyncDelta(isFullUpdate: full, upserts: upserts, removed: removed, stats: sp)
    }

    /// 目录还不存在时（比如还没有种子下完，complete 目录没建）TR 返回错误，逐级往上查
    private func freeSpace(at dir: String) async -> Int64? {
        var path = dir
        for _ in 0..<6 {
            if let r = try? decode(TRFreeSpace.self, try await call("free-space", ["path": path])), let v = r.sizeBytes, v >= 0 { return v }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
        return nil
    }

    // MARK: - 操作

    public func perform(_ action: TorrentAction, on ids: [String]) async throws {
        let nums = ids.compactMap(Int.init)
        guard !nums.isEmpty else { return }
        switch action {
        case .start: _ = try await call("torrent-start", ["ids": nums])
        case .stop: _ = try await call("torrent-stop", ["ids": nums])
        case .recheck: _ = try await call("torrent-verify", ["ids": nums])
        case .reannounce: _ = try await call("torrent-reannounce", ["ids": nums])
        case .delete(let withData): _ = try await call("torrent-remove", ["ids": nums, "delete-local-data": withData])
        }
    }

    public func add(_ source: AddSource, options: AddOptions) async throws {
        var args: [String: Any] = ["paused": options.paused]
        switch source {
        case .url(let u): args["filename"] = u
        case .file(let d, _): args["metainfo"] = d.base64EncodedString()
        }
        if let p = options.savePath { args["download-dir"] = p }
        if !options.tags.isEmpty { args["labels"] = options.tags }
        _ = try await call("torrent-add", args)
    }

    public func trackers(of id: String) async throws -> [Tracker] {
        guard let n = Int(id) else { return [] }
        let list = try decode(TRTrackerStatsList.self, try await call("torrent-get", [
            "ids": [n], "fields": ["id", "trackerStats"],
        ]))
        return (list.torrents.first?.trackerStats ?? []).map { $0.model() }
    }

    public func files(of id: String) async throws -> [ContentFile] {
        guard let n = Int(id) else { return [] }
        return try decode(TRFileList.self, try await call("torrent-get", ["ids": [n], "fields": ["id", "files", "fileStats"]])).model()
    }

    public func setFilePriority(_ priority: FilePriority, files indices: [Int], of id: String) async throws {
        guard let n = Int(id), !indices.isEmpty else { return }
        var args: [String: Any] = ["ids": [n]]
        switch priority {
        case .skip: args["files-unwanted"] = indices
        case .low: args["files-wanted"] = indices; args["priority-low"] = indices
        case .normal: args["files-wanted"] = indices; args["priority-normal"] = indices
        case .high: args["files-wanted"] = indices; args["priority-high"] = indices
        }
        _ = try await call("torrent-set", args)
    }

    // MARK: - 批量操作

    public func setCategory(_ category: String, on ids: [String]) async throws {
        throw ClientError.unsupported(String(localized: "Transmission has no categories"))
    }

    public func updateTags(_ changes: [TagChange]) async throws {
        // TR 的 labels 是整体设置：按最终结果分组
        var groups: [[String]: [Int]] = [:]
        for c in changes where Set(c.final) != Set(c.current) {
            if let n = Int(c.id) { groups[c.final.sorted(), default: []].append(n) }
        }
        for (labels, ids) in groups { _ = try await call("torrent-set", ["ids": ids, "labels": labels]) }
    }

    public func setUploadLimit(_ bytesPerSecond: Int64, on ids: [String]) async throws {
        let nums = ids.compactMap(Int.init)
        guard !nums.isEmpty else { return }
        var args: [String: Any] = ["ids": nums, "uploadLimited": bytesPerSecond > 0]
        if bytesPerSecond > 0 { args["uploadLimit"] = max(1, bytesPerSecond / 1024) } // TR 的单位是 KB/s
        _ = try await call("torrent-set", args)
    }

    public func setLocation(_ path: String, moveFiles: Bool, on ids: [String]) async throws {
        let nums = ids.compactMap(Int.init)
        guard !nums.isEmpty else { return }
        _ = try await call("torrent-set-location", ["ids": nums, "location": path, "move": moveFiles])
    }

    public func replaceTrackerURL(on id: String, from old: String, to new: String) async throws {
        guard let n = Int(id) else { return }
        let list = try decode(TRTorrentList.self, try await call("torrent-get", ["ids": [n], "fields": ["id", "trackers"]]))
        let trackers = list.torrents.first?.trackers ?? []
        guard trackers.contains(where: { $0.announce == old }) else {
            throw ClientError.unexpectedResponse(String(localized: "The torrent doesn’t have this tracker: \(old)"))
        }
        if rpcVersion >= 17 {
            // 4.0+：trackerList 整体替换，tier 之间空一行
            let tiers = Dictionary(grouping: trackers, by: { $0.tier ?? 0 }).sorted { $0.key < $1.key }
            let text = tiers.map { $0.value.map { $0.announce == old ? new : $0.announce }.joined(separator: "\n") }.joined(separator: "\n\n")
            _ = try await call("torrent-set", ["ids": [n], "trackerList": text])
        } else if let tid = trackers.first(where: { $0.announce == old })?.id {
            _ = try await call("torrent-set", ["ids": [n], "trackerReplace": [tid, new]])
        }
    }

    public func setAltSpeed(_ enabled: Bool) async throws {
        _ = try await call("session-set", ["alt-speed-enabled": enabled])
    }

    public func speedLimits() async throws -> SpeedLimits {
        let s = try decode(TRSpeedSession.self, try await call("session-get", ["fields": [
            "speed-limit-down", "speed-limit-down-enabled", "speed-limit-up", "speed-limit-up-enabled", "alt-speed-down", "alt-speed-up",
        ]]))
        func kb(_ v: Int64?) -> Int64 { max(0, v ?? 0) * 1024 }
        return SpeedLimits(
            download: s.downEnabled == true ? kb(s.down) : 0,
            upload: s.upEnabled == true ? kb(s.up) : 0,
            altDownload: kb(s.altDown), altUpload: kb(s.altUp)
        )
    }

    public func setSpeedLimits(_ l: SpeedLimits) async throws {
        guard l.altDownload > 0, l.altUpload > 0 else {
            throw ClientError.unsupported(String(localized: "Transmission’s alternative limits can’t be unlimited"))
        }
        func kb(_ v: Int64) -> Int64 { max(1, v / 1024) }
        var args: [String: Any] = [
            "speed-limit-down-enabled": l.download > 0, "speed-limit-up-enabled": l.upload > 0,
            "alt-speed-down": kb(l.altDownload), "alt-speed-up": kb(l.altUpload),
        ]
        // 关掉时保留原来的数值，下次在 TR 自己的界面里打开还是原值
        if l.download > 0 { args["speed-limit-down"] = kb(l.download) }
        if l.upload > 0 { args["speed-limit-up"] = kb(l.upload) }
        _ = try await call("session-set", args)
    }
}
