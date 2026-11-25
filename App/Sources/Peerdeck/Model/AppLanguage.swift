import Foundation

/// 界面语言：跟随系统，或者固定成英文 / 简体中文。
/// 用的是系统自己的机制：在 app 的偏好域里写 AppleLanguages（mac「系统设置 › 语言与地区 › App」、
/// iOS「设置 › Peerdeck › 语言」改的也是它），所以重新启动后才生效，和系统设置里改的互相看得到。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 选项名：语言本身用自己的文字写，不翻译
    var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    private static let key = "AppleLanguages"

    /// 现在保存的选择。只看 app 自己的偏好域：UserDefaults.standard 读不到时会落到全局域，那就分不清是不是跟随系统了
    static var saved: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// 这次启动时用的选择，用来判断改了以后要不要重启。
    /// static let 是第一次用到时才求值，所以 app 启动时要读一次（见 PeerdeckApp / PeerdeckIOSApp 的 init）
    static let atLaunch = saved

    static func save(_ lang: AppLanguage) {
        if lang == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([lang.rawValue], forKey: key)
        }
        #if os(iOS)
        shareWithExtension(lang)
        #endif
    }

    #if os(iOS)
    /// 分享扩展有自己的偏好域，写一份到 App Group 让它照着用（见 ShareExtension/FollowAppLanguage.m）。
    /// app 每次启动也写一次：用户可能是在系统「设置 › Peerdeck › 语言」里改的
    static func shareWithExtension(_ lang: AppLanguage = atLaunch) {
        UserDefaults(suiteName: AppData.appGroup)?.set(lang.rawValue, forKey: "language")
    }
    #endif
}
