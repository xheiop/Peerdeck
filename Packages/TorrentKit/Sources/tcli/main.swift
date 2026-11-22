import CryptoKit
import Foundation

func CC_SHA1_shim(_ buf: UnsafeRawBufferPointer, _ out: inout [UInt8]) {
    out = Array(Insecure.SHA1.hash(data: Data(buf)))
}
import QBittorrentClient
import SyncEngine
import TorrentKit
import TransmissionClient

// M0 验证用的命令行工具，默认连 dev/compose.yaml 起的环境。
//
//   swift run -c release tcli probe            各下载器的 tracker 场景种子 + 健康度
//   swift run -c release tcli net              反代 / 自签证书 / CF Access / SSO / 多线路选择
//   swift run -c release tcli sync qb53 5      全量 + N 次增量的耗时和流量
//   swift run -c release tcli bench 20000      合成数据的合并、过滤、排序耗时
//   swift run -c release tcli files [目标…]     文件列表、文件优先级、剩余空间（加一个三文件的暂停种子，测完删掉）

let adminCreds = Credentials(username: "admin", password: "adminadmin")

struct Target {
    var name: String
    var kind: ClientKind
    var endpoint: Endpoint
}

let presets: [String: Target] = [
    "qb53": Target(name: "qb53", kind: .qbittorrent, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:18080")!)),
    "qb46": Target(name: "qb46", kind: .qbittorrent, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:18081")!)),
    "qbx": Target(name: "qbx", kind: .qbittorrent, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:18082")!)),
    "tr41": Target(name: "tr41", kind: .transmission, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:19091")!)),
    "tr40": Target(name: "tr40", kind: .transmission, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:19092")!)),
]

func makeClient(_ t: Target, creds: Credentials = adminCreds) -> any TorrentClient {
    switch t.kind {
    case .qbittorrent: QBittorrentClient(serverID: ServerID(t.name), endpoint: t.endpoint, credentials: creds)
    case .transmission: TransmissionClient(serverID: ServerID(t.name), endpoint: t.endpoint, credentials: creds)
    }
}

func transportStats(_ c: any TorrentClient) -> HTTPTransport.Stats {
    if let q = c as? QBittorrentClient { return q.transportStats }
    if let t = c as? TransmissionClient { return t.transportStats }
    return .init()
}

func ms(_ d: Duration) -> String {
    String(format: "%.1fms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func kb(_ bytes: Int) -> String { String(format: "%.1fKB", Double(bytes) / 1024) }

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// MARK: - probe

func probe(_ names: [String]) async {
    for name in names {
        guard let target = presets[name] else { print("未知目标 \(name)"); continue }
        let client = makeClient(target)
        print("===== \(name)")
        do {
            let info = try await client.connect()
            print("version \(info.version)  api \(info.apiVersion)")
            let sync = ServerSync(client: client)
            try await sync.refresh()
            let all = await sync.snapshot().filter { $0.name.hasPrefix("scn-") }.sorted { $0.name < $1.name }
            for t in all {
                print("  \(pad(t.name, 15)) \(pad(t.state.rawValue, 19)) health=\(pad(t.trackerHealth.rawValue, 15)) host=\(pad(t.trackerHost, 10)) err=\(t.errorMessage)")
                if t.trackerHealth != .working {
                    for tr in try await client.trackers(of: t.ref.id) {
                        print("      tier\(tr.tier) \(pad(tr.status.rawValue, 13)) \(tr.url)  \(tr.message)")
                    }
                }
            }
        } catch {
            print("  失败：\(error)")
        }
    }
}

// MARK: - net

func net() async {
    let proxy = URL(string: "https://localhost:18443")!
    let proxyCreds = Credentials(username: "proxyuser", password: "proxypass")

    func attempt(_ label: String, _ kind: ClientKind, _ ep: Endpoint) async -> String? {
        let c = makeClient(Target(name: label, kind: kind, endpoint: ep))
        do {
            let info = try await c.connect()
            _ = try await c.fetchChanges()
            print("  ✓ \(label): \(info.version)")
            return nil
        } catch let TransportError.untrustedCertificate(fp) {
            print("  ✗ \(label): 证书不受信任 sha256=\(fp.prefix(16))…")
            return fp
        } catch {
            print("  ✗ \(label): \(error)")
            return nil
        }
    }

    print("== 自签证书（未确认指纹）")
    let fp = await attempt("qb via proxy, no pin", .qbittorrent,
                           Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, proxyAuth: proxyCreds)) ?? ""

    print("== 确认指纹后")
    _ = await attempt("qb via proxy /qb/ + basic auth", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, proxyAuth: proxyCreds, pinnedCertificateSHA256: fp))
    _ = await attempt("qb via proxy /qbfix/（反代改写 Host）", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "qbfix/"), kind: .proxy, proxyAuth: proxyCreds, pinnedCertificateSHA256: fp))
    _ = await attempt("qb via proxy /qb/ 缺反代密码", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, pinnedCertificateSHA256: fp))
    _ = await attempt("tr via proxy /tr/", .transmission,
                      Endpoint(baseURL: proxy.appending(path: "tr/"), kind: .proxy, pinnedCertificateSHA256: fp))
    _ = await attempt("qb via /cf/ 无 access 头", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "cf/"), kind: .proxy, pinnedCertificateSHA256: fp))
    _ = await attempt("qb via /cf/ 带 access 头", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "cf/"), kind: .proxy,
                               headers: ["CF-Access-Client-Id": "test-client-id", "CF-Access-Client-Secret": "x"],
                               pinnedCertificateSHA256: fp))
    _ = await attempt("qb via /sso/", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "sso/"), kind: .proxy, pinnedCertificateSHA256: fp))
    _ = await attempt("指纹不对", .qbittorrent,
                      Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, proxyAuth: proxyCreds,
                               pinnedCertificateSHA256: String(repeating: "0", count: 64)))

    print("== 多线路选择（内网不通 → 组网不通 → 反代）")
    let candidates = [
        Endpoint(baseURL: URL(string: "http://10.255.255.1:18080")!, kind: .lan, timeout: 2),
        Endpoint(baseURL: URL(string: "http://dead.invalid:18080")!, kind: .overlay, timeout: 2),
        Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, proxyAuth: proxyCreds, pinnedCertificateSHA256: fp),
    ]
    let t0 = ContinuousClock.now
    let outcome = await EndpointSelector.select(candidates, probePath: "api/v2/app/version")
    print("  选中 \(outcome.selected.map { "\($0.kind) \($0.baseURL)" } ?? "无")，耗时 \(ms(ContinuousClock.now - t0))")
    for (ep, why) in outcome.failures.sorted(by: { $0.key.baseURL.absoluteString < $1.key.baseURL.absoluteString }) {
        print("    \(ep.kind) \(ep.baseURL): \(why)")
    }

    print("== 多线路选择（内网可用时不走反代）")
    let t1 = ContinuousClock.now
    let o2 = await EndpointSelector.select([
        Endpoint(baseURL: URL(string: "http://127.0.0.1:18080")!, kind: .lan, timeout: 2),
        Endpoint(baseURL: proxy.appending(path: "qb/"), kind: .proxy, proxyAuth: proxyCreds, pinnedCertificateSHA256: fp),
    ], probePath: "api/v2/app/version")
    print("  选中 \(o2.selected.map { "\($0.kind) \($0.baseURL)" } ?? "无")，耗时 \(ms(ContinuousClock.now - t1))")
}

