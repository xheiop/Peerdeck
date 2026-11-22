import Foundation
import Testing
@testable import QBittorrentClient
@testable import SyncEngine
@testable import TorrentKit
@testable import TransmissionClient

// fixture 都是从 dev/compose.yaml 的真实容器录下来的（只保留 scn-* 场景种子）

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func qbClient() -> QBittorrentClient {
    QBittorrentClient(
        serverID: ServerID("t"),
        endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:1")!),
        credentials: Credentials(username: "u", password: "p")
    )
}

/// 按名字取种子
func byName(_ torrents: [String: Torrent]) -> [String: Torrent] {
    Dictionary(uniqueKeysWithValues: torrents.values.map { ($0.name, $0) })
}

func mirror(_ delta: SyncDelta) async -> [String: Torrent] {
    let sync = ServerSync(client: qbClient())
    await sync.apply(delta)
    return byName(await sync.torrents)
}

@Suite struct QBittorrentTests {
    @Test func qb53HealthFromFlags() async throws {
        let main = try JSONDecoder().decode(QBMainData.self, from: fixture("qb53-maindata-full"))
        let delta = await qbClient().apply(main)
        #expect(delta.isFullUpdate)
        let t = await mirror(delta)
        #expect(t["scn-ok.bin"]?.trackerHealth == .working)
        #expect(t["scn-unreg.bin"]?.trackerHealth == .trackerError)
        #expect(t["scn-mixed.bin"]?.trackerHealth == .trackerError)
        #expect(t["scn-warn.bin"]?.trackerHealth == .trackerWarning)
        #expect(t["scn-err500.bin"]?.trackerHealth == .unreachable)
        #expect(t["scn-dead.bin"]?.trackerHealth == .unreachable)
        #expect(t["scn-unreg.bin"]?.trackerHost == "pt-b.test")
        #expect(t["scn-unreg.bin"]?.isPrivate == true)
        #expect(t["scn-ok.bin"]?.state == .stalledDownloading)
    }

    @Test func qb46HealthWithoutFlags() async throws {
        let main = try JSONDecoder().decode(QBMainData.self, from: fixture("qb46-maindata-full"))
        let t = await mirror(await qbClient().apply(main))
        // 4.6.7 只能分出「有没有正常工作的 tracker」
        #expect(t["scn-ok.bin"]?.trackerHealth == .working)
        #expect(t["scn-warn.bin"]?.trackerHealth == .working)
        #expect(t["scn-mixed.bin"]?.trackerHealth == .working) // tier 2 正常就看不出 tier 1 未注册
        #expect(t["scn-unreg.bin"]?.trackerHealth == .notWorking)
        #expect(t["scn-err500.bin"]?.trackerHealth == .notWorking)
        #expect(t["scn-dead.bin"]?.trackerHealth == .notWorking)
        // tracker 字段为空时，站点分组仍然要能用（来自 maindata 的 trackers 映射）
        #expect(t["scn-unreg.bin"]?.currentTracker == "")
        #expect(t["scn-unreg.bin"]?.trackerHost == "pt-b.test")
        #expect(t["scn-ok.bin"]?.isPrivate == nil)
    }

    @Test func qb46IncrementalKeepsOtherFields() async throws {
        let client = qbClient()
        let sync = ServerSync(client: client)
        await sync.apply(await client.apply(try JSONDecoder().decode(QBMainData.self, from: fixture("qb46-maindata-full"))))
        let before = byName(await sync.torrents)["scn-ok.bin"]!

        let inc = try JSONDecoder().decode(QBMainData.self, from: fixture("qb46-maindata-incremental-paused"))
        let delta = await client.apply(inc)
        #expect(!delta.isFullUpdate)
        let cs = await sync.apply(delta)
        #expect(cs.changed == [before.ref])

        let after = byName(await sync.torrents)["scn-ok.bin"]!
        #expect(after.state == .stopped)
        #expect(after.rawState == "pausedDL")
        #expect(after.trackerHealth == .unknown) // 停止的种子不判断
        #expect(after.name == before.name)
        #expect(after.trackerHost == before.trackerHost)
        #expect(after.totalSize == before.totalSize)
    }

