import Foundation

/// TMDB（themoviedb.org）API v3 的最小客户端：搜索、详情、校验密钥。
/// 文档：https://developer.themoviedb.org/docs 。使用条款要求在 app 里注明来源，见 app 的「关于」。
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case movie, tv
}

public enum TMDBError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case rateLimited
    case notFound
    case http(Int)
    case network(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unauthorized: String(localized: "The TMDB key was rejected")
        case .rateLimited: String(localized: "TMDB is limiting requests. Try again later.")
        case .notFound: String(localized: "Not found on TMDB")
        case .http(let code): "HTTP \(code)"
        case .network(let msg): msg
        case .decoding(let msg): String(localized: "Unexpected reply from TMDB: \(msg)")
        }
    }
}

/// 搜索结果里的一条（电影和剧集字段名不一样：title / name、release_date / first_air_date）
public struct TMDBSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String?
    public var name: String?
    public var originalTitle: String?
    public var originalName: String?
    public var releaseDate: String?
    public var firstAirDate: String?
    public var posterPath: String?
    public var overview: String?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, popularity
        case originalTitle = "original_title", originalName = "original_name"
        case releaseDate = "release_date", firstAirDate = "first_air_date"
        case posterPath = "poster_path", voteAverage = "vote_average", voteCount = "vote_count", mediaType = "media_type"
    }

    public var displayTitle: String { title ?? name ?? "" }
    public var originalDisplayTitle: String { originalTitle ?? originalName ?? "" }
    public var year: Int? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
}

/// 详情页需要的字段，电影和剧集合在一起
public struct TMDBDetails: Codable, Sendable, Equatable {
    public struct Season: Codable, Sendable, Equatable {
        public var number: Int
        public var name: String
        public var posterPath: String?
        public var overview: String?
    }

    public var kind: MediaKind
    public var id: Int
    public var title: String
    public var originalTitle: String
    public var year: Int?
    public var overview: String
    public var posterPath: String?
    public var voteAverage: Double
    public var voteCount: Int
    public var genres: [String]
    /// 电影片长（分钟）
    public var runtime: Int?
    public var numberOfSeasons: Int?
    public var seasons: [Season]
    public var imdbID: String?
    /// 请求时用的语言（zh-CN、en-US）
    public var language: String

    public var tmdbURL: URL { URL(string: "https://www.themoviedb.org/\(kind.rawValue)/\(id)")! }
    public var imdbURL: URL? { imdbID.flatMap { $0.isEmpty ? nil : URL(string: "https://www.imdb.com/title/\($0)/") } }
    /// 豆瓣没有开放 API，用 IMDb 编号在豆瓣搜索跳转
    public var doubanURL: URL? {
        guard let imdbID, !imdbID.isEmpty else { return nil }
        return URL(string: "https://search.douban.com/movie/subject_search?search_text=\(imdbID)")
    }

    public func season(_ n: Int) -> Season? { seasons.first { $0.number == n } }
}

public enum TMDBImage {
    /// 文档建议从 /configuration 取 base_url；它多年没变过（2026-11-25 取到的也是这个），就直接写死，省一次请求
    public static let base = "https://image.tmdb.org/t/p/"

    /// size：w92 / w154 / w185 / w342 / w500 / w780 / original
    public static func url(_ path: String?, size: String = "w342") -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: base + size + path)
    }
}

public struct TMDBClient: Sendable {
    /// v3 的 API Key（32 位十六进制，放查询参数）或 v4 的 Read Access Token（JWT，放 Bearer 头），两种都能用
    public let credential: String
    let session: URLSession
    static let base = URL(string: "https://api.themoviedb.org/3/")!

    public init(credential: String, session: URLSession = .shared) {
        self.credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var isBearer: Bool { credential.count > 40 }

    /// 拼请求。单独拿出来方便测试（不发请求）
    func request(_ path: String, _ query: [URLQueryItem]) -> URLRequest {
        var c = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = query
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: credential)) }
        c.queryItems = items.isEmpty ? nil : items
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let req = request(path, query)
        for attempt in 0..<2 {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw TMDBError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                do { return try JSONDecoder().decode(T.self, from: data) } catch { throw TMDBError.decoding("\(error)") }
            case 401: throw TMDBError.unauthorized
            case 404: throw TMDBError.notFound
            case 429:
                // 按 Retry-After 等一次（最多 5 秒），还不行就放弃
                guard attempt == 0 else { throw TMDBError.rateLimited }
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(for: .seconds(min(max(wait, 0.5), 5)))
            default: throw TMDBError.http(status)
            }
        }
        throw TMDBError.rateLimited
    }

    struct Page: Decodable { let results: [TMDBSearchResult] }

    /// 电影可以按上映年份过滤，剧集按首播年份过滤
    public func search(_ kind: MediaKind, query: String, year: Int?, language: String) async throws -> [TMDBSearchResult] {
        var q = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "language", value: language), URLQueryItem(name: "include_adult", value: "false")]
        if let year { q.append(URLQueryItem(name: kind == .movie ? "year" : "first_air_date_year", value: String(year))) }
        let page: Page = try await get("search/\(kind.rawValue)", q)
        return page.results
    }

    /// 详情，带上外部 ID（IMDb 编号）
    public func details(_ kind: MediaKind, id: Int, language: String) async throws -> TMDBDetails {
        let raw: RawDetails = try await get("\(kind.rawValue)/\(id)", [URLQueryItem(name: "language", value: language), URLQueryItem(name: "append_to_response", value: "external_ids")])
        return raw.details(kind, language: language)
    }

    /// 校验密钥：请求一次 /configuration（不需要任何参数，返回很小）
    public func verify() async throws {
        struct Config: Decodable {}
        let _: Config = try await get("configuration")
    }
}

/// 详情接口的原始回应。中文资料缺失时片名会回落成原名，但简介是空字符串（2026-11-25 实测）
struct RawDetails: Decodable {
    struct Genre: Decodable { let name: String }
    struct RawSeason: Decodable {
        let season_number: Int
        let name: String?
        let poster_path: String?
        let overview: String?
    }
    struct External: Decodable { let imdb_id: String? }

    let id: Int
    let title: String?
    let name: String?
    let original_title: String?
    let original_name: String?
    let release_date: String?
    let first_air_date: String?
    let overview: String?
    let poster_path: String?
    let vote_average: Double?
    let vote_count: Int?
    let genres: [Genre]?
    let runtime: Int?
    let number_of_seasons: Int?
    let seasons: [RawSeason]?
    let imdb_id: String?
    let external_ids: External?

    func details(_ kind: MediaKind, language: String) -> TMDBDetails {
        let date = release_date ?? first_air_date ?? ""
        return TMDBDetails(
            kind: kind, id: id,
            title: title ?? name ?? "",
            originalTitle: original_title ?? original_name ?? "",
            year: date.count >= 4 ? Int(date.prefix(4)) : nil,
            overview: overview ?? "",
            posterPath: poster_path,
            voteAverage: vote_average ?? 0,
            voteCount: vote_count ?? 0,
            genres: genres?.map(\.name) ?? [],
            runtime: runtime.flatMap { $0 > 0 ? $0 : nil },
            numberOfSeasons: number_of_seasons,
            seasons: (seasons ?? []).map { .init(number: $0.season_number, name: $0.name ?? "", posterPath: $0.poster_path, overview: $0.overview) },
            imdbID: external_ids?.imdb_id ?? imdb_id,
            language: language)
    }
}
