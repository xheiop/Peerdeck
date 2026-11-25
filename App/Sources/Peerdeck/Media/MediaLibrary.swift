import Foundation
import MediaKit
import Observation
import TorrentKit

/// 种子详情里的影视信息：解析种子名 → 查 TMDB → 缓存。
///
/// - 只在打开某个种子的详情时才查，不批量预取。
/// - 匹配结果按「解析出来的片名 + 年份 + 类型」缓存，同名的种子（包括辅种）共用；手动改正的也存在这里，不过期。
/// - 资料按「类型 / id / 语言」缓存 30 天（TMDB 条款要求不超过 6 个月），没匹配到的 7 天后重查。
/// - 密钥：用户在设置里填的（Keychain）优先，没有就用构建时注入的内置密钥（Info.plist 的 PeerdeckTMDBKey）。
@MainActor @Observable
final class MediaLibrary {
    enum State: Equatable {
        case notVideo
        case loading
        case notFound
        case failed(String)
        case found(Entry)
    }

    struct Entry: Equatable {
        var details: TMDBDetails
        var confident: Bool
        var manual: Bool
        /// 种子是第几季（单季时用来显示这一季的海报和名字）
        var season: Int?
    }

    /// 豆瓣条目（按 IMDb 编号）。nil = 还没查；.none = 查不到或请求失败，用搜索链接兜底
    enum DoubanState: Equatable {
        case found(DoubanSubject)
        case none
    }

    let model: AppModel
    private(set) var states: [String: State] = [:]
    private(set) var doubanStates: [String: DoubanState] = [:]
    /// 用户自己填的密钥（Keychain，由 AppModel 读写：配置导入也会改它）
    var userKey: String { model.tmdbKey }
    let builtInKey: String?

    @ObservationIgnored private var cache: Cache
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var doubanInFlight: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var releases: [String: ReleaseName] = [:]

    init(model: AppModel) {
        self.model = model
        let plistKey = (Bundle.main.object(forInfoDictionaryKey: "PeerdeckTMDBKey") as? String)?.trimmingCharacters(in: .whitespaces)
        // 没注入时 iOS 的 Info.plist 里是空字符串
        builtInKey = plistKey.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        cache = AppData.load("media-cache.json", as: Cache.self) ?? Cache()
    }

    var enabled: Bool {
        get { model.prefs.mediaInfo }
        set { model.prefs.mediaInfo = newValue }
    }

    var activeKey: String? { userKey.isEmpty ? builtInKey : userKey }
    /// 开着并且有密钥
    var isActive: Bool { enabled && activeKey != nil }

