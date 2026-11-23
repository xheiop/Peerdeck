import AppKit
import Foundation
import SwiftUI
import TorrentKit

/// 调试钩子：设置 TC_SNAPSHOT=/path/prefix 时，按 TC_SNAPSHOT_AT（秒，逗号分隔，默认 8）把所有窗口画成 PNG，
/// 不需要屏幕录制权限。TC_SNAPSHOT_EXIT=1 时截完退出。用于自动化验证 UI。
/// 本地化：中文原文就是键（开发语言 zh-Hans），译文在 Resources/Localizable.xcstrings。
/// 用 String.LocalizationValue 当参数，编译器提取字符串时能认出来
@MainActor
enum DebugSnapshot {
    static func scheduleIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["TC_SNAPSHOT"] else { return }
        let times = (env["TC_SNAPSHOT_AT"] ?? "8").split(separator: ",").compactMap { Double($0) }
        for (i, t) in times.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                for (j, window) in NSApp.windows.enumerated() where window.isVisible && window.contentView != nil {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let path = "\(prefix)-\(i)-\(j).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("[Peerdeck] snapshot \(path) \(window.title)")
                }
                fflush(stdout)
                // 有弹窗时 terminate 会被拦下，调试模式直接退出
                if i == times.count - 1, env["TC_SNAPSHOT_EXIT"] == "1" { exit(0) }
            }
        }
    }
}

@MainActor
private var debugPanels: [NSPanel] = []

