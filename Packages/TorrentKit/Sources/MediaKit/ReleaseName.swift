import Foundation

/// 从种子名（或文件名）里认出片名、年份、季集。
///
/// 规则移植自 MoviePilot（https://github.com/jxxghp/MoviePilot，GPL-3.0）的 app/domain/meta/metavideo.py、metabase.py 和 metainfo.py：
/// 按分隔符切成词，逐个判断是片名、年份、分辨率、季、集还是片源，遇到第一个技术词就不再往片名里加。
/// 只移植了查 TMDB 用得到的部分（片名、年份、季集、类型）。动漫（[字幕组] 片名 - 12 这类）MoviePilot 用 anitopy 解析，
/// 这里是简化的规则。测试样例也来自 MoviePilot 的 tests/cases/meta.py。
public struct ReleaseName: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case movie, tv, unknown }

    public var cnTitle: String?
    public var enTitle: String?
    public var year: Int?
    public var kind: Kind = .unknown
    public var seasons: ClosedRange<Int>?
    public var episodes: ClosedRange<Int>?
    /// 名字里显式写了 [tmdbid=123] / {tmdb-123}
    public var tmdbID: Int?
    /// 出现过分辨率、片源、编码、季集之类的技术词。没有这些又没有年份的，多半不是影视（软件、音乐、电子书）
    public var hasMediaMarkers = false

    /// 查 TMDB 用的候选片名：英文名在前（发布组写的英文名基本就是官方名），中文名在后
    public var titles: [String] {
        var out: [String] = []
        for t in [enTitle, cnTitle] { if let t, !t.isEmpty, !out.contains(t) { out.append(t) } }
        return out
    }

    /// 看起来是影视：有片名，并且有年份、明确的季集写法或者技术词之一。
    /// 只靠裸数字猜出来的集数不算（ubuntu-24.04 里的 04 会被当成集数）
    public var looksLikeVideo: Bool {
        !titles.isEmpty && (year != nil || hasMediaMarkers || tmdbID != nil)
    }

    public var season: Int? { seasons?.lowerBound }

    public init() {}

    /// hints：分类、保存路径之类，用来判断是电影还是剧集，以及排除音乐、游戏
    public static func parse(_ raw: String, hints: [String] = []) -> ReleaseName {
        var parser = Parser(raw)
        var r = parser.parse()
        let hint = hints.joined(separator: " ").lowercased()
        if r.kind == .unknown {
            if Rx(#"(^|[/\s_-])(tv|tvs|series|shows?|剧集|电视剧|连续剧|番剧|动漫|动画)($|[/\s_-])"#).matches(hint) { r.kind = .tv }
            else if Rx(#"(^|[/\s_-])(movies?|films?|电影)($|[/\s_-])"#).matches(hint) { r.kind = .movie }
        }
        if Rx(#"(^|[/\s_-])(music|audio|音乐|games?|游戏|software|软件|apps?|e-?books?|电子书|书籍|comics?|漫画)($|[/\s_-])"#).matches(hint) {
            r.hasMediaMarkers = false
            r.year = nil
            r.kind = .unknown
        }
        return r
    }
}

// MARK: - 解析器

private let mediaExtensions: Set<String> = ["mkv", "mp4", "avi", "ts", "m2ts", "iso", "rmvb", "wmv", "mov", "flv", "webm", "mpg", "mpeg", "vob", "strm"]

private struct Parser {
    enum TokenKind { case enName, cnName, nameSeasonWord, part, year, pix, season, seasonMarker, episode, episodeMarker, source, effect, videoEncode, audioEncode }

    // 和 MoviePilot MetaVideo 同名的正则
    static let seasonRe = Rx(#"S(\d{3})|^S(\d{1,3})$|S(\d{1,3})E"#)
    static let episodeRe = Rx(#"EP?(\d{2,4})$|^EP?(\d{1,4})$|^S\d{1,2}EP?(\d{1,4})$|S\d{2}EP?(\d{2,4})"#)
    static let partRe = Rx(#"(^PART[0-9ABI]{0,2}$|^CD[0-9]{0,2}$|^DVD[0-9]{0,2}$|^DISK[0-9]{0,2}$|^DISC[0-9]{0,2}$)"#)
    static let romanRe = Rx(#"^(?=[MDCLXVI])M*(C[MD]|D?C{0,3})(X[CL]|L?X{0,3})(I[XV]|V?I{0,3})$"#, caseSensitive: true)
    static let sourceRe = Rx(#"^BLURAY$|^HDTV$|^UHDTV$|^HDDVD$|^WEBRIP$|^DVDRIP$|^BDRIP$|^BLU$|^WEB$|^BD$|^HDRip$|^REMUX$|^UHD$|^WEBDL$"#)
    static let effectRe = Rx(#"^SDR$|^HDR\d*$|^HDRVIVID$|^DOLBY$|^DOVI$|^DV$|^3D$|^REPACK$|^HLG$|^HDR10(\+|Plus)$|^HDR10P$|^VIVID$|^EDR$|^HQ$"#)
    static let pixRe = Rx(#"^[SBUHD]*(\d{3,4}[PI]+)|\d{3,4}X(\d{3,4})"#)
    static let pixRe2 = Rx(#"(^[248]+K)"#)
    static let videoEncodeRe = Rx(#"^(H26[45])$|^(x26[45])$|^AVC$|^HEVC$|^VC\d?$|^MPEG\d?$|^Xvid$|^DivX$|^AV1$|^HDR\d*$|^AVS(\+|[23])$"#)
    static let audioEncodeRe = Rx(#"^DTS\d?$|^DTSHD$|^DTSHDMA$|^Atmos$|^TrueHD\d?$|^AC3$|^EAC3\d?$|^\dAudios?$|^DDP\d?$|^DD\+\d?$|^DD\d?$|^LPCM\d?$|^AAC\d?$|^FLAC\d?$|^HD\d?$|^MA\d?$|^HR\d?$|^Opus\d?$|^Vorbis\d?$|^AV[3S]A$"#)
    static let nameNoChineseRe = Rx(#".*版|.*字幕"#)
    static let movieWordsRe = Rx(#"剧场版|劇場版|电影版|電影版"#)
    static let nameSeWords: Set<String> = ["共", "第", "季", "集", "话", "話", "期"]
    static let nostringRe = Rx(
        #"^PTS|^JADE|^AOD|^CHC|^[A-Z]{1,4}TV[\-0-9UVHDK]*"#
        + #"|\d{1,2}th|\d{1,2}bit|IMAX|^3D|\s+3D|\s+DC$"#
        + #"|[第\s共]+[0-9一二三四五六七八九十\-\s]+季"#
        + #"|[第\s共]+[0-9一二三四五六七八九十百零\-\s]+[集话話]"#
        + #"|连载|日剧|美剧|电视剧|动画片|动漫|欧美|西德|日韩|超高清|高清|无水印|下载|蓝光|翡翠台|梦幻天堂·龙网|★?\d*月?新番★?"#
        + #"|最终季|合集|[多中国英葡法俄日韩德意西印泰台港粤双文语简繁体特效内封官译外挂]+字幕|版本|出品|台版|港版|\w+字幕组|\w+字幕社"#
        + #"|未删减版|UNCUT$|UNRATE$|WITH EXTRAS$|RERIP$|SUBBED$|PROPER$|REPACK$|SEASON$|EPISODE$|Complete$|Extended$|Extended Version$"#
        + #"|S\d{2}\s*-\s*S\d{2}|S\d{2}|\s+S\d{1,2}|EP?\d{2,4}\s*-\s*EP?\d{2,4}|EP?\d{2,4}|\s+EP?\d{1,4}"#
        + #"|CD[\s.]*[1-9]|DVD[\s.]*[1-9]|DISK[\s.]*[1-9]|DISC[\s.]*[1-9]"#
        + #"|[248]K|\d{3,4}[PIX]+|\s+GB"#)

    // 预处理（metavideo.py 开头和 metainfo.py）
    static let explicitTMDB = Rx(#"[\[{]tmdb(?:id)?[=\-](\d+)[\]}]"#)
    static let seasonFull = Rx(#"^(?:Season\s+|S)(\d{1,3})(?:\s*\(\d{4}\))?$"#)
    static let firstBracket = Rx(#"^[\[【](.+?)[\]】]"#)
    static let bracketDotTitle = Rx(#"[A-Za-z]+\..+(?:19|20)\d{2}"#)
    static let bracketResource = Rx(#"(?:2160|1080|720|480)[PIpi]|4K|UHD|Blu[\-.]?ray|REMUX|WEB[\-.]?DL|HDTV"#)
    static let yearRange = Rx(#"([\s.]+)(\d{4})-(\d{4})"#)
    static let fileSize = Rx(#"[0-9.]+\s*[MGT]i?B(?![A-Z]+)"#)
    static let date = Rx(#"\d{4}[\s._-]\d{1,2}[\s._-]\d{1,2}"#)
    static let crc32 = Rx(#"\[([0-9A-Fa-f]{8})\]|\(([0-9A-Fa-f]{8})\)|【([0-9A-Fa-f]{8})】"#)
    static let separators = Rx(#"\.|\s+|\(|\)|\[|]|-|【|】|/|～|;|&|\||#|_|「|」|~"#)

    // 中文季集（metabase.py 的 init_subtitle）
    static let cnSeason = Rx(#"[第\s]+([0-9一二三四五六七八九十]+)\s*季"#)
    static let cnSeasonAll = Rx(#"[全共]\s*([0-9一二三四五六七八九十]+)\s*季"#)
    static let cnEpisode = Rx(#"[第\s]+([0-9一二三四五六七八九十百零]+)\s*[集话話期]"#)
    static let cnEpisodeRange = Rx(#"第?\s*([0-9一二三四五六七八九十百零]+)\s*[集话話期]?\s*-\s*第?\s*([0-9一二三四五六七八九十百零]+)\s*[集话話期]"#)
    static let titleEpisode = Rx(#"Episode\s+(\d{1,4})"#)

    // 动漫（metainfo.py 的 is_anime）
    static let animeBracket = Rx(#"【(?!\d+[PI]】)[+0-9XVPI-]+】\s*【"#)
    static let animeDash = Rx(#"\s+-\s+[\dv]{1,4}\s+"#)
    static let videoSeasonEpisode = Rx(#"S\d{2}\s*-\s*S\d{2}|S\d{2}|\s+S\d{1,2}|EP?\d{2,4}\s*-\s*EP?\d{2,4}|EP?\d{2,4}|\s+EP?\d{1,4}"#)
    static let animeSquare = Rx(#"\[(?!\d+[PI]])[+0-9XVPI-]+]\s*\["#)

    let original: String
    var title: String
    var isFile = false
    var anime = false
    var r = ReleaseName()

    // 逐词解析的状态（metavideo.py 的 _VideoParseState）
    var tokens: [String] = []
    var index = 0
    var lastKind: TokenKind?
    var lastToken = ""
    var stopName = false
    var stopCnName = false
    var pendingName = ""
    var bareDigitEpisode = false
    var pix: String?
    var sawSource = false

    init(_ raw: String) {
        original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = original
    }

    var name: String { (r.cnTitle?.isEmpty == false ? r.cnTitle : r.enTitle) ?? "" }

    mutating func parse() -> ReleaseName {
        if let g = Self.explicitTMDB.firstCapture(title), let id = Int(g) {
            r.tmdbID = id
            title = Self.explicitTMDB.replacing(title, with: "").trimmingCharacters(in: .whitespaces)
        }
        // 文件扩展名
        if let dot = title.lastIndex(of: "."), mediaExtensions.contains(title[title.index(after: dot)...].lowercased()) {
            isFile = true
            title = String(title[..<dot])
        }
        anime = Self.isAnime(title)
        if anime {
            parseAnime()
        } else {
            parseVideo()
        }
        applyChineseSeasonEpisode(original)
        // 动漫的片名是从括号里整段取的，不用再去干扰词（干扰词表里的 ^JADE 会把 Jade Dynasty 切掉）
        if !anime {
            r.cnTitle = fixName(r.cnTitle)
            r.enTitle = fixName(r.enTitle)
        } else {
            r.cnTitle = r.cnTitle.map { Rx(#"\s+"#).replacing($0, with: " ").trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            r.enTitle = r.enTitle.map { Rx(#"\s+"#).replacing($0, with: " ").trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if r.seasons != nil || r.episodes != nil { r.kind = .tv }
        if r.kind == .tv, r.seasons == nil { r.seasons = 1...1 }
        return r
    }

    static func isAnime(_ name: String) -> Bool {
        if animeBracket.matches(name) || animeDash.matches(name + " ") { return true }
        if videoSeasonEpisode.matches(name) { return false }
        return animeSquare.matches(name)
    }

    // MARK: 普通影视（metavideo.py）

    mutating func parseVideo() {
        if let s = Self.seasonFull.firstCapture(title), let n = Int(s) {
            r.kind = .tv
            r.seasons = n...n
            return
        }
        if let g = Self.firstBracket.firstGroups(title), let whole = g[0], let content = g[1] {
            // 第一个括号里是点分隔的英文发布名（带年份和片源）时只去掉括号，否则整个去掉（多半是发布组或站点）
            let rest = String(title.dropFirst(whole.count))
            title = Self.bracketDotTitle.matches(content) && Self.bracketResource.matches(content) ? content + rest : rest
        }
        title = Self.yearRange.replacing(title, with: "$1$2")
        title = Self.fileSize.replacing(title, with: "")
        title = Self.date.replacing(title, with: "")
        title = stripCRC32(title)
        tokens = Self.split(title)
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            parseToken(token)
        }
    }

    static func split(_ s: String) -> [String] {
        let marked = separators.replacing(s, with: "\u{1F}")
        return marked.split(separator: "\u{1F}").map(String.init).filter { !$0.isEmpty }
    }

    func stripCRC32(_ s: String) -> String {
        var out = s
        for g in Self.crc32.allGroups(s) {
            guard let whole = g[0], let sum = g.dropFirst().compactMap({ $0 }).first else { continue }
            if sum.contains(where: \.isNumber), sum.contains(where: \.isLetter) { out = out.replacingOccurrences(of: whole, with: "") }
        }
        return out
    }

    var nextToken: String? { index < tokens.count ? tokens[index] : nil }
    var prevToken: String? { index - 2 >= 0 ? tokens[index - 2] : nil }

    mutating func parseToken(_ token: String) {
        if token.count == 8, token.allSatisfy(\.isHexDigit), token.contains(where: \.isNumber), token.contains(where: \.isLetter) {
            stopName = true
            return
        }
        if initPart(token) { return }
        if initName(token) { return }
        if initYear(token) { return }
        if initPix(token) { return }
        if initSeason(token) { return }
        if initEpisode(token) { return }
        if initResourceType(token) { return }
        if initVideoEncode(token) { return }
        if Self.audioEncodeRe.matches(token) {
            stopName = true
            r.hasMediaMarkers = true
            lastKind = .audioEncode
        }
    }

    mutating func initName(_ token: String) -> Bool {
        if !pendingName.isEmpty {
            if r.cnTitle?.isEmpty ?? true {
                if r.enTitle?.isEmpty ?? true { r.enTitle = pendingName }
                else if pendingName != r.year.map(String.init) { r.enTitle! += " " + pendingName }
                lastKind = .enName
            }
            pendingName = ""
        }
        if stopName { return false }
        if token.uppercased() == "AKA" { stopName = true; return true }
        if Self.nameSeWords.contains(token) { lastKind = .nameSeasonWord; return false }
        if token.containsCJK {
            // 中文直接当片名（连着的数字、英文保留），后面再出现的中文只再接一段
            lastKind = .cnName
            if r.cnTitle?.isEmpty ?? true {
                r.cnTitle = token
            } else if !stopCnName {
                if Self.movieWordsRe.matches(token) || (!Self.nameNoChineseRe.matches(token) && !Self.nameSeWords.contains(where: { token.contains($0) })) {
                    r.cnTitle! += " " + token
                }
                stopCnName = true
            }
            return false
        }
        let isRoman = Self.romanRe.matches(token)
        if token.isAllDigits || isRoman {
            if lastKind == .nameSeasonWord { return false }
            if !name.isEmpty {
                // 片名后面以 0 开头的一般是集数，片名结尾单独一个 0 是续作编号（Steins;Gate 0）
                if token.hasPrefix("0"), !isZeroTitleToken(token) { return false }
                if !isRoman, lastKind == .cnName, let n = Int(token), n < 1900 { return false }
                if (token.isAllDigits && token.count < 4) || isRoman {
                    if lastKind == .cnName { r.cnTitle! += " " + token }
                    else if lastKind == .enName { r.enTitle! += " " + token }
                    return true
                } else if token.isAllDigits, token.count == 4, pendingName.isEmpty {
                    pendingName = token
                }
            } else if pendingName.isEmpty {
                pendingName = token
            }
        } else if Self.seasonRe.matches(token) {
            if let en = r.enTitle, en.uppercased().hasSuffix("SEASON") { r.enTitle = en + " " }
            stopName = true
            return false
        } else if Self.episodeRe.matches(token) || Self.sourceRe.matches(token) || Self.effectRe.matches(token) || Self.pixRe.matches(token) {
            stopName = true
            return false
        } else {
            if isFile, mediaExtensions.contains(token.lowercased()), original.lowercased().hasSuffix("." + token.lowercased()) { return false }
            r.enTitle = (r.enTitle?.isEmpty ?? true) ? token : r.enTitle! + " " + token
            lastKind = .enName
        }
        return false
    }

    func isZeroTitleToken(_ token: String) -> Bool {
        guard token == "0", let prev = prevToken, !prev.isAllDigits, let next = nextToken else { return false }
        if next.isAllDigits, next.count == 4 { return true }
        return Self.seasonRe.matches(next) || Self.episodeRe.matches(next)
    }

    mutating func initPart(_ token: String) -> Bool {
        guard !name.isEmpty, r.year != nil || r.seasons != nil || r.episodes != nil || pix != nil || sawSource else { return false }
        guard Self.partRe.matches(token) else { return false }
        if let next = nextToken, (next.isAllDigits && (next.count == 1 || (next.count == 2 && next.hasPrefix("0")))) || ["A", "B", "C", "I", "II", "III"].contains(next.uppercased()) {
            index += 1
        }
        lastKind = .part
        return true
    }

    mutating func initYear(_ token: String) -> Bool {
        guard !name.isEmpty, token.isAllDigits, token.count == 4, let y = Int(token), y > 1900, y < 2050 else { return false }
        if let old = r.year {
            // 两个年份：前一个其实是片名的一部分（Wonder Woman 1984 2020）
            if let en = r.enTitle, !en.isEmpty { r.enTitle = en.trimmingCharacters(in: .whitespaces) + " \(old)" }
            else if let cn = r.cnTitle, !cn.isEmpty { r.cnTitle = cn + " \(old)" }
        } else if let en = r.enTitle, en.uppercased().hasSuffix("SEASON") {
            r.enTitle = en + " "
        }
        r.year = y
        lastKind = .year
        stopName = true
        return true
    }

    mutating func initPix(_ token: String) -> Bool {
        guard !name.isEmpty else { return false }
        if Self.pixRe.matches(token) || Self.pixRe2.matches(token) {
            lastKind = .pix
            stopName = true
            pix = pix ?? token
            r.hasMediaMarkers = true
            return true
        }
        return false
    }

    mutating func initSeason(_ token: String) -> Bool {
        let found = Self.seasonRe.allGroups(token).compactMap { g in g.dropFirst().compactMap { $0 }.first.flatMap { Int($0) } }
        if !found.isEmpty {
            lastKind = .season
            r.kind = .tv
            r.hasMediaMarkers = true
            stopName = true
            for se in found {
                if let s = r.seasons {
                    if se > s.lowerBound { r.seasons = s.lowerBound...se }
                } else {
                    r.seasons = se...se
                }
            }
            return false
        }
        if token.isAllDigits {
            if lastKind == .seasonMarker, r.seasons == nil, token.count < 3, let n = Int(token) {
                r.seasons = n...n
                r.hasMediaMarkers = true
                lastKind = .season
                stopName = true
                r.kind = .tv
                return true
            }
        } else if token.uppercased() == "SEASON", r.seasons == nil {
            lastKind = .seasonMarker
        }
        return false
    }

    mutating func initEpisode(_ token: String) -> Bool {
        let found = Self.episodeRe.allGroups(token).compactMap { g in g.dropFirst().compactMap { $0 }.first.flatMap { Int($0) } }
        if !found.isEmpty {
            lastKind = .episode
            stopName = true
            r.kind = .tv
            r.hasMediaMarkers = true
            // 显式的 SxxEyy / Exx 覆盖之前按裸数字猜的集数
            if bareDigitEpisode { r.episodes = nil; bareDigitEpisode = false }
            for e in found {
                if let ep = r.episodes {
                    if e > ep.lowerBound { r.episodes = ep.lowerBound...e }
                } else {
                    r.episodes = e...e
                }
            }
            return true
        }
        guard token.isAllDigits, let n = Int(token) else {
            if token.uppercased() == "EPISODE" { lastKind = .episodeMarker }
            return false
        }
        if let ep = r.episodes, ep.count == 1, token.count < 5, n > ep.lowerBound, lastKind == .episode {
            r.episodes = ep.lowerBound...n
            r.kind = .tv
            return true
        }
        if r.episodes == nil, token.count > 1, token.count < 4, lastKind != .year, lastKind != .videoEncode, token != pendingName {
            r.episodes = n...n
            bareDigitEpisode = true
            lastKind = .episode
            stopName = true
            r.kind = .tv
            return true
        }
        if lastKind == .episodeMarker, r.episodes == nil, token.count < 5 {
            r.episodes = n...n
            r.hasMediaMarkers = true
            lastKind = .episode
            stopName = true
            r.kind = .tv
            return true
        }
        return false
    }

    mutating func initResourceType(_ token: String) -> Bool {
        guard !name.isEmpty else { return false }
        let up = token.uppercased()
        if (up == "DL" && lastKind == .source && lastToken == "WEB") || (up == "RAY" && lastKind == .source && lastToken == "BLU") { return true }
        if Self.sourceRe.matches(token) {
            stopName = true
            sawSource = true
            r.hasMediaMarkers = true
            lastKind = .source
            lastToken = up
            return true
        }
        if Self.effectRe.matches(token) {
            stopName = true
            r.hasMediaMarkers = true
            lastKind = .effect
            lastToken = up
            return true
        }
        return false
    }

    mutating func initVideoEncode(_ token: String) -> Bool {
        guard !name.isEmpty else { return false }
        // H.265 / x 264 会被切成两个词
        if ["H", "X"].contains(token.uppercased()), let next = nextToken, ["264", "265"].contains(next) {
            index += 1
            lastKind = .videoEncode
            stopName = true
            r.hasMediaMarkers = true
            return true
        }
        if Self.videoEncodeRe.matches(token) {
            lastKind = .videoEncode
            stopName = true
            r.hasMediaMarkers = true
            return true
        }
        return false
    }

    // MARK: 动漫（简化版）

    static let animeNoise = Rx(#"^(\d{3,4}[PI]\+?|\d{3,4}x\d{3,4}|[248]K|WEB-?DL|WEBRip|BDRip|BD|BluRay|HEVC.*|AVC.*|x26[45].*|H\.?26[45].*|AAC.*|FLAC.*|EAC3.*|MP4|MKV|GB|BIG5|CHS|CHT|简.*|繁.*|.*字幕.*|.*内[封嵌].*|.*新番.*|.*月番.*|招募.*|.*发布组|.*字幕组|.*字幕社|Baha|B-Global|CR|ANi|NC-Raws|LoliHouse|Fin|ENG.*|TV Series|\d{2,4}年.*|国漫|日漫|美漫|国创|动画|动漫|日剧|Animations.*|LeagueWEB|.*中字.*|.*双语.*|\d+(\.\d+)?\s*[MG]i?B)$"#)
    static let animeEpisode = Rx(#"^(?:第|TV\s*)?(\d{1,3})(?:v\d)?(?:[话話集])?$"#)
    static let animeEpisodeRange = Rx(#"^(?:TV\s*)?(\d{1,3})\s*-\s*(\d{1,3})(?:\s*Fin)?$"#)
    static let animeYear = Rx(#"^((?:19|20)\d{2})$"#)
    static let animeGroup = Rx(#"字幕|发布|[组組社]|Raws|Sub|Team|[-&]"#)
    static let animeDashEpisode = Rx(#"\s+-\s+(\d{1,4})(?:v\d)?(?:\s|$)"#)
    static let animeSeasonInTitle = Rx(#"\s*(?:第\s*([0-9一二三四五六七八九十]+)\s*季|\bS(\d{1,2})\b|\bSeason\s*(\d{1,2})\b)\s*"#)
    static let animeLeading = Rx(#"^(?:\s*[\[【][^\]】]*[\]】])+"#)
    static let animeBrackets = Rx(#"[\[【]+([^\[\]【】]*)[\]】]"#)

    mutating func parseAnime() {
        r.kind = .tv
        r.hasMediaMarkers = true
        let text = title
        var titleParts: [String] = []
        // 「片名 - 12 [1080p]」：片名在开头的括号之后、「 - 集数」之前
        if let g = Self.animeDashEpisode.firstGroups(text + " "), let ep = g[1].flatMap({ Int($0) }), let range = Self.animeDashEpisode.firstMatchRange(text + " ") {
            r.episodes = ep...ep
            let head = String((text + " ")[..<range.lowerBound])
            let stripped = Self.animeLeading.replacing(head, with: "").trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { titleParts = [stripped] }
        }
        // 方括号里的年份、集数
        let brackets = Self.animeBrackets.allGroups(text).compactMap { $0[1]?.trimmingCharacters(in: .whitespaces) }
        for b in brackets {
            if r.year == nil, let y = Self.animeYear.firstCapture(b) { r.year = Int(y); continue }
            if r.episodes == nil, let g = Self.animeEpisodeRange.firstGroups(b), let a = g[1].flatMap({ Int($0) }), let z = g[2].flatMap({ Int($0) }), z > a { r.episodes = a...z; continue }
            if r.episodes == nil, let e = Self.animeEpisode.firstCapture(b), let n = Int(e) { r.episodes = n...n }
        }
        if titleParts.isEmpty {
            // 第一个括号像字幕组（或者括号外还有文字）时跳过它，否则它就是片名（[诛仙][Jade Dynasty][2022]…）
            let outside = Rx(#"[\[【][^\]】]*[\]】]"#).replacing(text, with: "\u{1F}").split(separator: "\u{1F}")
                .map { $0.split(separator: "|").first.map(String.init) ?? "" }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !Self.animeNoise.matches($0) && Self.animeEpisode.firstCapture($0) == nil }
            // 字幕组：名字里带「字幕 / 组 / Raws / Team」之类，或者是一个不含空格的英文词（[xyx98]、[ANi]）
            let firstIsGroup = brackets.first.map { Self.animeGroup.matches($0) || (!$0.containsCJK && !$0.contains(" ")) } ?? false
            let startsWithBracket = text.trimmingCharacters(in: .whitespaces).first.map { "[【".contains($0) } ?? false
            if startsWithBracket && !firstIsGroup {
                titleParts = brackets
            } else if let o = outside.first {
                titleParts = [o]
            } else {
                titleParts = Array(brackets.dropFirst())
            }
            let useful: (String) -> Bool = { !$0.isEmpty && !Self.animeNoise.matches($0) && Self.animeEpisode.firstCapture($0) == nil && Self.animeYear.firstCapture($0) == nil && Self.animeEpisodeRange.firstCapture($0) == nil }
            let filtered = titleParts.filter(useful)
            // 单个英文词的片名（[Bocchi][01]）会被当成字幕组跳过，这时退回用第一个括号
            titleParts = filtered.isEmpty ? brackets.filter(useful) : filtered
        }
        for var t in titleParts {
            t = Self.nostringPrefix.replacing(t, with: "")
            if r.seasons == nil, let g = Self.animeSeasonInTitle.firstGroups(t), let s = g.dropFirst().compactMap({ $0 }).first, let n = chineseNumber(s) {
                r.seasons = n...n
            }
            t = Self.animeSeasonInTitle.replacing(t, with: " ")
            // 「中文名 / English Name」，或者「中文名 English Name」
            for part in t.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                let (cn, en) = Self.splitMixed(part)
                if r.cnTitle == nil, let cn { r.cnTitle = cn }
                if r.enTitle == nil, let en { r.enTitle = en }
            }
            if r.cnTitle != nil && r.enTitle != nil { break }
        }
    }

    /// 「不死者之王 OVERLORD Ⅳ」拆成中文名和英文名：开头连续含汉字的词算中文名，剩下的算英文名
    static func splitMixed(_ s: String) -> (String?, String?) {
        let words = s.split(separator: " ").map(String.init)
        guard let firstLatin = words.firstIndex(where: { !$0.containsCJK }) else { return (s, nil) }
        if firstLatin == 0 { return (nil, s.containsCJK ? nil : s) }
        let cn = words[..<firstLatin].joined(separator: " ")
        let rest = words[firstLatin...]
        let en = rest.contains(where: \.containsCJK) ? nil : rest.joined(separator: " ")
        return (cn, en?.isEmpty == false && en!.contains(where: \.isLetter) ? en : nil)
    }

    static let nostringPrefix = Rx(#"★?\d*月?新番★?"#)

    // MARK: 中文季集、收尾

    mutating func applyChineseSeasonEpisode(_ text: String) {
        let t = " \(text) "
        if r.episodes == nil, let e = Self.titleEpisode.firstCapture(t), let n = Int(e) {
            r.episodes = n...n
            r.hasMediaMarkers = true
        }
        let before = (r.seasons, r.episodes)
        defer { if before.0 != r.seasons || before.1 != r.episodes { r.hasMediaMarkers = true } }
        if r.seasons == nil {
            if let s = Self.cnSeasonAll.firstCapture(t), let n = chineseNumber(s), n > 0, n < 100 {
                r.seasons = 1...n
            } else if let s = Self.cnSeason.firstCapture(t), let n = chineseNumber(s), n > 0, n < 100 {
                r.seasons = n...n
            }
        }
        if r.episodes == nil {
            if let g = Self.cnEpisodeRange.firstGroups(t), let a = g[1].flatMap(chineseNumber), let b = g[2].flatMap(chineseNumber), b > a {
                r.episodes = a...b
            } else if let e = Self.cnEpisode.firstCapture(t), let n = chineseNumber(e), n < 10000 {
                r.episodes = n...n
            }
        }
    }

    /// 去掉片名里的干扰词；剩下过短的纯数字时当作集数
    mutating func fixName(_ name: String?) -> String? {
        guard var n = name else { return nil }
        n = Self.nostringRe.replacing(n, with: "").trimmingCharacters(in: .whitespaces)
        n = Rx(#"\s+"#).replacing(n, with: " ")
        if n.isAllDigits, let v = Int(n), v < 1800, r.year == nil, r.seasons == nil, pix == nil, !sawSource {
            if r.episodes == nil { r.episodes = v...v; return nil }
        }
        return n.isEmpty ? nil : n
    }
}
