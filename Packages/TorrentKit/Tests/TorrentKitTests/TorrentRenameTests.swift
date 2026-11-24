import Testing
@testable import TorrentKit

@Test func torrentRenameValidation() {
    #expect(TorrentRename.problem("Show.S01.1080p") == nil)
    #expect(TorrentRename.problem("  带空格 的名字 ") == nil)
    #expect(TorrentRename.problem("") != nil)
    #expect(TorrentRename.problem("   ") != nil)
    #expect(TorrentRename.problem("a/b") != nil)
    #expect(TorrentRename.problem(#"a\b"#) != nil)
    #expect(TorrentRename.problem(".") != nil)
    #expect(TorrentRename.problem("..") != nil)
}
