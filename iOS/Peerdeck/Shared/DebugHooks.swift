import SwiftUI
import TorrentKit

/// iOS 的调试开关（AppModel.load 里调用；mac 的在 App/Sources/Peerdeck/Support/Support.swift）。
/// 模拟器里用 `SIMCTL_CHILD_<名字>=<值> xcrun simctl launch …` 传进来：
///   TC_CONFIG_FILE=<json>        服务器配置从这个文件读写，不碰 Keychain
///   TC_DATA_DIR=<目录>            偏好、站点表、问题账本存这里
///   TC_DEBUG_SIDEBAR=<视图>       同 mac：all|active|rejected|unregistered|unreachable|state.<组>|server.<id>|site.<域名>|category.<名>|tag.<名>
///   TC_DEBUG_OPEN_FIRST=<秒>      打开列表第一个种子的详情；再加 TC_DEBUG_FILES=1 直接进文件列表
///   TC_DEBUG_IMPORT_TO_KEYCHAIN=<json>  启动时把这份配置写进 Keychain（验证共享组）
///   TC_LOG=1                     打日志（simctl launch --console 能看到）
///   TC_DEBUG_CLEANUP=<秒>         打开「清理未注册」确认（配合 TC_DEBUG_SIDEBAR=unregistered）
///   TC_DEBUG_ADD=<文本>           打开添加面板并填入文本（\n 分行）
///   TC_DEBUG_SCREEN=filters|settings|speed|setup|attention   打开对应的页面（attention = 总览里的「需要处理」）
@MainActor
enum DebugHooks {
    /// iOS 界面监听这个值，决定要不要打开某个页面（只在调试时用）
    static var screen: String? { ProcessInfo.processInfo.environment["TC_DEBUG_SCREEN"] }
    /// 启动时停在哪个标签（overview / torrents / sites / servers / search）
    static var tab: String? { ProcessInfo.processInfo.environment["TC_DEBUG_TAB"] }

    static func install(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let s = env["TC_DEBUG_SIDEBAR"] {
            let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
            switch (parts.first ?? "", parts.count > 1 ? parts[1] : nil) {
            case ("active", _): model.store.sidebar = .active
            case ("rejected", _): model.store.sidebar = .rejected
            case ("unregistered", _): model.store.sidebar = .unregistered
            case ("unreachable", _): model.store.sidebar = .unreachable
            case ("state", let g?): if let st = StateGroup(rawValue: g) { model.store.sidebar = .state(st) }
            case ("server", let id?): model.store.sidebar = .server(id)
            case ("site", let id?): model.store.sidebar = .site(id)
            case ("category", let n?): model.store.sidebar = .category(n)
            case ("tag", let n?): model.store.sidebar = .tag(n)
            default: break
            }
        }
        if let text = env["TC_DEBUG_ADD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.beginAdd(text: text.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        // 只开一个空的撤销窗口（不含任何种子），用来点测撤销附件条，不会真删东西
        if env["TC_DEBUG_UNDO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                model.scheduleDelete([], deleteDataFor: [], label: "debug", cleanup: true)
            }
        }
        if env["TC_DEBUG_SCREEN"] == "setup" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.sheet = .setup }
        }
    }
}