/// 自动化验证用的调试开关（只看环境变量，正常启动不会触发）：
///   TC_DEBUG_SIDEBAR=all|active|rejected|unregistered|unreachable|state.<组>|server.<id>|site.<域名>|category.<名>|tag.<名>
///   TC_DEBUG_SELECT_FIRST=<秒> / TC_DEBUG_SELECT_ALL=<秒>   选中第一行 / 全选（检查详情和多选操作条）
///   TC_DEBUG_INSPECTOR=1        打开详情面板
///   TC_DEBUG_FILES=1            详情面板里默认展开文件列表
///   TC_DEBUG_AUTOTRUST=<秒>      信任所有待确认的证书
///   TC_DEBUG_ADD=<文本>          打开添加面板并填入文本（\n 分行）
///   TC_DEBUG_CLEANUP=<秒>        打开「清理未注册」面板
///   TC_DEBUG_RETRACKER=<秒>      对当前站点打开「替换 tracker」面板
///   TC_DEBUG_SETTINGS=<标签>     打开设置窗口（servers|general|notify|sites），TC_DEBUG_SETTINGS_SERVER=<id> 选中服务器
///   TC_DEBUG_BACKUP=export       设置里「备份」一节出现时打开导出选项（配合 TC_DEBUG_SETTINGS=general）
///   TC_DEBUG_ABOUT=1             2 秒后打开「关于 Peerdeck」面板
///   TC_DEBUG_UPDATE_JSON=<文件>   检查更新时读这个文件当作 GitHub 的回应，不联网；开发配置（TC_CONFIG_FILE）下只有给了它才会自动检查
///   TC_DEBUG_LIMITS=1            3 秒后打开工具栏「限速」弹窗
///   TC_DEBUG_MENU=1              把菜单栏弹出面板放进一个普通窗口（截图用）
///   TC_DEBUG_SETUP=1             打开「添加服务器」面板
///   TC_DEBUG_RETRACKER_SEL=a=>b、TC_DEBUG_RETRACKER_AT=<秒>  对当前视图前 5 行把 tracker 地址里的 a 换成 b，3 秒后撤销
///   TC_DEBUG_APPEARANCE=dark|light  强制深色 / 浅色
///   TC_HITCH=1                   每 5 秒打印一次主线程最大卡顿
@MainActor
enum DebugHooks {
    static func install(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        func after(_ key: String, _ body: @escaping @MainActor () -> Void) {
            guard let t = env[key].flatMap(Double.init) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { body() }
        }
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
        if env["TC_DEBUG_INSPECTOR"] == "1" { model.showInspector = true }
        after("TC_DEBUG_SELECT_FIRST") {
            if let first = model.store.order.first { model.store.selection = [first] }
        }
        after("TC_DEBUG_SELECT_ALL") { model.store.selection = Set(model.store.order) }
        after("TC_DEBUG_AUTOTRUST") {
            for rt in model.servers {
                if case .needsTrust(let ep, let fp) = rt.status { model.trust(serverID: rt.id, endpoint: ep, fingerprint: fp) }
            }
        }
        if let text = env["TC_DEBUG_ADD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.beginAdd(text: text.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        after("TC_DEBUG_CLEANUP") {
            let refs = model.store.order
            model.requestDelete(refs, cleanup: true)
        }
        after("TC_DEBUG_RETRACKER") {
            if case .site(let sid) = model.store.sidebar {
                model.sheet = .retracker(RetrackerDraft(model: model, siteID: sid, selection: [], scope: .site))
            }
        }
        if let tab = env["TC_DEBUG_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                model.settingsTab = tab
                model.settingsServerFocus = env["TC_DEBUG_SETTINGS_SERVER"]
                model.openSettingsWindow?()
            }
        }
        if env["TC_DEBUG_ABOUT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AboutPanel.show() } }
        if env["TC_DEBUG_LIMITS"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.showSpeedLimits = true } }
        if env["TC_DEBUG_SETUP"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.sheet = .setup } }
        if let spec = env["TC_DEBUG_RETRACKER_SEL"], let t = env["TC_DEBUG_RETRACKER_AT"].flatMap(Double.init) {
            // 「from=>to」：对当前视图前 5 行做一次自定义替换，3 秒后撤销，结果打到日志
            let parts = spec.components(separatedBy: "=>")
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let refs = Array(model.store.order.prefix(5))
                let d = RetrackerDraft(model: model, siteID: nil, selection: refs, scope: .selection)
                d.mode = .custom
                d.find = parts[0]
                d.replacement = parts.count > 1 ? parts[1] : ""
                d.reannounce = false
                Log.info("retracker 计划 \(d.plan.count) 处：\(refs.map(\.id))")
                Task {
                    await d.run()
                    Log.info("retracker 完成：成功 \(d.succeeded.count)，失败 \(d.failures)")
                    try? await Task.sleep(for: .seconds(3))
                    await d.undo()
                    Log.info("retracker 已撤销")
                }
            }
        }
        if let a = env["TC_DEBUG_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        if env["TC_DEBUG_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 340, height: 300), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
                panel.title = "Menu Bar Panel (Debug)"
                let host = NSHostingView(rootView: MenuBarContent(model: model))
                panel.contentView = host
                panel.setContentSize(host.fittingSize)
                panel.orderFrontRegardless()
                debugPanels.append(panel)
            }
        }
        if env["TC_HITCH"] == "1" { HitchMonitor.shared.start() }
    }
}

@MainActor
final class HitchMonitor {
    static let shared = HitchMonitor()
    private var last = CACurrentMediaTime()
    private var worst = 0.0
    private var over50 = 0

    func start() {
        let beat = Timer(timeInterval: 0.004, repeats: true) { _ in MainActor.assumeIsolated { self.beat() } }
        RunLoop.main.add(beat, forMode: .common)
        let report = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { self.report() } }
        RunLoop.main.add(report, forMode: .common)
    }

    private func beat() {
        let now = CACurrentMediaTime()
        let gap = now - last
        last = now
        worst = max(worst, gap)
        if gap > 0.05 { over50 += 1 }
    }

    private func report() {
        print(String(format: "[Peerdeck] hitch: 5s 内主线程最大间隔 %.0fms，>50ms %d 次", worst * 1000, over50))
        fflush(stdout)
        worst = 0
        over50 = 0
    }
}
