import SwiftUI
import TorrentKit

@main
struct PeerdeckIOSApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        let env = ProcessInfo.processInfo.environment
        // 调试：把一份 JSON 配置写进 Keychain（验证 Keychain 共享组能读写），之后照常从 Keychain 读
        if let path = env["TC_DEBUG_IMPORT_TO_KEYCHAIN"], let configs = try? FileConfigStore(url: URL(fileURLWithPath: path)).load() {
            do { try KeychainConfigStore().save(configs); Log.info("已把 \(configs.count) 台服务器写进 Keychain") }
            catch { Log.info("写 Keychain 失败：\(error)") }
        }
        let store: any ConfigStore = if let path = env["TC_CONFIG_FILE"] {
            FileConfigStore(url: URL(fileURLWithPath: path))
        } else {
            KeychainConfigStore()
        }
        let model = AppModel(configStore: store)
        _model = State(initialValue: model)
        DispatchQueue.main.async { model.load() }
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: model)
                // v3：操作、开关、选中态一律墨色（面板也继承），颜色只留给 tracker 健康度
                .tint(Color.ink)
                // magnet: 链接，以及从「文件」或别的 app 打开的 .torrent
                .onOpenURL { model.handleOpen([$0]) }
        }
        // 进后台停止轮询，回前台立刻刷新
        .onChange(of: phase) { _, p in model.setForeground(p == .active) }
    }
}
