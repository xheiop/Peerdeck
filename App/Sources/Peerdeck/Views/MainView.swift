import SwiftUI
import TorrentKit

/// 没有服务器时显示欢迎页，否则显示主界面
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.servers.isEmpty {
                WelcomeView(model: model)
            } else {
                MainView(model: model)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .add(let d): AddTorrentSheet(model: model, draft: d)
            case .delete(let refs, let cleanup): DeleteSheet(model: model, refs: refs, cleanup: cleanup)
            case .retracker(let d): RetrackerSheet(model: model, draft: d)
            case .setLocation(let refs): SetLocationSheet(model: model, refs: refs)
            case .setup: SetupSheet(model: model)
            case .cleanup: DeleteSheet(model: model, refs: model.store.order, cleanup: true)
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
        .alert(model.updateNotice?.title ?? "", isPresented: Binding(get: { model.updateNotice != nil }, set: { if !$0 { model.updateNotice = nil } }),
               presenting: model.updateNotice) { notice in
            if case .available(let release, _) = notice {
                Button("View Release") { NSWorkspace.shared.open(release.page) }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { notice in
            Text(notice.message(homebrew: UpdateCheck.installedWithHomebrew))
        }
        .overlay(alignment: .bottom) { ToastView(model: model) }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Connect Your First Client").font(.title2.weight(.semibold))
            Text("Works with qBittorrent, Transmission and Flood. Each client can have several routes: LAN at home; DDNS, an overlay network or a reverse proxy when away. Passwords are stored in the Keychain.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Add Server…") { model.sheet = .setup }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    @Bindable var model: AppModel

    private var store: TorrentStore { model.store }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                BannersView(model: model)
                ZStack(alignment: .bottom) {
                    TorrentTable(model: model, columns: columns, columnSet: columnSet, selectionRevision: store.selectionRevision)
                        .overlay { EmptyListView(model: model) }
                    if store.selection.count > 1 { BulkBar(model: model).padding(.bottom, 12) }
                }
                StatusBar(model: model)
            }
            .inspector(isPresented: $model.showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(store.search.isEmpty ? Fmt.torrents(store.visibleCount) : L("Matches: \(Fmt.count(store.visibleCount))"))
        .searchable(text: Binding(get: { store.search }, set: { store.search = $0 }), prompt: "Search names")
        .toolbar { toolbar }
        .onExitCommand { if !store.selection.isEmpty { store.selection = [] } }
    }

    private var columnSet: String {
        if store.sidebar.isProblemView { return "problem" }
        if store.sidebar == .state(.downloading) { return "downloading" }
        return "normal"
    }

    private var columns: [ColumnKey] {
        var keys = model.prefs.columns[columnSet].map { $0.compactMap(ColumnKey.init(rawValue:)) } ?? ColumnKey.defaults(for: columnSet)
        if case .site = store.sidebar { keys.removeAll { $0 == .site } }
        if case .server = store.sidebar { keys.removeAll { $0 == .server } }
        if model.servers.count < 2 { keys.removeAll { $0 == .server } }
        return keys
    }

    private var title: String { model.title(for: store.sidebar) }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.beginAdd() } label: { Label("Add", systemImage: "plus") }
                .help("Add torrents (⌘N)")
            Button { model.toggleRun(store.selection) } label: {
                model.selectionAllStopped ? Label("Start", systemImage: "play.fill") : Label("Stop", systemImage: "pause.fill")
            }
            .disabled(store.selection.isEmpty)
            .help("Start / stop selected torrents")
            Button { model.requestDelete(store.selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(store.selection.isEmpty)
                .keyboardShortcut(.delete)
                .help("Delete selected torrents (⌘⌫)")
            Button { model.showSpeedLimits.toggle() } label: {
                Label(model.altSpeedCount > 0 ? "Speed Limits (\(model.altSpeedCount))" : "Speed Limits", systemImage: model.altSpeedCount > 0 ? "tortoise.fill" : "tortoise")
            }
            .help("Speed limits per server: values and alternative mode")
            .popover(isPresented: $model.showSpeedLimits, arrowEdge: .bottom) { SpeedLimitsView(model: model) }
            Button { model.showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help("Details (or double-click a row)")
        }
    }
}

/// 列表为空时盖在表格上：搜索无结果、问题视图没有问题。普通视图为空不提示（载入中也是空的）
struct EmptyListView: View {
    let model: AppModel

    var body: some View {
        let store = model.store
        // 还有服务器在连接或载入时，空列表只是暂时的
        let settled = model.servers.allSatisfy { rt in
            if case .connecting = rt.status { return false }
            return !rt.status.isOnline || rt.loaded
        }
        if store.visibleCount == 0, settled, !store.search.isEmpty || store.sidebar.isProblemView {
            Group {
                if !store.search.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    switch store.sidebar {
                    case .rejected:
                        ContentUnavailableView("No Torrents Rejected by Trackers", systemImage: "checkmark.seal",
                                               description: Text("Torrents rejected by a tracker (unregistered, banned client and so on) show up here."))
                    case .unregistered:
                        ContentUnavailableView("No Likely Unregistered Torrents", systemImage: "checkmark.seal",
                                               description: Text(model.pendingMessageCount > 0
                                                                 ? L("Still checking tracker messages for \(Fmt.torrents(model.pendingMessageCount)).")
                                                                 : L("Rejected torrents whose tracker message matches the keywords in Settings › Sites show up here.")))
                    case .unreachable:
                        let recent = store.counts.unreachableTransient
                        ContentUnavailableView("No Trackers Unreachable for Long", systemImage: "checkmark.seal",
                                               description: Text(recent > 0
                                                                 ? L("\(Fmt.torrents(recent)) can’t reach their tracker right now. They show up here if it lasts more than \(model.prefs.longUnreachableHours) h.")
                                                                 : L("Torrents whose tracker stays unreachable for more than \(model.prefs.longUnreachableHours) h show up here.")))
                    default:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        let sel = model.store.selection
        HStack(spacing: 16) {
            Text(Fmt.torrents(model.store.visibleCount))
            if !sel.isEmpty {
                let size = sel.compactMap { model.store.torrent($0)?.totalSize }.reduce(0, +)
                Text("\(Fmt.count(sel.count)) selected · \(Fmt.bytes(size))")
            }
            Spacer()
            if model.totalDown > 0 { Text("↓ \(Fmt.speed(model.totalDown))") }
            if model.totalUp > 0 { Text("↑ \(Fmt.speed(model.totalUp))") }
            if model.totalDown == 0, model.totalUp == 0 { Text("Idle") }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct ToastView: View {
    let model: AppModel

    var body: some View {
        if let t = model.toast {
            HStack(spacing: 12) {
                Text(t.text)
                if t.undo { Button("Undo") { model.undoDelete() }.buttonStyle(.borderless).fontWeight(.semibold) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            // 多选操作条在底部时让开它，不然提示会盖住按钮
            .padding(.bottom, model.store.selection.count > 1 && model.sheet == nil ? 92 : 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}
