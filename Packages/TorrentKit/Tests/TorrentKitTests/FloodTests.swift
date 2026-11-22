import Foundation
import os
import Testing
@testable import FloodClient
@testable import SyncEngine
@testable import TorrentKit

// fixture 录自 Flood 4.16.4 + rTorrent 0.9.8 / qB 5.3.0 / TR 4.1.4（测试容器、测试种子）

@Suite struct FloodTests {
    private func list(_ name: String) throws -> [String: FloodTorrent] {
        var mirror = FloodListMirror()
        let all = try mirror.replaceAll(fixture("flood416-\(name)-list"))
        return Dictionary(uniqueKeysWithValues: all.values.map { ($0.name, $0) })
    }

    private func torrent(_ fields: [String: Any]) -> FloodTorrent {
        var json: [String: Any] = ["name": "t", "sizeBytes": 100, "status": ["seeding"], "trackerURIs": ["a.example"]]
        json.merge(fields) { $1 }
        return FloodTorrent(hash: "ABC", json: json)
    }

    @Test func detectsBackendFromSettings() throws {
        let all = try JSONDecoder().decode([String: FloodSettings].self, from: fixture("flood416-settings"))
        #expect(FloodBackend.detect(try #require(all["rt"])) == .rTorrent)
        #expect(FloodBackend.detect(try #require(all["qb"])) == .qBittorrent)
        #expect(FloodBackend.detect(try #require(all["tr"])) == .transmission)
        // 这两个没有环境，按源码里填的常量构造
        #expect(FloodBackend.detect(FloodSettings(networkLocalAddress: [""], networkPortOpen: true, piecesMemoryMax: -1, trackersNumWant: -1)) == .deluge)
        #expect(FloodBackend.detect(FloodSettings(networkLocalAddress: [], networkMaxOpenFiles: 0, networkPortOpen: false, networkPortRange: "", piecesMemoryMax: 0, trackersNumWant: 0)) == .neptune)
        // rTorrent 还没就绪时 settings 是 {}：不能误认成别的后端
        #expect(FloodBackend.detect(FloodSettings()) == .unknown)
    }

