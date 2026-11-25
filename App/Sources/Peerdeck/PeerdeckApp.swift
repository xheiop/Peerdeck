import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// 启动参数里带进来的 URL（冷启动时 model 可能还没准备好）
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.handleOpen(urls) } else { pending += urls }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugSnapshot.scheduleIfNeeded()
    }

    func attach(_ model: AppModel) {
        self.model = model
        if !pending.isEmpty {
            model.handleOpen(pending)
            pending = []
        }
    }

    /// 关掉主窗口后 app 继续在菜单栏运行
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.prefs.keepInMenuBar ?? true) }

    func applicationWillTerminate(_ notification: Notification) { model?.saveLedgerNow() }
}

@main
struct PeerdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var media: MediaLibrary

    init() {
        // 注意：这里不要碰 NSApplication.shared（M0 实测会导致 WindowGroup 不开窗口）
        let env = ProcessInfo.processInfo.environment
        _ = AppLanguage.atLaunch
        let store: any ConfigStore = if let path = env["TC_CONFIG_FILE"] {
            FileConfigStore(url: URL(fileURLWithPath: path))
        } else {
            KeychainConfigStore()
        }
        let model = AppModel(configStore: store)
        _model = State(initialValue: model)
        let media = MediaLibrary(model: model)
        _media = State(initialValue: media)
        MediaDebug.installIfNeeded(media)
        // 等 run loop 起来再加载，避免启动时同步读 Keychain 卡住首帧
        DispatchQueue.main.async {
            model.load()
            model.checkForUpdatesIfDue()
        }
        // 菜单栏常驻时 app 会开很久：每 6 小时看一次是否到了该检查的时间（一天最多查一次）
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(6 * 3600))
                model.checkForUpdatesIfDue()
            }
        }
    }

    var body: some Scene {
        Window("Peerdeck", id: "main") {
            RootView(model: model)
                .environment(media)
                .frame(minWidth: 900, minHeight: 500)
                .onAppear { delegate.attach(model) }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Peerdeck") { AboutPanel.show() }
                // 结果在主窗口弹出，所以先把主窗口打开
                Button("Check for Updates…") {
                    NSApp.activate()
                    model.openMainWindow?()
                    model.checkForUpdates(manual: true)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Torrents…") { model.beginAdd() }.keyboardShortcut("n")
                Button("Add Server…") { model.sheet = .setup; NSApp.activate(); model.openMainWindow?() }
            }
        }

        Settings {
            SettingsView(model: model)
                .environment(media)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
