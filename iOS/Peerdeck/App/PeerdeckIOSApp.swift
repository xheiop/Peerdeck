import Security
import SwiftUI
import TorrentKit

@main
struct PeerdeckIOSApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        let env = ProcessInfo.processInfo.environment
        AppLanguage.shareWithExtension()
        // 调试：把一份 JSON 配置写进 Keychain（验证 Keychain 共享组能读写），之后照常从 Keychain 读。
        // 同时给了 TC_DEBUG_KEYCHAIN_GROUP 时，先删掉所有组里的这一条，再只写进那个组，模拟旧版本存的配置（验证下面的搬迁）
        if let path = env["TC_DEBUG_IMPORT_TO_KEYCHAIN"], let configs = try? FileConfigStore(url: URL(fileURLWithPath: path)).load() {
            let group = env["TC_DEBUG_KEYCHAIN_GROUP"]
            if group != nil { SecItemDelete(KeychainConfigStore().query as CFDictionary) }
            do { try KeychainConfigStore(accessGroup: group).save(configs); Log.info("已把 \(configs.count) 台服务器写进 Keychain（组：\(group ?? "默认")）") }
            catch { Log.info("写 Keychain 失败：\(error)") }
        }
        let store: any ConfigStore = if let path = env["TC_CONFIG_FILE"] {
            FileConfigStore(url: URL(fileURLWithPath: path))
        } else {
            KeychainConfigStore()
        }
        // 旧版本存在别的钥匙串组里的配置挪进共享组，分享扩展才读得到
        (store as? KeychainConfigStore)?.moveToDefaultGroup()
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
