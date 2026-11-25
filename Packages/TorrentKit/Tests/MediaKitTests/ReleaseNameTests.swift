import Foundation
import Testing
@testable import MediaKit

/// 种子名解析。样例来自 MoviePilot 的 tests/cases/meta.py（GPL-3.0），只比较查 TMDB 用得到的字段
@Suite struct ReleaseNameTests {
    struct Case: Decodable {
        let title: String, type: String, cn: String, en: String, year: String, season: String, episode: String
    }

    static let cases: [Case] = {
        let url = Bundle.module.url(forResource: "Fixtures/moviepilot-cases", withExtension: "json")!
        return try! JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }()

    static func norm(_ s: String?) -> String {
        (s ?? "").lowercased().replacingOccurrences(of: #"[\s:：!！?？.,'’\-]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func fmt(_ r: ClosedRange<Int>?, _ p: String) -> String {
        guard let r else { return "" }
        return r.count == 1 ? String(format: "\(p)%02d", r.lowerBound) : String(format: "\(p)%02d-\(p)%02d", r.lowerBound, r.upperBound)
    }

    /// 返回不一致的字段说明，一致时为 nil
    static func diff(_ c: Case) -> String? {
        let r = ReleaseName.parse(c.title)
        var bad: [String] = []
        // 片名：中文名、英文名至少有一个对得上（查 TMDB 只要有一个候选能用）
        let cnOK = c.cn.isEmpty || norm(r.cnTitle) == norm(c.cn)
        let enOK = c.en.isEmpty || norm(r.enTitle) == norm(c.en)
        if !(cnOK && enOK), !((!c.cn.isEmpty && norm(r.cnTitle) == norm(c.cn)) || (!c.en.isEmpty && norm(r.enTitle) == norm(c.en))) {
            bad.append("名字 \(r.cnTitle ?? "-") / \(r.enTitle ?? "-")，应为 \(c.cn) / \(c.en)")
        }
        if (r.year.map(String.init) ?? "") != c.year { bad.append("年份 \(r.year.map(String.init) ?? "-")，应为 \(c.year)") }
        if fmt(r.seasons, "S") != c.season { bad.append("季 \(fmt(r.seasons, "S"))，应为 \(c.season)") }
        if fmt(r.episodes, "E") != c.episode { bad.append("集 \(fmt(r.episodes, "E"))，应为 \(c.episode)") }
        if c.type == "电视剧", r.kind != .tv { bad.append("类型 \(r.kind)，应为剧集") }
        return bad.isEmpty ? nil : "\(c.title)\n    " + bad.joined(separator: "；")
    }

    @Test func moviePilotCases() {
        let failures = Self.cases.compactMap(Self.diff)
        let passed = Self.cases.count - failures.count
        print("ReleaseName：\(passed)/\(Self.cases.count) 个 MoviePilot 样例通过")
        for f in failures { print("  ✗ " + f) }
        // 2026-11-25：71 个里 69 个通过。没过的两个：传颂之物（MoviePilot 期望取日文名，这里取罗马音，查 TMDB 一样能用）、
        // Shadows of the Void（集数要从副标题里认，种子名里没有）。改规则后少于 69 说明有退化
        #expect(passed >= 69)
    }

    @Test func commonReleaseNames() {
        let shawshank = ReleaseName.parse("The.Shawshank.Redemption.1994.1080p.BluRay.x264-GROUP")
        #expect(shawshank.enTitle == "The Shawshank Redemption" && shawshank.year == 1994 && shawshank.kind == .unknown && shawshank.looksLikeVideo)

        let mixed = ReleaseName.parse("流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.DDP5.1-GROUP")
        #expect(mixed.cnTitle == "流浪地球2" && mixed.enTitle == "The Wandering Earth II" && mixed.year == 2023)
        #expect(mixed.titles == ["The Wandering Earth II", "流浪地球2"])

        let pack = ReleaseName.parse("Rick.and.Morty.S01-S03.1080p.BluRay.x264-GROUP")
        #expect(pack.enTitle == "Rick and Morty" && pack.kind == .tv && pack.seasons == 1...3)

        let episode = ReleaseName.parse("House.of.the.Dragon.S02E05.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.H.265-GROUP.mkv")
        #expect(episode.enTitle == "House of the Dragon" && episode.seasons == 2...2 && episode.episodes == 5...5)

        let cn = ReleaseName.parse("繁花 第一季 全30集 2023 2160p WEB-DL")
        #expect(cn.cnTitle == "繁花" && cn.seasons == 1...1 && cn.kind == .tv)

        let explicit = ReleaseName.parse("Some Movie 2020 [tmdbid=12345] 1080p")
        #expect(explicit.tmdbID == 12345 && explicit.enTitle == "Some Movie")
    }

    @Test func notVideo() {
        #expect(!ReleaseName.parse("Adobe Photoshop 2024 v25.0 Multilingual", hints: ["software"]).looksLikeVideo)
        #expect(!ReleaseName.parse("Taylor Swift - 1989 (Taylor's Version) [FLAC]", hints: ["music"]).looksLikeVideo)
        #expect(!ReleaseName.parse("ubuntu-24.04-desktop-amd64.iso").looksLikeVideo)
        #expect(ReleaseName.parse("Movie Name 2019 1080p", hints: ["/downloads/movies"]).kind == .movie)
        #expect(ReleaseName.parse("Show Name 2019 1080p", hints: ["tv"]).kind == .tv)
    }

    @Test func chineseNumbers() {
        #expect(chineseNumber("十二") == 12 && chineseNumber("二十三") == 23 && chineseNumber("一百零五") == 105 && chineseNumber("七") == 7 && chineseNumber("12") == 12)
    }
}
