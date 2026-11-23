import Foundation

/// 检查更新：查 GitHub 上最新的正式版（releases/latest 不含预发布），和当前版本比。只提示，不下载安装。
/// 仓库私有期间匿名请求是 404，会报「GitHub 上找不到发布的版本」。
enum UpdateCheck {
    static let repository = URL(string: "https://github.com/xheiop/Peerdeck")!
    static let releasesPage = URL(string: "https://github.com/xheiop/Peerdeck/releases/latest")!
    static let latestAPI = URL(string: "https://api.github.com/repos/xheiop/Peerdeck/releases/latest")!

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    /// 「0.1.0 (42)」；构建号为空或和版本号一样时只显示版本号
    static var versionLabel: String { build.isEmpty || build == version ? version : "\(version) (\(build))" }

    struct Release: Equatable, Sendable {
        var version: String
        var page: URL
    }

    enum Outcome: Equatable, Sendable, Identifiable {
        case upToDate(current: String)
        case available(Release, current: String)
        case failed(String)

        var id: String {
            switch self {
            case .upToDate: "upToDate"
            case .available(let r, _): "available-\(r.version)"
            case .failed(let s): "failed-\(s)"
            }
        }

        var title: String {
            switch self {
            case .upToDate: L("You’re Up to Date")
            case .available(let r, _): L("Peerdeck \(r.version) Is Available")
            case .failed: L("Couldn’t Check for Updates")
            }
        }

        /// homebrew：mac 上是不是用 Homebrew 装的，是的话提示用 brew 升级
        func message(homebrew: Bool = false) -> String {
            switch self {
            case .upToDate(let current):
                return L("Peerdeck \(current) is the latest version.")
            case .available(_, let current):
                #if os(iOS)
                return L("You have \(current). If you installed Peerdeck with AltStore or SideStore, update it there; otherwise download the new version from the release page.")
                #else
                return homebrew
                    ? L("You have \(current). Update with Homebrew: brew upgrade --cask peerdeck")
                    : L("You have \(current). Download the new version from the release page.")
                #endif
            case .failed(let reason):
                return reason
            }
        }
    }

    /// a 比 b 新：x.y.z 逐段比数字，后缀（-beta.1）不看，缺的段当 0
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let base = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            return base.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 解析 GitHub API 的回应（拆出来方便测试）
    static func outcome(data: Data, status: Int, current: String) -> Outcome {
        guard status == 200 else {
            return .failed(status == 404 ? L("Couldn’t find a published release on GitHub.") : L("GitHub returned HTTP \(status)."))
        }
        struct Latest: Decodable {
            let tag_name: String
            let html_url: String?
        }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: data) else {
            return .failed(L("Couldn’t read the reply from GitHub."))
        }
        let tag = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        // 只打开本仓库在 github.com 上的页面
        var page = releasesPage
        if let s = latest.html_url, let u = URL(string: s), u.scheme == "https", u.host() == "github.com",
           u.path().hasPrefix("/xheiop/Peerdeck/") {
            page = u
        }
        return isNewer(tag, than: current) ? .available(Release(version: tag, page: page), current: current) : .upToDate(current: current)
    }

    /// 联网检查。TC_DEBUG_UPDATE_JSON=<文件> 时读这个文件当作回应，不联网（自动化验证用）
    static func check(current: String = version) async -> Outcome {
        if let path = ProcessInfo.processInfo.environment["TC_DEBUG_UPDATE_JSON"] {
            guard let data = FileManager.default.contents(atPath: path) else { return .failed("TC_DEBUG_UPDATE_JSON: \(path)") }
            return outcome(data: data, status: 200, current: current)
        }
        var request = URLRequest(url: latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Peerdeck/\(version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return outcome(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, current: current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    #if os(macOS)
    /// 用 Homebrew 装的：cask 的目录在
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/peerdeck", "/usr/local/Caskroom/peerdeck"].contains { FileManager.default.fileExists(atPath: $0) }
    }
    #endif
}

#if os(macOS)
extension AppModel {
    /// 手动检查总会弹出结果；自动检查只在有新版本、而且这个版本还没提醒过时弹
    func checkForUpdates(manual: Bool) {
        Task {
            let outcome = await UpdateCheck.check()
            prefs.lastUpdateCheck = .now
            if case .available(let r, _) = outcome {
                guard manual || prefs.notifiedVersion != r.version else { return }
                prefs.notifiedVersion = r.version
                updateNotice = outcome
            } else if manual {
                updateNotice = outcome
            }
        }
    }

    /// 开着自动检查、离上次检查超过一天才查。用开发配置（TC_CONFIG_FILE）跑的时候不联网，除非给了 TC_DEBUG_UPDATE_JSON
    func checkForUpdatesIfDue() {
        let env = ProcessInfo.processInfo.environment
        guard prefs.autoCheckUpdates, env["TC_CONFIG_FILE"] == nil || env["TC_DEBUG_UPDATE_JSON"] != nil else { return }
        if let last = prefs.lastUpdateCheck, Date.now.timeIntervalSince(last) < 24 * 3600 { return }
        checkForUpdates(manual: false)
    }
}
#endif
