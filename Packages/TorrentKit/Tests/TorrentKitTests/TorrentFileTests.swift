import Foundation
import Testing
@testable import TorrentKit

@Suite struct TorrentFileTests {
    @Test func parsesMultiFileTorrent() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-multifile", withExtension: "torrent", subdirectory: "Fixtures"))
        let t = try TorrentFile.parse(Data(contentsOf: url))
        #expect(t.name == "Sample.Pack")
        #expect(t.totalSize == 1024)
        #expect(t.files.map(\.path) == ["a.mkv", "Subs/a.chs.srt"])
        #expect(t.trackers == ["https://tracker.aurora-pt.example/announce?passkey=abc", "https://backup.example/announce"])
        #expect(t.isPrivate)
        // 期望值由 Python 对同一份 info 字典做 SHA1 得到
        #expect(t.infoHashV1 == "249baaeeb60fded396255d7497e70123e4717bca")
    }

    @Test func rejectsGarbage() {
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile.parse(Data("<html>login</html>".utf8)) }
        #expect(throws: TorrentFile.ParseError.self) { try TorrentFile.parse(Data("d4:infoi1ee".utf8)) }
    }
}
