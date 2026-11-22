import Foundation
import Testing
@testable import TorrentKit
@testable import TransmissionClient

// 这里每一条错了都是删错种子或删掉用户的数据

private func torrent(_ server: String, _ id: String, name: String, hash: String = "", size: Int64 = 100) -> Torrent {
    var t = Torrent(ref: TorrentRef(server: ServerID(server), id: id))
    var p = TorrentPatch()
    p.name = name
    p.infoHashV1 = hash
    p.totalSize = size
    t.apply(p)
    return t
}

private func table(_ ts: Torrent...) -> [TorrentRef: Torrent] {
    Dictionary(uniqueKeysWithValues: ts.map { ($0.ref, $0) })
}

private let a = ServerID("a"), b = ServerID("b")

@Suite struct SharedDataTests {
    @Test func protectsSameHashOrNameIgnoringSize() {
        let t = torrent("a", "1", name: "Season", hash: "h1", size: 100)
        #expect(SharedData.protected([t], among: [t, torrent("b", "2", name: "Season", hash: "h2", size: 40)]) == [t.ref])
        #expect(SharedData.protected([t], among: [t, torrent("b", "2", name: "Renamed", hash: "h1")]) == [t.ref])
        #expect(SharedData.protected([t], among: [t, torrent("b", "2", name: "Other", hash: "h2")]).isEmpty)
    }

    @Test func allUsersInsideTheSetAreNotProtected() {
        let x = torrent("a", "1", name: "Same", hash: "h1"), y = torrent("b", "2", name: "Same", hash: "h2")
        #expect(SharedData.protected([x, y], among: [x, y]).isEmpty)
    }

    @Test func protectionPropagates() {
        // x 和 y 同 hash，y 和范围外的 z 同名：三个是同一份数据
        let x = torrent("a", "1", name: "N1", hash: "h1"), y = torrent("b", "2", name: "N2", hash: "h1")
        let z = torrent("b", "3", name: "N2", hash: "h3")
        #expect(SharedData.protected([x, y], among: [x, y, z]) == [x.ref, y.ref])
    }

    @Test func emptyHashOrNameDoesNotMatchEverything() {
        let x = torrent("a", "1", name: ""), y = torrent("b", "2", name: "")
        #expect(SharedData.protected([x], among: [x, y]).isEmpty)
    }
}

@Suite struct DeletionDecisionTests {
    let t = torrent("a", "1", name: "T", hash: "h")

    @Test func deletesDataOnlyWhenEveryServerWasChecked() {
        let yes = DeletionDecision.resolve(refs: [t.ref], wantsData: [t.ref], torrents: table(t), fresh: [a, b], allServers: [a, b])
        #expect(yes.removeData == [t.ref] && yes.filesKept == 0)
        let no = DeletionDecision.resolve(refs: [t.ref], wantsData: [t.ref], torrents: table(t), fresh: [a], allServers: [a, b])
        #expect(no.remove == [t.ref] && no.removeData.isEmpty && no.filesKept == 1)
    }

    @Test func lateTwinKeepsFiles() {
        let twin = torrent("b", "2", name: "T", hash: "other")
        let d = DeletionDecision.resolve(refs: [t.ref], wantsData: [t.ref], torrents: table(t, twin), fresh: [a, b], allServers: [a, b])
        #expect(d.remove == [t.ref] && d.removeData.isEmpty)
    }

    @Test func cleanupSkipsRecoveredAndUnchecked() {
        let recovered = DeletionDecision.resolve(refs: [t.ref], wantsData: [], torrents: table(t), fresh: [a], allServers: [a]) { _ in false }
        #expect(recovered.remove.isEmpty && recovered.skipped == [t.ref])
        let unchecked = DeletionDecision.resolve(refs: [t.ref], wantsData: [], torrents: table(t), fresh: [], allServers: [a]) { _ in true }
        #expect(unchecked.remove.isEmpty && unchecked.skipped == [t.ref])
    }

    @Test func skippedTorrentStillProtectsItsTwin() {
        let twin = torrent("a", "2", name: "T", hash: "other")
        let d = DeletionDecision.resolve(refs: [t.ref, twin.ref], wantsData: [t.ref, twin.ref], torrents: table(t, twin), fresh: [a], allServers: [a]) { $0.ref != twin.ref }
        #expect(d.remove == [t.ref] && d.removeData.isEmpty && d.skipped == [twin.ref])
    }

    @Test func missingTorrent() {
        #expect(DeletionDecision.resolve(refs: [t.ref], wantsData: [], torrents: [:], fresh: [a], allServers: [a]) == DeletionDecision())
        #expect(DeletionDecision.resolve(refs: [t.ref], wantsData: [], torrents: [:], fresh: [], allServers: [a]).skipped == [t.ref])
    }
}

@Suite struct TransmissionIdentityTests {
    private let A = String(repeating: "a", count: 40), B = String(repeating: "b", count: 40), C = String(repeating: "c", count: 40)

    private func list(_ rows: [(Int, String)], removed: [Int]? = nil) -> TRTorrentList {
        TRTorrentList(torrents: rows.map { TRTorrent(id: $0.0, hashString: $0.1, name: $0.1) }, removed: removed)
    }

    @Test func identityIsTheHash() {
        let m = TransmissionClient.merge(list([(1, A), (2, B)]), whole: true, known: [:])
        #expect(Set(m.upserts.keys) == [A, B])
        #expect(m.known == [1: A, 2: B])
    }

    @Test func renumberingAfterRestart() {
        // 删过 A、重启之后：B 从 2 变成 1，C 从 3 变成 2
        let known = [2: B, 3: C]
        #expect(TransmissionClient.idsConflict(list([(2, C)]).torrents, known: known))
        let m = TransmissionClient.merge(list([(1, B), (2, C)]), whole: true, known: known)
        #expect(m.removed.isEmpty && m.known == [1: B, 2: C])
    }

    @Test func removedNumbersBecomeHashes() {
        let m = TransmissionClient.merge(list([], removed: [1, 99]), whole: false, known: [1: A, 2: B])
        #expect(m.removed == [A] && m.known == [2: B])
        #expect(TransmissionClient.merge(list([(1, A)]), whole: true, known: [1: A, 2: B]).removed == [B])
        // 删了又加回来
        #expect(TransmissionClient.merge(list([(5, A)], removed: [1]), whole: false, known: [1: A]).removed.isEmpty)
    }

    @Test func onlyHashesAreSentAsIDs() throws {
        #expect(try TransmissionClient.hashes([A]) == [A])
        for bad in ["2", "recently-active", "", String(repeating: "g", count: 40)] {
            #expect(throws: (any Error).self) { try TransmissionClient.hashes([bad]) }
        }
    }
}
