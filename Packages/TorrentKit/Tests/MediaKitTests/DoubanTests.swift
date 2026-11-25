import Foundation
import Testing
@testable import MediaKit

/// 豆瓣 frodo search/weixin。fixture 是 2026-11-25 实际请求录下的回应
struct DoubanTests {
    static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/douban/\(name)", withExtension: "json")!)
    }

    @Test func requestCarriesQueryAndKey() {
        let url = DoubanClient.request(imdbID: "tt0061418").url!
        #expect(url.host() == "frodo.douban.com" && url.path() == "/api/v2/search/weixin")
        #expect(url.query() == "q=tt0061418&apikey=\(DoubanClient.apiKey)")
    }

    @Test func parsesMovie() throws {
        let s = try #require(try DoubanClient.parse(Self.fixture("search-tt0061418"), kind: .movie))
        #expect(s.id == "1294584" && s.type == "movie" && s.title == "雌雄大盗")
        #expect(s.appURL?.absoluteString == "douban://douban.com/movie/1294584")
        #expect(s.webURL.absoluteString == "https://movie.douban.com/subject/1294584/")
    }

    @Test func parsesTVAsFirstSeason() throws {
        let s = try #require(try DoubanClient.parse(Self.fixture("search-tt0903747"), kind: .tv))
        #expect(s.id == "2373195" && s.type == "tv" && s.title == "绝命毒师 第一季")
        #expect(s.appURL?.absoluteString == "douban://douban.com/tv/2373195")
        #expect(s.webURL.absoluteString == "https://movie.douban.com/subject/2373195/")
    }

    @Test func emptyMeansNotFound() throws {
        #expect(try DoubanClient.parse(Self.fixture("search-empty"), kind: .movie) == nil)
    }

    @Test func prefersSameKindAndSkipsOtherTypes() throws {
        let json = #"""
        {"items": [
          {"layout": "subject", "target_type": "book", "target": {"id": "1", "title": "书"}},
          {"layout": "subject", "target_type": "movie", "target": {"id": "2", "title": "电影", "uri": "douban://douban.com/movie/2"}},
          {"layout": "subject", "target_type": "tv", "target": {"id": "3", "title": "剧", "uri": "douban://douban.com/tv/3"}},
          {"layout": "subject", "target_type": "tv", "target": {"id": "javascript:x", "title": "坏 id"}}
        ]}
        """#
        #expect(try DoubanClient.parse(Data(json.utf8), kind: .tv)?.id == "3")
        #expect(try DoubanClient.parse(Data(json.utf8), kind: .movie)?.id == "2")
        #expect(try DoubanClient.parse(Data(json.utf8), kind: nil)?.id == "2")
    }

    @Test func appURLOnlyForDoubanScheme() {
        #expect(DoubanSubject(id: "1", uri: "https://evil.example/1", title: "", type: "movie").appURL == nil)
        #expect(DoubanSubject(id: "1", uri: nil, title: "", type: "movie").appURL == nil)
    }

    @Test func errorReplyIsNotParsedAsEmpty() throws {
        // 400 由 subject(imdbID:) 按状态码抛错；回应体本身没有 items，单独解析也只会得到 nil
        #expect(try DoubanClient.parse(Self.fixture("error-invalid-apikey"), kind: .movie) == nil)
    }
}
