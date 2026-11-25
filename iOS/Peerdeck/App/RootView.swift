import SwiftUI
import TorrentKit

/// 没有服务器时显示欢迎页，否则是标签页。各种面板（添加、删除、添加服务器）都从这里弹出
struct IOSRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.servers.isEmpty {
                IOSWelcomeView(model: model)
            } else {
                IOSTabs(model: model)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .add(let d): AddTorrentScreen(model: model, draft: d)
            case .delete(let refs, let cleanup):
                if cleanup { CleanupScreen(model: model) } else { DeleteScreen(model: model, refs: refs) }
            case .setLocation(let refs): SetLocationScreen(model: model, refs: refs)
            case .renameTorrent(let ref): RenameTorrentScreen(model: model, ref: ref)
            case .setup: SetupScreen(model: model)
            case .cleanup: CleanupScreen(model: model)
            case .retracker:
                // 替换 tracker 只在 mac 上做
                ContentUnavailableView("Replace Tracker is available on the Mac", systemImage: "desktopcomputer")
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
        .overlay(alignment: .bottom) { IOSToast(model: model) }
    }
}

struct IOSWelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Connect Your First Client").font(.title2.weight(.semibold))
            Text("Works with qBittorrent, Transmission and Flood. Each client can have several routes: LAN at home; DDNS, an overlay network or a reverse proxy when away. Passwords are stored in the Keychain.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button { model.sheet = .setup } label: {
                Text("Add Server…").font(.headline).padding(.horizontal, 28).frame(height: 50)
            }
            .foregroundStyle(Color.onInk)
            .background(Color.ink, in: .capsule)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 底部的一次性提示（玻璃胶囊，浮层所以用玻璃）
struct IOSToast: View {
    let model: AppModel

    var body: some View {
        // 撤销倒计时在标签栏的附件条里，这里只显示一次性提示
        if let t = model.toast, !t.undo {
            HStack(spacing: 12) {
                Text(t.text).font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCapsule()
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

/// 标签页：总览 / 种子 / 站点 / 下载器 + 搜索。撤销窗口里标签栏上方出现附件条
struct IOSTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        tabs
            .minimizeTabBarOnScroll()
            .tint(Color.ink) // v3：选中态和操作用墨色，不用系统蓝
            .toggleStyle(InkSwitchStyle())
            .modifier(UndoAccessoryModifier(model: model))
            .onAppear {
                if let t = DebugHooks.tab { model.selectedTab = t }
            }
    }

    /// iOS 18 起用 Tab（搜索是独立的 .search 角色标签）；iOS 17 退回 tabItem，搜索做成普通的第五个标签
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $model.selectedTab) {
                Tab(String(localized: "Overview", table: "Groups"), systemImage: "list.bullet.rectangle", value: "overview") {
                    OverviewScreen(model: model)
                }
                Tab("Torrents", systemImage: "arrow.up.arrow.down", value: "torrents") {
                    TorrentsScreen(model: model)
                }
                Tab("Sites", systemImage: "globe", value: "sites") {
                    SitesScreen(model: model)
                }
                Tab(String(localized: "Servers", table: "Groups"), systemImage: "server.rack", value: "servers") {
                    ServersScreen(model: model)
                }
                Tab(value: "search", role: .search) {
                    TorrentsScreen(model: model, searchTab: true)
                }
            }
        } else {
            TabView(selection: $model.selectedTab) {
                OverviewScreen(model: model)
                    .tabItem { Label(String(localized: "Overview", table: "Groups"), systemImage: "list.bullet.rectangle") }
                    .tag("overview")
                TorrentsScreen(model: model)
                    .tabItem { Label("Torrents", systemImage: "arrow.up.arrow.down") }
                    .tag("torrents")
                SitesScreen(model: model)
                    .tabItem { Label("Sites", systemImage: "globe") }
                    .tag("sites")
                ServersScreen(model: model)
                    .tabItem { Label(String(localized: "Servers", table: "Groups"), systemImage: "server.rack") }
                    .tag("servers")
                TorrentsScreen(model: model, searchTab: true)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag("search")
            }
        }
    }
}

/// 撤销附件条只在撤销窗口里出现。tabViewBottomAccessory(isEnabled:) 要 iOS 26.1；更早的系统退回成标签栏上方的胶囊
private struct UndoAccessoryModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: model.pending != nil) { PlacedUndoAccessory(model: model) }
        } else {
            content.overlay(alignment: .bottom) {
                if model.pending != nil {
                    UndoAccessory(model: model)
                        .frame(height: 48)
                        .glassCapsule()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 92)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

/// 附件条收进标签栏（.inline）时文案用短的。tabViewBottomAccessoryPlacement 只有 iOS 26 有
@available(iOS 26.0, *)
private struct PlacedUndoAccessory: View {
    let model: AppModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        UndoAccessory(model: model, short: placement == .inline)
    }
}
