import Foundation

/// 从 TMDB 搜索结果里挑出和种子名最像的一个
public struct MediaMatch: Sendable, Equatable {
    public var kind: MediaKind
    public var result: TMDBSearchResult
    public var score: Double
    /// 片名完全相同，年份也对得上（或者没写年份且同名的只有这一个）
    public var confident: Bool
}

/// 一条搜索结果，以及它在那次搜索里的名次和那次搜索的结果数
public struct MediaCandidate: Sendable {
    public var kind: MediaKind
    public var result: TMDBSearchResult
    public var rank: Int
    public var count: Int

    public init(kind: MediaKind, result: TMDBSearchResult, rank: Int, count: Int) {
        self.kind = kind
        self.result = result
        self.rank = rank
        self.count = count
    }
}

public enum MediaMatcher {
    /// 低于这个分数不算匹配
    public static let threshold = 0.75

    /// 片名归一化：小写、去重音、全角转半角、去标点、& 换成 and
    public static func normalize(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        // 去掉空格再比（中文名里的空格、Spider-Man / Spiderman）
        if x.replacingOccurrences(of: " ", with: "") == y.replacingOccurrences(of: " ", with: "") { return 0.95 }
        let short = x.count < y.count ? x : y, long = x.count < y.count ? y : x
        if short.count >= 4, long.hasPrefix(short + " ") || long.hasSuffix(" " + short) { return 0.75 }
        let sx = Set(x.split(separator: " ")), sy = Set(y.split(separator: " "))
        let jaccard = Double(sx.intersection(sy).count) / Double(max(sx.union(sy).count, 1))
        return jaccard * 0.7
    }

    public static func score(_ c: MediaCandidate, release: ReleaseName) -> (score: Double, title: Double, yearOK: Bool) {
        let r = c.result, kind = c.kind
        let names = [r.title, r.name, r.originalTitle, r.originalName].compactMap { $0 }
        var title = release.titles.flatMap { t in names.map { titleSimilarity(t, $0) } }.max() ?? 0
        // 种子名是罗马音或英文译名、TMDB 返回的是中文名和原文名时，片名对不上，但 TMDB 也会搜别名，排第一的通常就是。
        // 只有一个结果时更可信（2026-11-25 实测：Hataraku Maou sama → 打工吧！魔王大人，The Witch Part 2 → 魔女2）
        if title < 0.6, c.rank == 0 { title = c.count == 1 ? 0.8 : 0.6 }
        var s = title
        var yearOK = false
        if let ry = release.year, let ty = r.year {
            let diff = ry - ty
            // 剧集第 2 季以后，种子名里的年份通常是这一季的年份，比首播晚
            let laterSeason = kind == .tv && (release.season ?? 1) > 1
            if diff == 0 { s += 0.3; yearOK = true }
            else if abs(diff) == 1 { s += 0.15; yearOK = true }
            else if laterSeason && diff > 0 { s += 0.1; yearOK = true }
            else { s -= 0.4 }
        }
        switch (release.kind, kind) {
        case (.tv, .tv), (.movie, .movie): s += 0.1
        case (.tv, .movie), (.movie, .tv): s -= 0.3
        default: break
        }
        // 同分时偏向人多的那个
        s += min(log10(1 + Double(r.voteCount ?? 0)) / 100, 0.04)
        return (s, title, yearOK)
    }

    /// 同一次搜索的结果，按 TMDB 返回的顺序
    public static func best(_ results: [(MediaKind, TMDBSearchResult)], for release: ReleaseName) -> MediaMatch? {
        best(results.enumerated().map { MediaCandidate(kind: $1.0, result: $1.1, rank: $0, count: results.count) }, for: release)
    }

    public static func best(_ candidates: [MediaCandidate], for release: ReleaseName) -> MediaMatch? {
        let scored = candidates.map { ($0, score($0, release: release)) }
        guard let top = scored.max(by: { $0.1.score < $1.1.score }), top.1.score >= threshold else { return nil }
        let sameTitle = scored.filter { $0.1.title >= 0.95 }.count
        let soleResult = top.0.count == 1 && top.0.rank == 0 && top.1.yearOK
        let confident = (top.1.title >= 0.95 && (top.1.yearOK || (release.year == nil && sameTitle == 1))) || soleResult
        return MediaMatch(kind: top.0.kind, result: top.0.result, score: top.1.score, confident: confident)
    }
}

/// 解析好的种子名 → 搜 TMDB → 挑最像的一个
public struct MediaResolver: Sendable {
    public let client: TMDBClient

    public init(client: TMDBClient) { self.client = client }

    /// 返回 nil 表示没找到。每个候选片名、每种类型最多搜两次（带年份没结果时去掉年份再搜）
    public func resolve(_ release: ReleaseName, language: String) async throws -> MediaMatch? {
        if let id = release.tmdbID {
            for kind in kinds(release) {
                if let d = try? await client.details(kind, id: id, language: language) {
                    let r = TMDBSearchResult(id: d.id, title: d.title, originalTitle: d.originalTitle, releaseDate: d.year.map { "\($0)" }, posterPath: d.posterPath, overview: d.overview, voteAverage: d.voteAverage, voteCount: d.voteCount)
                    return MediaMatch(kind: kind, result: r, score: 2, confident: true)
                }
            }
        }
        var pool: [MediaCandidate] = []
        for title in release.titles {
            for kind in kinds(release) {
                // 第 2 季以后的年份不是首播年份，不拿来过滤剧集
                let year = kind == .tv && (release.season ?? 1) > 1 ? nil : release.year
                var found = try await client.search(kind, query: title, year: year, language: language)
                if found.isEmpty, year != nil {
                    found = try await client.search(kind, query: title, year: nil, language: language)
                }
                let top = Array(found.prefix(10))
                pool += top.enumerated().map { MediaCandidate(kind: kind, result: $1, rank: $0, count: found.count) }
                if let m = MediaMatcher.best(pool, for: release), m.confident { return m }
            }
        }
        return MediaMatcher.best(pool, for: release)
    }

    func kinds(_ release: ReleaseName) -> [MediaKind] {
        switch release.kind {
        case .tv: [.tv]
        case .movie: [.movie]
        case .unknown: [.movie, .tv]
        }
    }
}
