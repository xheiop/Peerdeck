import Foundation
import Testing
@testable import Peerdeck

/// 检查更新：版本比较、GitHub 回应的解析、只打开本仓库的页面
@Suite struct UpdateCheckTests {
    static func reply(_ tag: String, url: String = "https://github.com/xheiop/Peerdeck/releases/tag/v0.2.0") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)","draft":false,"prerelease":false}"#.utf8)
    }

    @Test func versionComparison() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.99.99"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        // 后缀不看：0.2.0-beta.1 和 0.2.0 一样新
        #expect(!UpdateCheck.isNewer("0.2.0", than: "0.2.0-beta.1"))
    }

    @Test func newerReleaseIsAvailable() {
        let r = UpdateCheck.outcome(data: Self.reply("v0.2.0"), status: 200, current: "0.1.0")
        #expect(r == .available(UpdateCheck.Release(version: "0.2.0", page: URL(string: "https://github.com/xheiop/Peerdeck/releases/tag/v0.2.0")!), current: "0.1.0"))
    }

    @Test func sameOrOlderIsUpToDate() {
        #expect(UpdateCheck.outcome(data: Self.reply("v0.1.0"), status: 200, current: "0.1.0") == .upToDate(current: "0.1.0"))
        #expect(UpdateCheck.outcome(data: Self.reply("0.1.0"), status: 200, current: "0.2.0") == .upToDate(current: "0.2.0"))
    }

    @Test func onlyOpensThisRepository() {
        for url in ["https://example.com/xheiop/Peerdeck/releases/tag/v0.2.0", "http://github.com/xheiop/Peerdeck/releases/tag/v0.2.0",
                    "https://github.com/someone/else/releases/tag/v0.2.0", "not a url"] {
            guard case .available(let r, _) = UpdateCheck.outcome(data: Self.reply("v0.2.0", url: url), status: 200, current: "0.1.0") else {
                Issue.record("应该有新版本：\(url)"); continue
            }
            #expect(r.page == UpdateCheck.releasesPage)
        }
    }

    @Test func failures() {
        guard case .failed = UpdateCheck.outcome(data: Data(), status: 404, current: "0.1.0") else { Issue.record("404"); return }
        guard case .failed = UpdateCheck.outcome(data: Data(), status: 403, current: "0.1.0") else { Issue.record("403"); return }
        guard case .failed = UpdateCheck.outcome(data: Data("<html>".utf8), status: 200, current: "0.1.0") else { Issue.record("坏 JSON"); return }
    }
}
