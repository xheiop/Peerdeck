import Foundation
import Testing
@testable import MediaKit

/// TMDB 客户端和匹配。fixture 是 2026-11-25 用真实密钥录下的回应（不含密钥）
@Suite(.serialized) struct TMDBTests {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/tmdb/\(name)", withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    @Test func requestCarriesKeyOrBearer() {
        let v3 = TMDBClient(credential: String(repeating: "a", count: 32)).request("search/movie", [URLQueryItem(name: "query", value: "x")])
        #expect(v3.url!.query()!.contains("api_key=" + String(repeating: "a", count: 32)))
        #expect(v3.value(forHTTPHeaderField: "Authorization") == nil)

        let token = "eyJhbGciOiJIUzI1NiJ9." + String(repeating: "b", count: 60)
        let v4 = TMDBClient(credential: token).request("search/movie", [])
        #expect(v4.url!.query() == nil)
        #expect(v4.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test func decodesMovieDetails() throws {
        let d = try JSONDecoder().decode(RawDetails.self, from: Self.fixture("movie-278-zh")).details(.movie, language: "zh-CN")
        #expect(d.title == "肖申克的救赎" && d.originalTitle == "The Shawshank Redemption" && d.year == 1994)
        #expect(d.imdbID == "tt0111161" && d.runtime == 142 && d.genres == ["剧情", "犯罪"])
        #expect(d.imdbURL?.absoluteString == "https://www.imdb.com/title/tt0111161/")
        #expect(d.doubanURL?.absoluteString == "https://search.douban.com/movie/subject_search?search_text=tt0111161")
        #expect(TMDBImage.url(d.posterPath, size: "w185")?.absoluteString == "https://image.tmdb.org/t/p/w185/aAdnwqwkKX5PPcr8EdtaiA8AZVl.jpg")
    }

    @Test func decodesTVDetailsWithSeasons() throws {
        let d = try JSONDecoder().decode(RawDetails.self, from: Self.fixture("tv-60625-zh")).details(.tv, language: "zh-CN")
        #expect(d.title == "瑞克和莫蒂" && d.year == 2013 && d.imdbID == "tt2861424")
        #expect(d.numberOfSeasons == 9 && d.season(2)?.name == "第 2 季" && d.season(2)?.posterPath != nil)
        #expect(d.tmdbURL.absoluteString == "https://www.themoviedb.org/tv/60625")
    }

    @Test func matcherPicksSameTitleAndYear() throws {
        struct Page: Decodable { let results: [TMDBSearchResult] }
        let movie = try JSONDecoder().decode(Page.self, from: Self.fixture("search-movie-shawshank-zh")).results
        let release = ReleaseName.parse("The.Shawshank.Redemption.1994.1080p.BluRay.x264-GROUP")
        let m = try #require(MediaMatcher.best(movie.map { (.movie, $0) }, for: release))
        #expect(m.result.id == 278 && m.confident)

        // 年份差太多：不算匹配
        let wrongYear = ReleaseName.parse("The.Shawshank.Redemption.2011.1080p.BluRay.x264-GROUP")
        #expect(MediaMatcher.best(movie.map { (.movie, $0) }, for: wrongYear) == nil)

        // 剧集：Rick and Morty 和 Rick and Morty: The Anime 都搜得到，选同名的
        let tv = try JSONDecoder().decode(Page.self, from: Self.fixture("search-tv-rick-zh")).results
        let pack = ReleaseName.parse("Rick.and.Morty.S06E06.JuRicksic.Mort.1080p.HMAX.WEBRip.DD5.1.X264-NTb")
        let t = try #require(MediaMatcher.best(tv.map { (.tv, $0) }, for: pack))
        #expect(t.result.id == 60625 && t.confident)
    }

    @Test func matcherUsesChineseTitle() throws {
        struct Page: Decodable { let results: [TMDBSearchResult] }
        let multi = try JSONDecoder().decode(Page.self, from: Self.fixture("search-multi-wandering-zh")).results
        let release = ReleaseName.parse("流浪地球2 2023 2160p WEB-DL")
        let m = try #require(MediaMatcher.best(multi.map { (.movie, $0) }, for: release))
        #expect(m.result.displayTitle == "流浪地球2" && m.confident)
    }

    @Test func soleResultWithOtherTitle() {
        // TMDB 按别名搜到、返回的是中文名和原文名：只有一个结果且年份对得上，就认
        let witch = TMDBSearchResult(id: 615173, title: "魔女2", originalTitle: "마녀 2", releaseDate: "2022-06-15")
        let release = ReleaseName.parse("The Witch Part 2 The Other One 2022 1080p WEB-DL AAC5.1 H.264-tG1R0")
        #expect(MediaMatcher.best([(.movie, witch)], for: release)?.confident == true)
        // 年份对不上就不认
        #expect(MediaMatcher.best([(.movie, witch)], for: ReleaseName.parse("The Witch Part 2 2015 1080p WEB-DL")) == nil)
        // 结果不止一个、片名又对不上：最多算「不确定」
        let other = TMDBSearchResult(id: 1, title: "别的", originalTitle: "Other", releaseDate: "2022-01-01")
        #expect(MediaMatcher.best([(.movie, witch), (.movie, other)], for: release)?.confident != true)
    }

    @Test func normalize() {
        #expect(MediaMatcher.normalize("Spider-Man: No Way Home") == "spider man no way home")
        #expect(MediaMatcher.normalize("Ｆａｓｔ ＆ Ｆｕｒｉｏｕｓ") == "fast and furious")
        #expect(MediaMatcher.titleSimilarity("Amélie", "Amelie") == 1)
    }

    @Test func resolverSearchesThenStops() async throws {
        StubProtocol.replies = [
            "/3/search/movie": Self.fixture("search-movie-shawshank-zh"),
        ]
        StubProtocol.seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = TMDBClient(credential: String(repeating: "a", count: 32), session: URLSession(configuration: config))
        let m = try await MediaResolver(client: client).resolve(ReleaseName.parse("The.Shawshank.Redemption.1994.1080p.BluRay.x264-GROUP"), language: "zh-CN")
        #expect(m?.result.id == 278)
        // 电影搜到了就不再搜剧集
        #expect(StubProtocol.seen == ["/3/search/movie"])
    }
}

/// 按路径回放 fixture；没有对应 fixture 的路径回 404
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: Data] = [:]
    nonisolated(unsafe) static var seen: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path()
        Self.seen.append(path)
        let data = Self.replies[path]
        let resp = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
