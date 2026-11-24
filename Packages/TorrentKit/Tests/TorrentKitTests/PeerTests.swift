import Foundation
import Testing
@testable import FloodClient
@testable import QBittorrentClient
@testable import TorrentKit
@testable import TransmissionClient

// fixture 录自开发环境（2026-11-24）：qb46 做种并限速上传，qb53 / tr41 / tr40 / Flood（TR 后端）下载同一个测试种子，
// 用 qB 的 torrents/addPeers 让它们互连。地址是 Docker 内网地址

private func byClient(_ peers: [Peer]) -> [String: Peer] {
    Dictionary(peers.map { ($0.client, $0) }, uniquingKeysWith: { a, _ in a })
}

@Test func qb46Peers() throws {
    let peers = try JSONDecoder().decode(QBPeerList.self, from: fixture("qb46-torrent-peers")).model()
    #expect(peers.count == 3)
    let qb = try #require(byClient(peers)["qBittorrent/5.3.0"])
    #expect(qb.endpoint == "192.168.107.2:6881")
    #expect(qb.connection == "μTP")
    #expect(qb.uploadRate == 94894)
    #expect(qb.uploaded == 2000196)
    #expect(qb.flags == "U E P")
    #expect(qb.flagsHelp?.contains("E = Encrypted traffic") == true)
    #expect(qb.encrypted == true)
    #expect(qb.incoming == false)
    #expect(qb.countryCode == nil) // 没开「解析国家」时是空字符串
    #expect(abs(qb.progress - 0.005) < 0.0001)
}

@Test func qb53Peers() throws {
    let peers = try JSONDecoder().decode(QBPeerList.self, from: fixture("qb53-torrent-peers")).model()
    #expect(peers.count == 3)
    let seed = try #require(byClient(peers)["qBittorrent/4.6.7"])
    #expect(seed.progress == 1)
    #expect(seed.downloadRate == 95441)
    #expect(seed.downloaded == 2097931)
    #expect(seed.incoming == true) // flags 里有 I
}

@Test func qbPeersFallBackToKey() throws {
    // 没有 ip / port 字段时从字典键拆（IPv6 带方括号）
    let json = #"{"peers":{"[2001:db8::1]:51413":{"client":"x","dl_speed":1},"10.0.0.2:6881":{}}}"#
    let peers = try JSONDecoder().decode(QBPeerList.self, from: Data(json.utf8)).model().sorted { $0.endpoint < $1.endpoint }
    #expect(peers.map(\.endpoint) == ["10.0.0.2:6881", "[2001:db8::1]:51413"])
    #expect(peers.map(\.address) == ["10.0.0.2", "2001:db8::1"])
}

@Test func trPeers() throws {
    let tr41 = try JSONDecoder().decode(TRPeerList.self, from: fixture("tr41-torrent-get-peers")).model()
    #expect(tr41.count == 3)
    let seed = try #require(byClient(tr41)["qBittorrent/4.6.7"])
    #expect(seed.downloadRate == 40960)
    #expect(seed.downloaded == 638976)
    #expect(seed.uploaded == 0)
    #expect(seed.connection == "BT")
    #expect(seed.flags == "DEI")
    #expect(seed.incoming == true)
    #expect(seed.progress == 1)
    // TR 4.0 没有 bytes_to_client / bytes_to_peer
    let tr40 = try JSONDecoder().decode(TRPeerList.self, from: fixture("tr40-torrent-get-peers")).model()
    #expect(tr40.count == 3)
    #expect(tr40.allSatisfy { $0.downloaded == nil && $0.uploaded == nil })
}

@Test func trPeersEmpty() throws {
    let json = #"{"torrents":[{"id":1,"peers":[]}]}"#
    #expect(try JSONDecoder().decode(TRPeerList.self, from: Data(json.utf8)).model().isEmpty)
    #expect(try JSONDecoder().decode(TRPeerList.self, from: Data(#"{"torrents":[]}"#.utf8)).model().isEmpty)
}

@Test func floodPeers() throws {
    let peers = try JSONDecoder().decode([FloodPeer].self, from: fixture("flood416-tr-peers")).map(\.model)
    #expect(peers.count == 4)
    let seed = try #require(byClient(peers)["qBittorrent/4.6.7"])
    #expect(seed.progress == 1) // completedPercent 是 0…100
    #expect(seed.downloadRate == 24576)
    #expect(seed.port == 0)
    #expect(seed.endpoint == "192.168.107.4") // 没有端口就只显示地址
    #expect(seed.connection == nil && seed.downloaded == nil)
    #expect(peers.allSatisfy { $0.encrypted == true && $0.incoming == false })
}

@Test func peerDisplayOrder() {
    let idle = Peer(address: "10.0.0.1", port: 1, progress: 1)
    let busy = Peer(address: "10.0.0.2", port: 1, progress: 0, downloadRate: 10)
    let half = Peer(address: "10.0.0.3", port: 1, progress: 0.5)
    #expect([idle, half, busy].sorted(by: Peer.displayOrder).map(\.address) == ["10.0.0.2", "10.0.0.1", "10.0.0.3"])
}