    @Test func qbAllTimeTotalsSurviveIncremental() async throws {
        var stats = ServerStats()
        let full = try JSONDecoder().decode(QBMainData.self, from: fixture("qb53-maindata-full"))
        stats.apply(try #require(full.server_state).patch())
        #expect(stats.allTimeUploaded == 3332)
        #expect(stats.allTimeDownloaded == 2772)
        // 增量里没有 alltime_* 时保持原值
        let inc = try JSONDecoder().decode(QBMainData.self, from: Data(#"{"rid":2,"server_state":{"dl_info_speed":5}}"#.utf8))
        stats.apply(try #require(inc.server_state).patch())
        #expect(stats.downloadSpeed == 5)
        #expect(stats.allTimeUploaded == 3332)
    }

    @Test func trackerMapIncrementalMovesAnnounceURL() async throws {
        let client = qbClient()
        let full = """
        {"rid":1,"full_update":true,
         "torrents":{"aa":{"name":"a","state":"uploading","tracker":"","trackers_count":1},
                     "bb":{"name":"b","state":"uploading","tracker":"","trackers_count":1}},
         "trackers":{"http://x.test/announce":["aa","bb"]}}
        """
        let sync = ServerSync(client: client)
        await sync.apply(await client.apply(try JSONDecoder().decode(QBMainData.self, from: Data(full.utf8))))
        #expect(await sync.torrents["bb"]?.trackerHost == "x.test")

        // bb 换了 tracker：旧 URL 的列表只剩 aa，新 URL 出现
        let inc = """
        {"rid":2,"trackers":{"http://x.test/announce":["aa"],"http://y.test/announce":["bb"]}}
        """
        let delta = await client.apply(try JSONDecoder().decode(QBMainData.self, from: Data(inc.utf8)))
        #expect(Set(delta.upserts.keys) == ["bb"])
        await sync.apply(delta)
        #expect(await sync.torrents["aa"]?.trackerHost == "x.test")
        #expect(await sync.torrents["bb"]?.trackerHost == "y.test")

        let removed = """
        {"rid":3,"trackers_removed":["http://y.test/announce"]}
        """
        await sync.apply(await client.apply(try JSONDecoder().decode(QBMainData.self, from: Data(removed.utf8))))
        #expect(await sync.torrents["bb"]?.trackerHost == "")
    }

    @Test func sessionCookieBothFormats() throws {
        func resp(_ cookie: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": cookie])!
        }
        #expect(QBittorrentClient.sessionCookie(resp("SID=abc; HttpOnly; path=/; SameSite=Strict")) == "SID=abc")
        #expect(QBittorrentClient.sessionCookie(resp("QBT_SID_18080=o8A/b+c=; HttpOnly; SameSite=Lax; expires=Fri, 20-Nov-2026 14:12:12 GMT; path=/")) == "QBT_SID_18080=o8A/b+c=")
        #expect(QBittorrentClient.sessionCookie(resp("other=1")) == nil)
    }
}

@Suite struct TransmissionTests {
    @Test func tr41Health() async throws {
        let list = try JSONDecoder().decode(TREnvelope<TRTorrentList>.self, from: fixture("tr41-torrent-get")).arguments
        var t: [String: Torrent] = [:]
        for raw in list.torrents {
            var torrent = Torrent(ref: TorrentRef(server: ServerID("tr"), id: raw.hashString ?? ""))
            torrent.apply(raw.patch())
            t[torrent.name] = torrent
        }
        #expect(t["scn-ok.bin"]?.trackerHealth == .working)
        #expect(t["scn-unreg.bin"]?.trackerHealth == .trackerError)
        #expect(t["scn-unreg.bin"]?.errorMessage == "Unregistered torrent")
        #expect(t["scn-warn.bin"]?.trackerHealth == .trackerWarning)
        #expect(t["scn-err500.bin"]?.trackerHealth == .unreachable)
        #expect(t["scn-dead.bin"]?.trackerHealth == .unreachable)
        #expect(t["scn-mixed.bin"]?.state == .queued)
        #expect(t["scn-mixed.bin"]?.trackerHealth == .unknown)
        #expect(t["scn-unreg.bin"]?.trackerHost == "pt-b.test")
        #expect(t["scn-ok.bin"]?.infoHashV1.count == 40)
    }
}

extension TransmissionTests {
    @Test func trSessionStatsCumulative() throws {
        let json = #"{"downloadSpeed":10,"uploadSpeed":20,"cumulative-stats":{"uploadedBytes":123,"downloadedBytes":45,"filesAdded":0}}"#
        let s = try JSONDecoder().decode(TRSessionStats.self, from: Data(json.utf8))
        #expect(s.cumulative?.uploadedBytes == 123)
        #expect(s.cumulative?.downloadedBytes == 45)
        let old = try JSONDecoder().decode(TRSessionStats.self, from: Data(#"{"downloadSpeed":1,"uploadSpeed":2}"#.utf8))
        #expect(old.cumulative == nil)
    }
}

@Suite struct CoreTests {
    @Test func semver() {
        #expect(SemVer(parsing: "v5.3.0") == SemVer(5, 3, 0))
        #expect(SemVer(parsing: "2.16.2") == SemVer(2, 16, 2))
        #expect(SemVer(parsing: "4.1.4 (a6d907d9ea)") == SemVer(4, 1, 4))
        #expect(SemVer(parsing: "2.11") == SemVer(2, 11, 0))
        #expect(SemVer(parsing: "garbage") == nil)
        #expect(SemVer(2, 9, 3) < SemVer(2, 11, 0))
    }

    @Test func naturalNameSort() {
        #expect(Torrent.sortKey("Show.S01E2") < Torrent.sortKey("show.s01e10"))
        let s = ServerID("s")
        let names = ["b10", "B2", "a", "b1"]
        let rows = names.enumerated().map { i, n in
            var t = Torrent(ref: TorrentRef(server: s, id: String(i))); t.name = n; return t
        }
        let sorted = TorrentQuery.run(rows, filter: TorrentFilter(), sort: .name).map { names[Int($0.id)!] }
        #expect(sorted == ["a", "b1", "B2", "b10"])
    }

    @Test func hostExtraction() {
        #expect(Torrent.host(of: "https://Tracker.PT-A.test:443/announce?passkey=x") == "tracker.pt-a.test")
        #expect(Torrent.host(of: "udp://tracker.test:6969") == "tracker.test")
        #expect(Torrent.host(of: "") == "")
    }

    @Test func fullUpdateReplacesAndReportsRemoved() async {
        let sync = ServerSync(client: qbClient())
        var p = TorrentPatch(); p.name = "a"
        await sync.apply(SyncDelta(isFullUpdate: true, upserts: ["1": p, "2": p]))
        let cs = await sync.apply(SyncDelta(isFullUpdate: true, upserts: ["2": p]))
        #expect(cs.removed == [TorrentRef(server: ServerID("t"), id: "1")])
        #expect(await sync.torrents.keys.sorted() == ["2"])
    }

    @Test func incrementalSkipsNoopChanges() async {
        let sync = ServerSync(client: qbClient())
        var p = TorrentPatch(); p.name = "a"; p.uploadSpeed = 10
        await sync.apply(SyncDelta(isFullUpdate: true, upserts: ["1": p]))
        var same = TorrentPatch(); same.uploadSpeed = 10
        let cs = await sync.apply(SyncDelta(isFullUpdate: false, upserts: ["1": same]))
        #expect(cs.changed.isEmpty)
    }

    @Test func queryFilterAndStableSort() {
        let s = ServerID("s")
        func t(_ id: String, _ name: String, _ up: Int64, _ health: TrackerHealth) -> Torrent {
            var x = Torrent(ref: TorrentRef(server: s, id: id))
            x.name = name; x.uploadSpeed = up; x.trackerHealth = health
            x.announceURL = "http://site.test/a"
            return x
        }
        let rows = [t("3", "c", 5, .working), t("1", "a", 5, .trackerError), t("2", "b", 9, .unreachable)]
        let ids = TorrentQuery.run(rows, filter: TorrentFilter(health: [.trackerError, .unreachable]), sort: .uploadSpeed, ascending: false).map(\.id)
        #expect(ids == ["2", "1"])
        // 速度相同时按 id 稳定排序
        let all = TorrentQuery.run(rows, filter: TorrentFilter(), sort: .uploadSpeed, ascending: true).map(\.id)
        #expect(all == ["1", "3", "2"])
    }
}