    /// 按当前界面语言取资料
    static var language: String { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-CN" : "en-US" }
    static var isChineseUI: Bool { language == "zh-CN" }

    // MARK: 查询

    func release(of t: Torrent) -> ReleaseName {
        if let r = releases[t.name] { return r }
        let r = ReleaseName.parse(t.name, hints: [t.category, t.savePath])
        releases[t.name] = r
        return r
    }

    /// 匹配缓存的键：同一部作品的不同种子（不同站点的辅种、不同版本）共用
    func signature(of t: Torrent) -> String {
        let r = release(of: t)
        if let id = r.tmdbID { return "tmdb|\(id)" }
        let titles = r.titles.map(MediaMatcher.normalize).joined(separator: "|")
        return "\(r.kind.rawValue)|\(titles)|\(r.year.map(String.init) ?? "")"
    }

    func state(for t: Torrent) -> State? {
        guard isActive else { return nil }
        if !release(of: t).looksLikeVideo, cache.matches[signature(of: t)]?.manual != true { return .notVideo }
        return states[signature(of: t)]
    }

    /// 详情出现时调用。已经有结果（或者正在查）就什么都不做
    func load(_ t: Torrent) async {
        guard isActive, let key = activeKey else { return }
        let sig = signature(of: t)
        let r = release(of: t)
        if let s = states[sig], s != .loading { if case .failed = s {} else { return } }
        if let task = inFlight[sig] { await task.value; return }
        let manual = cache.matches[sig]?.manual == true
        if !r.looksLikeVideo, !manual { return }
        let task = Task { await self.resolve(sig: sig, release: r, key: key) }
        inFlight[sig] = task
        await task.value
        inFlight[sig] = nil
    }

    private func resolve(sig: String, release r: ReleaseName, key: String) async {
        let lang = Self.language
        let client = TMDBClient(credential: key)
        let now = Date()
        var match = cache.matches[sig]
        if let m = match, !m.manual, now.timeIntervalSince(m.at) > (m.id == nil ? 7 : 30) * 86400 { match = nil }
        if match == nil { states[sig] = .loading }
        do {
            if match == nil {
                let found = try await MediaResolver(client: client).resolve(r, language: lang)
                match = MatchRecord(kind: found?.kind, id: found?.result.id, confident: found?.confident ?? false, manual: false, notVideo: false, at: now)
                cache.matches[sig] = match
                scheduleSave()
            }
            guard let m = match else { return }
            if m.notVideo { states[sig] = .notVideo; return }
            guard let kind = m.kind, let id = m.id else { states[sig] = .notFound; return }
            let details = try await self.details(kind, id: id, client: client, language: lang)
            states[sig] = .found(Entry(details: details, confident: m.confident || m.manual, manual: m.manual, season: r.seasons.flatMap { $0.count == 1 ? $0.lowerBound : nil }))
        } catch {
            states[sig] = .failed("\(error)")
        }
    }

    private func details(_ kind: MediaKind, id: Int, client: TMDBClient, language: String) async throws -> TMDBDetails {
        let key = "\(kind.rawValue)/\(id)/\(language)"
        if let d = cache.details[key], Date().timeIntervalSince(d.at) < 30 * 86400 { return d.details }
        var d = try await client.details(kind, id: id, language: language)
        // 中文资料缺失时 TMDB 的片名会回落成原名，简介却是空的：补英文简介
        if d.overview.isEmpty, language != "en-US", let en = try? await client.details(kind, id: id, language: "en-US") {
            d.overview = en.overview
        }
        cache.details[key] = DetailRecord(details: d, at: Date())
        scheduleSave()
        return d
    }

    // MARK: 豆瓣

    /// 豆瓣链接要用的条目。查到了返回条目；还没查、查不到、失败都返回 nil（卡片用搜索链接）
    func doubanSubject(imdbID: String) -> DoubanSubject? {
        if case .found(let s)? = doubanStates[imdbID] { return s }
        return nil
    }

    /// 卡片出现时调用（只在中文界面）。查到的缓存 30 天，查不到的 7 天；请求失败不缓存，这次运行里不再重试
    func loadDouban(imdbID: String, kind: MediaKind) async {
        guard !imdbID.isEmpty, doubanStates[imdbID] == nil, !doubanInFlight.contains(imdbID) else { return }
        if let r = cache.douban[imdbID], Date().timeIntervalSince(r.at) < (r.subject == nil ? 7 : 30) * 86400 {
            doubanStates[imdbID] = r.subject.map { .found($0) } ?? DoubanState.none
            return
        }
        doubanInFlight.insert(imdbID)
        defer { doubanInFlight.remove(imdbID) }
        do {
            let subject = try await DoubanClient().subject(imdbID: imdbID, kind: kind)
            cache.douban[imdbID] = DoubanRecord(subject: subject, at: Date())
            scheduleSave()
            doubanStates[imdbID] = subject.map { .found($0) } ?? DoubanState.none
        } catch {
            Log.info("豆瓣查询失败（\(imdbID)），用搜索链接：\(error)")
            doubanStates[imdbID] = DoubanState.none
        }
    }

    // MARK: 手动改正

    /// 匹配面板里搜索
    func search(_ query: String, kind: MediaKind, year: Int?) async throws -> [TMDBSearchResult] {
        guard let key = activeKey else { return [] }
        return try await TMDBClient(credential: key).search(kind, query: query, year: year, language: Self.language)
    }

    func setMatch(_ t: Torrent, kind: MediaKind, id: Int) async {
        let sig = signature(of: t)
        cache.matches[sig] = MatchRecord(kind: kind, id: id, confident: true, manual: true, notVideo: false, at: Date())
        scheduleSave()
        states[sig] = nil
        await load(t)
    }

    func markNotVideo(_ t: Torrent) {
        let sig = signature(of: t)
        cache.matches[sig] = MatchRecord(kind: nil, id: nil, confident: true, manual: true, notVideo: true, at: Date())
        states[sig] = .notVideo
        scheduleSave()
    }

    /// 去掉手动改正，重新自动匹配
    func resetMatch(_ t: Torrent) async {
        let sig = signature(of: t)
        cache.matches[sig] = nil
        states[sig] = nil
        scheduleSave()
        await load(t)
    }

    func retry(_ t: Torrent) async {
        states[signature(of: t)] = nil
        await load(t)
    }

    // MARK: 设置

    func clearCache() {
        cache = Cache(matches: cache.matches.filter { $0.value.manual }, details: [:])
        states = [:]
        doubanStates = [:]
        PosterCache.shared.clear()
        scheduleSave()
    }

    /// 校验并保存用户的密钥。空字符串表示删掉，改用内置的。返回错误说明
    func saveUserKey(_ key: String) async -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty {
            do { try await TMDBClient(credential: k).verify() } catch { return "\(error)" }
        }
        TMDBKeyStore.save(k)
        model.tmdbKey = k
        states = [:]
        return nil
    }

    /// 测试当前生效的密钥
    func testActiveKey() async -> String? {
        guard let key = activeKey else { return L("No TMDB key") }
        do { try await TMDBClient(credential: key).verify(); return nil } catch { return "\(error)" }
    }

    // MARK: 持久化

    struct MatchRecord: Codable {
        var kind: MediaKind?
        var id: Int?
        var confident: Bool
        var manual: Bool
        var notVideo: Bool
        var at: Date
    }

    struct DetailRecord: Codable {
        var details: TMDBDetails
        var at: Date
    }

    struct DoubanRecord: Codable {
        /// nil = 豆瓣查不到
        var subject: DoubanSubject?
        var at: Date
    }

    struct Cache: Codable {
        var matches: [String: MatchRecord] = [:]
        var details: [String: DetailRecord] = [:]
        /// 键是 IMDb 编号
        var douban: [String: DoubanRecord] = [:]

        init(matches: [String: MatchRecord] = [:], details: [String: DetailRecord] = [:], douban: [String: DoubanRecord] = [:]) {
            self.matches = matches
            self.details = details
            self.douban = douban
        }

        /// 旧版本的缓存文件没有 douban，不能因此整个读不出来（里面有手动改正）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            matches = try c.decodeIfPresent([String: MatchRecord].self, forKey: .matches) ?? [:]
            details = try c.decodeIfPresent([String: DetailRecord].self, forKey: .details) ?? [:]
            douban = (try? c.decodeIfPresent([String: DoubanRecord].self, forKey: .douban)) ?? [:]
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            AppData.save(cache, as: "media-cache.json")
        }
    }
}
