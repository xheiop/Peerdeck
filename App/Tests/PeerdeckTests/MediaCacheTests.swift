import Foundation
import Testing
@testable import Peerdeck

/// 影视信息缓存文件（media-cache.json）的兼容性
struct MediaCacheTests {
    /// 0.4.0 写的缓存没有 douban。不能因此整个读不出来：里面有用户的手动改正
    @Test func readsCacheWithoutDouban() throws {
        let old = #"{"matches": {"movie|x|": {"kind": "movie", "id": 278, "confident": true, "manual": true, "notVideo": false, "at": 0}}, "details": {}}"#
        let c = try JSONDecoder().decode(MediaLibrary.Cache.self, from: Data(old.utf8))
        #expect(c.matches["movie|x|"]?.manual == true)
        #expect(c.douban.isEmpty)
    }

    @Test func roundTripsDouban() throws {
        var c = MediaLibrary.Cache()
        c.douban["tt0111161"] = .init(subject: .init(id: "1292052", uri: "douban://douban.com/movie/1292052", title: "肖申克的救赎", type: "movie"), at: Date(timeIntervalSinceReferenceDate: 0))
        c.douban["tt9999999"] = .init(subject: nil, at: Date(timeIntervalSinceReferenceDate: 0))
        let back = try JSONDecoder().decode(MediaLibrary.Cache.self, from: JSONEncoder().encode(c))
        #expect(back.douban["tt0111161"]?.subject?.id == "1292052")
        #expect(back.douban.keys.contains("tt9999999") && back.douban["tt9999999"]?.subject == nil)
    }
}
