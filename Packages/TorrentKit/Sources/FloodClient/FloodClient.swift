import Foundation
import TorrentKit

/// Flood（jesec/flood 4.x）适配器。接口以 v4.16.4 源码为准。
///
/// - 登录：POST api/auth/authenticate，拿 jwt cookie（一周过期）。auth=none 时不看用户名密码，同样发 cookie
/// - 同步：SSE api/activity-stream，先给全量，再给 JSON Patch。不轮询 GET api/torrents：它每次都是全量，
///   2 万种子一次十几 MB
/// - 列表里的 tracker 只有主域名：每个域名查一个种子的详情换出完整主机名，和直连 qB / TR 时的站点对得上
/// - 不支持：分类、备用限速、单种限速（Flood 没有接口）；替换 tracker（Flood 是先全删再加，丢层级，中途失败就没有 tracker 了）
public actor FloodClient: TorrentClient {
    public nonisolated let serverID: ServerID
    public nonisolated let kind: ClientKind = .flood

    private let transport: HTTPTransport
    /// SSE 和会很慢的操作（rTorrent 后端的移动、删数据是 Flood 同步做完才返回）用长超时
    private let slowTransport: HTTPTransport
    private let credentials: Credentials
    private let headerTimeout: TimeInterval
    private var cookie: String?
    private(set) var backend: FloodBackend = .unknown
    private var defaultDirectory: String?
    private var stream: FloodEventStream?
    /// 主域名 → 「协议://完整主机名/」
    private var originByDomain: [String: String] = [:]

    private static let batchSize = 200
    private static let firstListTimeout: Duration = .seconds(120)
    /// 下载器正常时 Flood 每 2 秒推一次速度；这么久没动静就是连接已经死了（app 从后台回来时常见）
    private static let staleAfter: Duration = .seconds(45)
    /// Flood 到下载器偶尔断一下会自己恢复
    private static let disconnectGrace: Duration = .seconds(15)

    public init(serverID: ServerID, endpoint: Endpoint, credentials: Credentials) {
        self.serverID = serverID
        self.credentials = credentials
        headerTimeout = max(endpoint.timeout, 15)
        transport = HTTPTransport(endpoint: endpoint)
        var slow = endpoint
        slow.timeout = max(endpoint.timeout, 120)
        slowTransport = HTTPTransport(endpoint: slow)
    }

    public nonisolated var transportStats: HTTPTransport.Stats { transport.stats }

    // MARK: - HTTP

    private func login() async throws {
        var req = transport.request("api/auth/authenticate", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": credentials.username, "password": credentials.password])
        let (data, resp) = try await transport.send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch resp.statusCode {
        case 200:
            guard json?["success"] as? Bool == true else { throw Self.notFlood() }
            guard let token = Self.jwt(resp.value(forHTTPHeaderField: "Set-Cookie")) else {
                throw ClientError.unexpectedResponse(String(localized: "Flood didn’t return a session cookie"))
            }
            cookie = token
        case 401:
            if let realm = HTTPTransport.authRealm(resp) { throw TransportError.proxyAuthRequired(realm: realm) }
            guard json?["message"] != nil else { throw TransportError.http(status: 401, body: String(decoding: data, as: UTF8.self)) }
            // 还没建过账号时也是 401。verify 有限流，只在这里才查
            if let (body, _) = try? await transport.send(transport.request("api/auth/verify")),
               let verify = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], verify["initialUser"] as? Bool == true {
                throw ClientError.unexpectedResponse(String(localized: "Flood has no account yet. Finish its setup in the web UI first."))
            }
            throw ClientError.badCredentials
        case 404, 405:
            throw Self.notFlood()
        default:
            throw Self.failure(data, resp)
        }
    }

    private static func notFlood() -> ClientError {
        .unexpectedResponse(String(localized: "This doesn’t look like Flood. Check the address and its base path."))
    }

    /// "jwt=xxx; Path=/; HttpOnly" → "jwt=xxx"
    static func jwt(_ header: String?) -> String? {
        guard let header, let r = header.range(of: "jwt=") else { return nil }
        let value = header[r.upperBound...].prefix { $0 != ";" && $0 != "," }
        return value.isEmpty ? nil : "jwt=" + value
    }

    static func failure(_ data: Data, _ resp: HTTPURLResponse) -> any Error {
        if resp.statusCode == 403, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["code"] as? String == "EACCES" {
            return ClientError.unexpectedResponse(String(localized: "Flood isn’t allowed to use this path (see its allowedpath option)"))
        }
        if resp.statusCode == 429 {
            // 不能用 .ipBanned：那会停止自动重连，而限流过几分钟就解除
            return ClientError.unexpectedResponse(String(localized: "Flood is rate limiting requests; try again in a few minutes"))
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let m = json["message"] as? String {
            // 很多后端错误 Flood 是 throw new Error()，message 是空的
            let reason = m.isEmpty ? String(localized: "Flood gave no reason; check its log") : String(m.prefix(200))
            return ClientError.unexpectedResponse("Flood HTTP \(resp.statusCode): \(reason)")
        }
        return TransportError.http(status: resp.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    private static func sessionRejected() -> ClientError {
        .unexpectedResponse(String(localized: "Flood rejected the session right after login"))
    }

    /// 带会话发请求；401 时重新登录一次
    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, slow: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let t = slow ? slowTransport : transport
        for attempt in 0..<2 {
            if cookie == nil { try await login() }
            var req = t.request(path, method: method)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let payload {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = payload
            }
            let (data, resp) = try await t.send(req)
            if resp.statusCode == 401 {
                if let realm = HTTPTransport.authRealm(resp) { throw TransportError.proxyAuthRequired(realm: realm) }
                cookie = nil
                if attempt == 0 { continue }
                throw Self.sessionRejected()
            }
            guard (200..<300).contains(resp.statusCode) else { throw Self.failure(data, resp) }
            return (data, resp)
        }
        throw Self.sessionRejected()
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let (data, _) = try await call(path)
        guard let v = try? JSONDecoder().decode(T.self, from: data) else {
            throw ClientError.unexpectedResponse(path)
        }
        return v
    }

    // MARK: - 连接

    public func connect() async throws -> ServerInfo {
        stream = nil
        try await login()
        do {
            _ = try await call("api/client/connection-test")
        } catch ClientError.unexpectedResponse(let reason) {
            throw ClientError.unexpectedResponse(String(localized: "Flood can’t reach its torrent client (\(reason))"))
        } catch TransportError.http(let status, _) where status >= 500 {
            throw ClientError.unexpectedResponse(String(localized: "Flood can’t reach its torrent client (\("HTTP \(status)"))"))
        }
        let settings = try await get(FloodSettings.self, "api/client/settings")
        backend = FloodBackend.detect(settings)
        defaultDirectory = settings.directoryDefault

        // 版本只在 OpenAPI 文档里有；老版本没有这个文档，不影响使用
        struct OpenAPI: Decodable { struct Info: Decodable { var version: String }; var info: Info }
        let version = try? await get(OpenAPI.self, "api/openapi.json").info.version

        var caps: Capabilities = []
        if backend.reportsTrackerHealth { caps.insert(.trackerHealthInList) }
        if backend.supportsTags { caps.insert(.tags) }
        if backend.canRelocateWithoutMove { caps.insert(.relocateWithoutMove) }
        return ServerInfo(
            kind: .flood, version: "\(version ?? "4.x") (\(backend.name))",
            apiVersion: version.flatMap(SemVer.init(parsing:)) ?? SemVer(4), capabilities: caps
        )
    }

    // MARK: - 同步

    public func resetSync() { stream?.markFull() }

    private func openStream() async throws -> FloodEventStream {
        for attempt in 0..<2 {
            if cookie == nil { try await login() }
            var req = slowTransport.request("api/activity-stream")
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, resp) = try await slowTransport.stream(req, headersWithin: headerTimeout)
            if resp.statusCode == 200 {
                guard resp.mimeType == "text/event-stream" else { throw Self.notFlood() }
                return FloodEventStream(bytes: bytes)
            }
            bytes.task.cancel()
            if resp.statusCode == 401 {
                cookie = nil
                if attempt == 0 { continue }
                throw Self.sessionRejected()
            }
            throw Self.failure(Data(), resp)
        }
        throw Self.sessionRejected()
    }

    private func liveStream() async throws -> FloodEventStream {
        if let s = stream {
            let st = s.status
            let stale = st.disconnectedSince == nil && ContinuousClock.now - st.lastEvent > Self.staleAfter
            // 拿到过列表的连接断了就重开一条（新连接先给全量）；从没拿到过的在下面报错
            if st.hasList, st.ended || stale { stream = nil }
        }
        if let s = stream { return s }
        let s = try await openStream()
        stream = s
        return s
    }

    public func fetchChanges() async throws -> SyncDelta {
        let s = try await liveStream()
        let started = ContinuousClock.now
        while true {
            let st = s.status
            if let since = st.disconnectedSince, ContinuousClock.now - since > Self.disconnectGrace {
                stream = nil
                throw ClientError.unexpectedResponse(String(localized: "Flood lost the connection to its torrent client"))
            }
            if st.hasList { break }
            if st.ended {
                stream = nil
                let reason = st.failure ?? "EOF"
                throw ClientError.unexpectedResponse(String(localized: "Flood’s activity stream closed (\(reason))"))
            }
            if ContinuousClock.now - started > Self.firstListTimeout {
                stream = nil
                throw ClientError.unexpectedResponse(String(localized: "Flood didn’t send the torrent list. A reverse proxy may be buffering its activity stream."))
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let changes = s.take()
        await resolveOrigins(changes.upserts)
        var upserts = [String: TorrentPatch](minimumCapacity: changes.upserts.count)
        for (id, t) in changes.upserts {
            let origin = t.trackerDomains.first.flatMap { originByDomain[$0] } ?? ""
            upserts[id] = t.patch(backend: backend, announceURL: origin)
        }
        var stats = ServerStatsPatch()
        stats.downloadSpeed = FloodNumber.int(changes.summary?.downRate)
        stats.uploadSpeed = FloodNumber.int(changes.summary?.upRate)
        stats.freeSpace = FloodDisk.free(changes.disks, for: defaultDirectory)
        return SyncDelta(isFullUpdate: changes.full, upserts: upserts, removed: changes.removed, stats: stats)
    }

    /// 每个新域名取 hash 最小的那个种子查一次详情，每次启动选到同一个，站点才不会变来变去
    private func resolveOrigins(_ torrents: [String: FloodTorrent]) async {
        var sample: [String: String] = [:]
        for (id, t) in torrents {
            guard let domain = t.trackerDomains.first, originByDomain[domain] == nil else { continue }
            sample[domain] = min(sample[domain] ?? id, id)
        }
        let pending = Array(sample)
        for start in stride(from: 0, to: pending.count, by: 4) {
            await withTaskGroup(of: (String, String).self) { group in
                for (domain, id) in pending[start..<min(start + 4, pending.count)] {
                    group.addTask {
                        let urls = (try? await self.details(id).realURLs) ?? []
                        return (domain, Self.origin(domain: domain, urls: urls))
                    }
                }
                for await (domain, origin) in group { originByDomain[domain] = origin }
            }
        }
    }

    /// 只留协议和主机：完整地址里有这个种子的 passkey，不能安到同域名的别的种子头上
    static func origin(domain: String, urls: [String]) -> String {
        let d = domain.lowercased()
        for url in urls {
            guard let c = URLComponents(string: url), let scheme = c.scheme, let host = c.host?.lowercased() else { continue }
            if host == d || host.hasSuffix("." + d) { return "\(scheme)://\(host)/" }
        }
        return "https://\(d)/"
    }

    private func details(_ id: String) async throws -> FloodDetails {
        try await get(FloodDetails.self, "api/torrents/\(id)/details")
    }

    // MARK: - 操作

    private static func batches(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
    }

    public func perform(_ action: TorrentAction, on ids: [String]) async throws {
        for batch in Self.batches(ids) {
            var body: [String: Any] = ["hashes": batch]
            let path: String
            switch action {
            case .start: path = "start"
            case .stop: path = "stop"
            case .recheck: path = "check-hash"
            case .reannounce: path = "reannounce"
            case .delete(let withData):
                path = "delete"
                body["deleteData"] = withData
            }
            _ = try await call("api/torrents/\(path)", method: "POST", body: body, slow: true)
        }
    }

    public func add(_ source: AddSource, options: AddOptions) async throws {
        var body: [String: Any] = ["start": !options.paused]
        if let p = options.savePath, !p.isEmpty { body["destination"] = p }
        if !options.tags.isEmpty { body["tags"] = try Self.validated(options.tags) }
        let path: String
        switch source {
        case .url(let u):
            path = "add-urls"
            body["urls"] = [u]
        case .file(let d, _):
            path = "add-files"
            body["files"] = [d.base64EncodedString()]
        }
        let (_, resp) = try await call("api/torrents/\(path)", method: "POST", body: body, slow: true)
        // 202 表示「没返回 hash」：rTorrent 一直是这样，qB 加链接也是，都算成功。
        // 只有 Transmission 成功时必有 hash，它的 202 是 Flood 吞掉了错误
        if backend == .transmission, resp.statusCode == 202 {
            throw ClientError.unexpectedResponse(String(localized: "Transmission didn’t accept the torrent"))
        }
    }

    public func trackers(of id: String) async throws -> [Tracker] {
        let urls = try await details(id).realURLs
        // Flood 不给每个 tracker 的状态：只有一个 tracker 时才能把种子级的状态算到它头上
        let diagnosis = urls.count == 1 ? stream?.torrent(id).map { FloodHealth.diagnose($0, backend: backend) } : nil
        let status: TrackerStatus = switch diagnosis?.health {
        case .working: .working
        case .trackerError: .trackerError
        case .unreachable: .unreachable
        default: .unknown
        }
        let message = diagnosis.map { $0.localError ? "" : $0.message } ?? ""
        return urls.enumerated().map { i, url in Tracker(url: url, tier: i, status: status, message: message) }
    }

    public func files(of id: String) async throws -> [ContentFile] {
        let contents = try await get([FloodContent].self, "api/torrents/\(id)/contents")
        var root: String?
        if let t = stream?.torrent(id), t.includesRootFolder(backend), !(contents.count == 1 && contents[0].path == t.name) {
            root = t.name
        }
        return contents.map { $0.model(rootFolder: root) }
    }

    public func setFilePriority(_ priority: FilePriority, files indices: [Int], of id: String) async throws {
        guard !indices.isEmpty else { return }
        let value: Int
        switch priority {
        case .skip: value = 0
        case .normal: value = 1
        case .high: value = 2
        case .low: throw ClientError.unsupported(String(localized: "Flood has no low file priority"))
        }
        _ = try await call("api/torrents/\(id)/contents", method: "PATCH", body: ["indices": indices, "priority": value])
    }

    // MARK: - 批量操作

    public func setCategory(_ category: String, on ids: [String]) async throws {
        throw ClientError.unsupported(String(localized: "Flood has no categories"))
    }

    private static func validated(_ tags: [String]) throws -> [String] {
        guard !tags.contains(where: { $0.contains(",") }) else {
            throw ClientError.unsupported(String(localized: "Flood tags can’t contain commas"))
        }
        return tags
    }

    public func updateTags(_ changes: [TagChange]) async throws {
        guard backend.supportsTags else {
            throw ClientError.unsupported(String(localized: "Flood can’t set tags on Deluge"))
        }
        var groups: [[String]: [String]] = [:]
        for c in changes where Set(c.final) != Set(c.current) {
            groups[try Self.validated(c.final.sorted()), default: []].append(c.id)
        }
        for (tags, ids) in groups {
            for batch in Self.batches(ids) {
                _ = try await call("api/torrents/tags", method: "PATCH", body: ["hashes": batch, "tags": tags])
            }
        }
    }

    public func setUploadLimit(_ bytesPerSecond: Int64, on ids: [String]) async throws {
        throw ClientError.unsupported(String(localized: "Flood has no per-torrent speed limits"))
    }

    public func setLocation(_ path: String, moveFiles: Bool, on ids: [String]) async throws {
        guard moveFiles || backend.canRelocateWithoutMove else {
            throw ClientError.unsupported(String(localized: "This client always moves files when changing the path"))
        }
        for batch in Self.batches(ids) {
            _ = try await call("api/torrents/move", method: "POST", body: [
                "hashes": batch, "destination": path, "moveFiles": moveFiles, "isBasePath": false, "isCheckHash": false,
            ], slow: true)
        }
    }

    public func replaceTrackerURL(on id: String, from old: String, to new: String) async throws {
        throw ClientError.unsupported(String(localized: "Flood can’t replace a single tracker URL safely"))
    }

    public func setAltSpeed(_ enabled: Bool) async throws {
        throw ClientError.unsupported(String(localized: "Flood has no alternative speed limits"))
    }

    public func speedLimits() async throws -> SpeedLimits {
        let s = try await get(FloodSettings.self, "api/client/settings")
        return SpeedLimits(
            download: max(0, FloodNumber.int(s.throttleGlobalDownSpeed) ?? 0),
            upload: max(0, FloodNumber.int(s.throttleGlobalUpSpeed) ?? 0)
        )
    }

    public func setSpeedLimits(_ limits: SpeedLimits) async throws {
        _ = try await call("api/client/settings", method: "PATCH", body: [
            "throttleGlobalDownSpeed": limits.download, "throttleGlobalUpSpeed": limits.upload,
        ])
    }
}