// MARK: - sync

func syncBench(_ name: String, ticks: Int) async {
    guard let target = presets[name] else { print("未知目标 \(name)"); return }
    let client = makeClient(target)
    do {
        let info = try await client.connect()
        print("\(name) \(info.version)")
        let sync = ServerSync(client: client)
        var before = transportStats(client)
        var t0 = ContinuousClock.now
        let first = try await sync.refresh()
        var total = ContinuousClock.now - t0
        var after = transportStats(client)
        let count = await sync.torrents.count
        print("  全量：\(count) 个种子，\(after.requests - before.requests) 个请求，\(kb(after.bytesReceived - before.bytesReceived))，总耗时 \(ms(total))，其中网络 \(String(format: "%.1fms", (after.networkSeconds - before.networkSeconds) * 1000))，changed=\(first.changed.count)")
        for i in 1...max(ticks, 1) {
            try await Task.sleep(for: .seconds(1))
            before = after
            t0 = ContinuousClock.now
            let cs = try await sync.refresh()
            total = ContinuousClock.now - t0
            after = transportStats(client)
            print("  增量 #\(i)：\(after.requests - before.requests) 个请求，\(kb(after.bytesReceived - before.bytesReceived))，总耗时 \(ms(total))，网络 \(String(format: "%.1fms", (after.networkSeconds - before.networkSeconds) * 1000))，changed=\(cs.changed.count) removed=\(cs.removed.count)")
        }
        let health = TorrentQuery.healthBySite(await sync.snapshot())
        for (site, counts) in health.sorted(by: { $0.key < $1.key }) {
            print("  站点 \(pad(site, 10)) " + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
        }
    } catch {
        print("  失败：\(error)")
    }
}

// MARK: - bench

func bench(_ count: Int) async {
    let server = ServerID("bench")
    let states: [TorrentState] = [.seeding, .stalledSeeding, .downloading, .stopped]
    let hosts = ["pt-a.test", "pt-b.test", "pt-c.test", "pt-d.test"]
    var full: [String: TorrentPatch] = [:]
    for i in 0..<count {
        var p = TorrentPatch()
        p.name = "Some.Show.S01E\(i % 100).2160p.WEB-DL.\(i).mkv"
        p.state = states[i % states.count]
        p.totalSize = Int64(i) * 1_048_576
        p.uploadSpeed = Int64(i % 37) * 1024
        p.ratio = Double(i % 300) / 100
        p.addedAt = 1_700_000_000 + Int64(i)
        p.announceURL = "https://\(hosts[i % hosts.count])/announce?passkey=abc"
        p.trackerHealth = i % 25 == 0 ? .trackerError : .working
        full[String(format: "%040x", i)] = p
    }
    let sync = ServerSync(client: QBittorrentClient(serverID: server, endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:1")!), credentials: adminCreds))

    var t0 = ContinuousClock.now
    await sync.apply(SyncDelta(isFullUpdate: true, upserts: full))
    print("全量合并 \(count) 条：\(ms(ContinuousClock.now - t0))")

    // 模拟一次 1Hz 增量：5% 的种子速度变化
    var delta: [String: TorrentPatch] = [:]
    for i in stride(from: 0, to: count, by: 20) {
        var p = TorrentPatch()
        p.uploadSpeed = Int64.random(in: 0...1_000_000)
        p.uploaded = Int64(i) * 2
        delta[String(format: "%040x", i)] = p
    }
    t0 = ContinuousClock.now
    let cs = await sync.apply(SyncDelta(isFullUpdate: false, upserts: delta))
    print("增量合并 \(delta.count) 条：\(ms(ContinuousClock.now - t0))，changed=\(cs.changed.count)")

    let snapshot = await sync.snapshot()
    for (label, filter, sort) in [
        ("无过滤，按名称", TorrentFilter(), SortKey.name),
        ("无过滤，按上传速度", TorrentFilter(), SortKey.uploadSpeed),
        ("tracker 出错，按添加时间", TorrentFilter(health: [.trackerError, .unreachable, .notWorking]), SortKey.addedAt),
        ("站点 pt-b + 搜索 2160p，按大小", TorrentFilter(trackerHost: "pt-b.test", search: "2160p"), SortKey.size),
    ] {
        t0 = ContinuousClock.now
        let rows = TorrentQuery.run(snapshot, filter: filter, sort: sort, ascending: false)
        print("查询「\(label)」→ \(rows.count) 行：\(ms(ContinuousClock.now - t0))")
    }
    t0 = ContinuousClock.now
    let sites = TorrentQuery.healthBySite(snapshot)
    print("按站点聚合 \(sites.count) 个站点：\(ms(ContinuousClock.now - t0))")
}

// MARK: - actions（端到端：添加 → 停止 → 开始 → 汇报 → 校验 → 删除）

func bencode(_ v: Any) -> Data {
    switch v {
    case let i as Int: return Data("i\(i)e".utf8)
    case let s as String: return bencode(Data(s.utf8))
    case let d as Data: return Data("\(d.count):".utf8) + d
    case let a as [Any]: return a.reduce(Data("l".utf8)) { $0 + bencode($1) } + Data("e".utf8)
    case let m as [String: Any]:
        return m.keys.sorted().reduce(Data("d".utf8)) { $0 + bencode($1) + bencode(m[$1]!) } + Data("e".utf8)
    default: fatalError("bencode \(type(of: v))")
    }
}

func actions(_ name: String) async {
    guard let target = presets[name] else { print("未知目标 \(name)"); return }
    let client = makeClient(target)
    let stamp = String(Int(Date().timeIntervalSince1970))
    func ok(_ label: String, _ cond: Bool, _ extra: String = "") { print("  \(cond ? "✓" : "✗") \(label) \(extra)") }
    do {
        let info = try await client.connect()
        print("===== \(name) \(info.version)")
        let sync = ServerSync(client: client)
        try await sync.refresh()

        // 1. magnet
        var hashBytes = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { hashBytes[i] = UInt8.random(in: 0...255) }
        let hash = hashBytes.map { String(format: "%02x", $0) }.joined()
        try await client.add(.url("magnet:?xt=urn:btih:\(hash)&dn=tc-magnet-\(stamp)&tr=http://pt-a.test:6969/ok/announce"),
                             options: AddOptions(savePath: "/downloads/tc", tags: ["tc-test"], paused: true))
        // 2. .torrent 文件
        let content = Data("transclient \(stamp)".utf8)
        var sha = [UInt8](repeating: 0, count: 20)
        content.withUnsafeBytes { CC_SHA1_shim($0, &sha) }
        let meta: [String: Any] = [
            "announce": "http://pt-b.test:6969/ok/announce",
            "info": ["name": "tc-file-\(stamp).bin", "length": content.count, "piece length": 16384,
                     "pieces": Data(sha), "private": 1] as [String: Any],
        ]
        try await client.add(.file(bencode(meta), filename: "tc-file-\(stamp).torrent"),
                             options: AddOptions(savePath: "/downloads/tc", paused: true))
        try await Task.sleep(for: .seconds(2))
        try await sync.refresh()
        let mine = await sync.snapshot().filter { $0.name.contains(stamp) || $0.infoHashV1.lowercased() == hash }
        ok("添加 magnet + .torrent", mine.count == 2, mine.map { "\($0.name)[\($0.rawState)]" }.joined(separator: " "))
        let ids = mine.map(\.ref.id)
        guard !ids.isEmpty else { return }

        try await client.perform(.start, on: ids)
        try await Task.sleep(for: .seconds(2))
        try await sync.refresh()
        let started = await sync.torrents(ids)
        ok("开始", started.allSatisfy { $0.state != .stopped }, started.map(\.rawState).joined(separator: " "))

        try await client.perform(.stop, on: ids)
        try await Task.sleep(for: .seconds(2))
        try await sync.refresh()
        let stopped = await sync.torrents(ids)
        ok("停止", stopped.allSatisfy { $0.state == .stopped }, stopped.map(\.rawState).joined(separator: " "))

        try await client.perform(.reannounce, on: ids)
        ok("重新汇报（无报错即可）", true)
        try await client.perform(.recheck, on: ids)
        ok("重新校验（无报错即可）", true)

        try await client.perform(.delete(withData: true), on: ids)
        try await Task.sleep(for: .seconds(2))
        try await sync.refresh()
        let left = await sync.torrents(ids)
        ok("删除", left.isEmpty, "剩 \(left.count)")
    } catch {
        print("  ✗ 失败：\(error)")
    }
}

// MARK: - ops（批量操作接口：分类、标签、限速、移动、替换 tracker）

func ops(_ name: String) async {
    guard let target = presets[name] else { print("未知目标 \(name)"); return }
    let client = makeClient(target)
    let stamp = String(Int(Date().timeIntervalSince1970))
    func ok(_ label: String, _ cond: Bool, _ extra: String = "") { print("  \(cond ? "✓" : "✗") \(label) \(extra)") }
    do {
        let info = try await client.connect()
        print("===== \(name) \(info.version)")

        // 全局 / 备用限速：改完读回来核对，再恢复原值
        let orig = try await client.speedLimits()
        print("  原限速 \(orig)")
        let want = SpeedLimits(download: 2048 * 1024, upload: 300 * 1024, altDownload: 100 * 1024, altUpload: 50 * 1024)
        try await client.setSpeedLimits(want)
        let got = try await client.speedLimits()
        ok("全局 + 备用限速", got == want, "\(got)")
        try await client.setSpeedLimits(SpeedLimits(altDownload: want.altDownload, altUpload: want.altUpload))
        let off = try await client.speedLimits()
        ok("取消全局限速", off.download == 0 && off.upload == 0, "\(off)")
        try await client.setSpeedLimits(orig)
        ok("恢复原限速", try await client.speedLimits() == orig)

        let sync = ServerSync(client: client)
        try await sync.refresh()
        let content = Data("ops \(stamp)".utf8)
        var sha = [UInt8](repeating: 0, count: 20)
        content.withUnsafeBytes { CC_SHA1_shim($0, &sha) }
        let meta: [String: Any] = [
            "announce": "http://pt-a.test:6969/ok/announce",
            "info": ["name": "tc-ops-\(stamp).bin", "length": content.count, "piece length": 16384, "pieces": Data(sha), "private": 1] as [String: Any],
        ]
        try await client.add(.file(bencode(meta), filename: "ops.torrent"), options: AddOptions(savePath: "/downloads/tc", paused: true))
        try await Task.sleep(for: .seconds(2))
        try await sync.refresh()
        guard let t0 = await sync.snapshot().first(where: { $0.name.contains(stamp) }) else { print("  ✗ 添加失败"); return }
        let id = t0.ref.id
        func cur() async throws -> Torrent { try await Task.sleep(for: .seconds(1.5)); try await sync.refresh(); return await sync.torrents([id])[0] }

        do {
            try await client.setCategory("tc-cat", on: [id])
            let t = try await cur(); ok("分类（不存在时自动创建）", t.category == "tc-cat", t.category)
        } catch ClientError.unsupported(let m) { ok("分类：按预期不支持", true, m) }

        try await client.updateTags([TagChange(id: id, current: [], final: ["tc1", "tc2"])])
        var t = try await cur(); ok("加标签", Set(t.tags) == ["tc1", "tc2"], "\(t.tags)")
        try await client.updateTags([TagChange(id: id, current: ["tc1", "tc2"], final: ["tc2"])])
        t = try await cur(); ok("删标签", t.tags == ["tc2"], "\(t.tags)")

        try await client.setUploadLimit(512 * 1024, on: [id])
        t = try await cur(); ok("单种限速 512 KB/s", t.uploadLimit == 512 * 1024, "\(t.uploadLimit)")
        try await client.setUploadLimit(0, on: [id])
        t = try await cur(); ok("取消限速", t.uploadLimit == 0, "\(t.uploadLimit)")

        try await client.setLocation("/downloads/tc-moved", moveFiles: true, on: [id])
        t = try await cur(); ok("移动（带文件）", t.savePath.hasPrefix("/downloads/tc-moved"), t.savePath)
        do {
            try await client.setLocation("/downloads/tc-nomove", moveFiles: false, on: [id])
            t = try await cur(); ok("只改路径（不移动文件）", t.savePath.hasPrefix("/downloads/tc-nomove"), t.savePath)
        } catch ClientError.unsupported(let m) { ok("只改路径：按预期不支持", true, m) }

        let old = "http://pt-a.test:6969/ok/announce", new = "http://pt-b.test:6969/ok/announce"
        try await client.replaceTrackerURL(on: id, from: old, to: new)
        t = try await cur(); ok("替换 tracker", t.trackerURLs == [new], "\(t.trackerURLs)")
        let trs = try await client.trackers(of: id).map(\.url)
        ok("替换 tracker（trackers 接口复核）", trs == [new], "\(trs)")

        try await client.perform(.delete(withData: true), on: [id])
        try await Task.sleep(for: .seconds(1.5)); try await sync.refresh()
        ok("清理测试种子", await sync.torrents([id]).isEmpty)
    } catch {
        print("  ✗ 失败：\(error)")
    }
}

/// 文件列表、文件优先级、剩余空间：加一个三文件的暂停种子，改优先级后读回核对，最后删掉
func filesCheck(_ name: String) async {
    guard let target = presets[name] else { print("未知目标 \(name)"); return }
    let client = makeClient(target)
    let stamp = String(Int(Date().timeIntervalSince1970))
    func ok(_ label: String, _ cond: Bool, _ extra: String = "") { print("  \(cond ? "✓" : "✗") \(label) \(extra)") }
    do {
        let info = try await client.connect()
        print("===== \(name) \(info.version)")
        let delta = try await client.fetchChanges()
        let free = delta.stats?.freeSpace
        ok("剩余空间", (free ?? 0) > 0, free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "nil")

        let parts = ["a", "b", "c"].map { Data("file \($0) \(stamp)".utf8) }
        var pieces = Data()
        let all = parts.reduce(Data(), +)
        var sha = [UInt8](repeating: 0, count: 20)
        all.withUnsafeBytes { CC_SHA1_shim($0, &sha) }
        pieces.append(contentsOf: sha)
        let meta: [String: Any] = [
            "announce": "http://pt-a.test:6969/ok/announce",
            "info": [
                "name": "tc-files-\(stamp)",
                "files": zip(["a.txt", "b.txt", "c.txt"], parts).map { ["length": $1.count, "path": ["sub", $0]] as [String: Any] },
                "piece length": 16384, "pieces": pieces, "private": 1,
            ] as [String: Any],
        ]
        try await client.add(.file(bencode(meta), filename: "files.torrent"), options: AddOptions(savePath: "/downloads/tc", paused: true))
        try await Task.sleep(for: .seconds(2))
        let sync = ServerSync(client: client)
        try await sync.refresh()
        guard let t = await sync.snapshot().first(where: { $0.name.contains(stamp) }) else { print("  ✗ 添加失败"); return }
        let id = t.ref.id

        var files = try await client.files(of: id)
        ok("文件列表", files.count == 3 && files.allSatisfy { $0.path.hasPrefix("tc-files-\(stamp)/sub/") }, files.map { "\($0.index):\($0.path):\($0.size):\($0.priority)" }.joined(separator: " "))
        ok("默认优先级都是普通", files.allSatisfy { $0.priority == .normal })

        let idx = files.map(\.index)
        try await client.setFilePriority(.skip, files: [idx[0]], of: id)
        try await client.setFilePriority(.high, files: [idx[1]], of: id)
        var want: [FilePriority] = [.skip, .high, .normal]
        if info.capabilities.contains(.lowFilePriority) {
            try await client.setFilePriority(.low, files: [idx[2]], of: id)
            want[2] = .low
        } else {
            do { try await client.setFilePriority(.low, files: [idx[2]], of: id); ok("「低」按预期不支持", false) }
            catch ClientError.unsupported { ok("「低」按预期不支持", true) }
        }
        try await Task.sleep(for: .seconds(1))
        files = try await client.files(of: id)
        ok("改优先级后读回", files.map(\.priority) == want, "\(files.map(\.priority))")

        try await client.setFilePriority(.normal, files: idx, of: id)
        try await Task.sleep(for: .seconds(1))
        files = try await client.files(of: id)
        ok("恢复普通", files.allSatisfy { $0.priority == .normal }, "\(files.map(\.priority))")

        try await client.perform(.delete(withData: true), on: [id])
        try await Task.sleep(for: .seconds(1.5)); try await sync.refresh()
        ok("清理测试种子", await sync.torrents([id]).isEmpty)
    } catch {
        print("  ✗ 失败：\(error)")
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "probe": await probe(args.count > 1 ? Array(args.dropFirst()) : ["qb53", "qb46", "tr41", "tr40"])
case "net": await net()
case "sync": await syncBench(args.count > 1 ? args[1] : "qb53", ticks: args.count > 2 ? Int(args[2]) ?? 3 : 3)
case "ops":
    for n in (args.count > 1 ? Array(args.dropFirst()) : ["qb53", "qb46", "tr41", "tr40"]) { await ops(n) }
case "files":
    for n in (args.count > 1 ? Array(args.dropFirst()) : ["qb53", "qb46", "tr41", "tr40"]) { await filesCheck(n) }
case "actions":
    for n in (args.count > 1 ? Array(args.dropFirst()) : ["qb53", "qb46", "tr41", "tr40"]) { await actions(n) }
case "apikey":
    // 用法：tcli apikey <key>，用 API key 连 qb53 跑一次同步
    let c = QBittorrentClient(serverID: ServerID("qb53-key"), endpoint: presets["qb53"]!.endpoint, credentials: adminCreds, apiKey: args.count > 1 ? args[1] : "qbt_wrong")
    do {
        let info = try await c.connect()
        let d = try await c.fetchChanges()
        print("API key 连接成功：\(info.version)，\(d.upserts.count) 个种子")
    } catch { print("API key 连接失败：\(error)") }
case "bench": await bench(args.count > 1 ? Int(args[1]) ?? 20_000 : 20_000)
default: print("用法：tcli probe [目标…] | net | sync <目标> [次数] | bench [数量]")
}