    @Test func rTorrentHealth() throws {
        let t = try list("rt")
        func health(_ name: String) throws -> FloodHealth.Diagnosis { FloodHealth.diagnose(try #require(t[name]), backend: .rTorrent) }
        #expect(try health("rt-unreg") == .init(health: .trackerError, message: "Unregistered torrent"))
        #expect(try health("rt-ok").health == .working)
        #expect(try health("rt-dead").health == .unreachable)
        #expect(try health("rt-err500").health == .unreachable)
        #expect(try !health("rt-err500").message.contains("  "))
        #expect(try health("rt-paused").health == .unknown)
        // 挂了两个站，只有一个报未注册：不能算被拒绝，否则会进清理
        #expect(try health("rt-multi").health == .trackerWarning)
    }

    @Test func rTorrentLocalError() {
        let d = FloodHealth.diagnose(torrent(["message": "Hash check on download completion found bad chunks", "status": ["seeding", "error"]]), backend: .rTorrent)
        #expect(d.localError)
        #expect(d.health == .unknown)
        #expect(FloodHealth.diagnose(torrent(["message": "Tried all trackers."]), backend: .rTorrent).health == .unreachable)
    }

    @Test func transmissionHealth() throws {
        let t = try list("tr")
        func health(_ name: String) throws -> TrackerHealth { FloodHealth.diagnose(try #require(t[name]), backend: .transmission).health }
        #expect(try health("tr-unreg") == .trackerError)
        #expect(try health("tr-warn") == .trackerWarning)
        #expect(try health("tr-err500") == .unreachable)
        #expect(try health("tr-dead") == .unreachable)
        #expect(try health("tr-ok") == .working)
        for message in ["No data found! Ensure your drives are connected", "Please verify local data! Piece #3 is corrupt.", "No space left on device", ""] {
            let d = FloodHealth.diagnose(torrent(["message": message, "status": ["error"]]), backend: .transmission)
            #expect(d.localError && d.health == .unknown, "\(message)")
        }
    }

    /// qB 后端的「未注册」和普通警告长得一样，还最多过期 1 小时：任何情况下都不能进「被拒绝」和清理
    @Test func qbBehindFloodNeverRejected() throws {
        let t = try list("qb")
        #expect(try FloodHealth.diagnose(#require(t["qb-unreg"]), backend: .qBittorrent) == .init(health: .trackerWarning, message: "Unregistered torrent"))
        for torrent in t.values {
            let h = FloodHealth.diagnose(torrent, backend: .qBittorrent).health
            #expect(h != .trackerError && h != .notWorking && h != .unreachable)
        }
        #expect(!FloodBackend.qBittorrent.reportsTrackerHealth)
        for backend in [FloodBackend.deluge, .neptune, .unknown] {
            let d = FloodHealth.diagnose(torrent(["message": "Unregistered torrent", "status": ["seeding", "warning"]]), backend: backend)
            #expect(d.health != .trackerError && d.health != .notWorking)
        }
    }

    @Test func patchMatchesDirectAdapters() throws {
        let multi = try #require(list("rt")["rt-multi"])
        let p = multi.patch(backend: .rTorrent, announceURL: "http://tracker.alpha.test/")
        // 辅种保护按小写 v1 hash 和名字认，大小也要和直连一个口径
        #expect(p.infoHashV1 == multi.hash.lowercased())
        #expect(p.totalSize == 2048)
        #expect(p.savePath == "/data/seed/rt")
        #expect(p.trackerURLs == [])
        #expect(try #require(list("qb")["qb-multi"]).savePath(.qBittorrent) == "/data/seed/qb")
    }

    @Test func progressEdgeCases() {
        // TR 后端：磁力还没元数据时 0 == 0，被标成 complete
        let magnet = torrent(["sizeBytes": 0, "status": ["downloading", "complete"]])
        #expect(magnet.progress == 0)
        #expect(magnet.state(localError: false) == .metadata)
        // 只选了部分文件：按选中的大小算
        #expect(torrent(["sizeBytes": 100, "selectedSizeBytes": 40, "bytesDone": 40, "percentComplete": 40]).progress == 1)
        // NaN / Infinity 序列化成 null
        #expect(torrent(["ratio": NSNull(), "eta": NSNull()]).ratio == 0)
        #expect(torrent(["eta": 12.7]).eta == 12)
    }

    @Test func sseParser() {
        var parser = SSEParser()
        let raw = ": heartbeat\n\nid: 1\r\nevent: A\r\ndata: {\"名\":\"中文\"}\r\n\r\nevent: B\ndata: x\ndata: y\n\nevent: C\n"
        let events = Array(raw.utf8).compactMap { parser.feed($0) }
        #expect(events == [.init(name: "A", data: Data("{\"名\":\"中文\"}".utf8)), .init(name: "B", data: Data("x\ny".utf8))])
    }

    @Test func jsonPatch() throws {
        var m = FloodListMirror()
        _ = try m.replaceAll(Data(#"{"A":{"name":"a","status":["seeding","inactive"],"tags":[]},"B":{"name":"b"}}"#.utf8))
        let (changed, removed) = try m.apply(Data(#"""
        [{"op":"replace","path":"/A/status/1","value":"error"},{"op":"add","path":"/A/status/2","value":"active"},
         {"op":"remove","path":"/A/status/0"},{"op":"add","path":"/A/tags/-","value":"x"},
         {"op":"remove","path":"/B"},{"op":"add","path":"/C","value":{"name":"c"}}]
        """#.utf8))
        #expect(changed["A"]?.status == ["error", "active"])
        #expect(changed["A"]?.tags == ["x"])
        #expect(changed["C"]?.name == "c")
        #expect(removed == ["B"])
        // 对不上的补丁要报错（调用方重连拿全量），不能悄悄带着错的镜像继续
        #expect(throws: (any Error).self) { try m.apply(Data(#"[{"op":"replace","path":"/Z/name","value":"z"}]"#.utf8)) }
        #expect(throws: (any Error).self) { try m.apply(Data(#"[{"op":"remove","path":"/A/status/9"}]"#.utf8)) }
    }

    @Test func streamAccumulatesBetweenPolls() throws {
        let box = OSAllocatedUnfairLock(initialState: FloodEventStream.Snapshot())
        var mirror = FloodListMirror()
        func send(_ name: String, _ json: String) throws {
            try FloodEventStream.handle(.init(name: name, data: Data(json.utf8)), mirror: &mirror, box: box)
        }
        try send("TORRENT_LIST_FULL_UPDATE", #"{"A":{"name":"a"},"B":{"name":"b"}}"#)
        box.withLock { $0.needsFull = false }
        try send("TORRENT_LIST_DIFF_CHANGE", #"[{"op":"remove","path":"/B"}]"#)
        try send("TORRENT_LIST_DIFF_CHANGE", #"[{"op":"add","path":"/B","value":{"name":"b2"}},{"op":"remove","path":"/A"}]"#)
        let s = box.withLock { $0 }
        #expect(s.changed == ["B"] && s.removed == ["A"])
        #expect(s.torrents["B"]?.name == "b2")
    }

    @Test func originHasNoPasskey() {
        let urls = ["udp://other.example:80/announce", "https://Tracker.Site.example:8443/announce?passkey=secret"]
        #expect(FloodClient.origin(domain: "site.example", urls: urls) == "https://tracker.site.example/")
        #expect(FloodClient.origin(domain: "site.example", urls: ["https://notsite.example/a"]) == "https://site.example/")
        #expect(FloodClient.jwt("jwt=abc.def; Path=/; HttpOnly") == "jwt=abc.def")
        #expect(FloodClient.jwt(nil) == nil)
    }

    @Test func freeSpaceNeedsMatchingMount() {
        let disks = [FloodDisk(target: "/data", avail: 5), FloodDisk(target: "/data/big", avail: 9)]
        #expect(FloodDisk.free(disks, for: "/data/big/downloads") == 9)
        #expect(FloodDisk.free(disks, for: "/data/bigger") == 5)
        #expect(FloodDisk.free(disks, for: "/database") == nil)
    }
}
