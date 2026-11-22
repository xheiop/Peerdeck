import SwiftUI
import TorrentKit

/// 「种子」标签：当前视图的种子列表。左上角切换视图（相当于 mac 的侧栏），右上角添加和更多操作；多选时底部是批量操作
struct TorrentsScreen: View {
    @Bindable var model: AppModel
    /// 「搜索」标签里的那份：在全部种子里搜，不显示视图切换
    var searchTab = false
    @State private var showFilters = DebugHooks.screen == "filters"
    @State private var showSettings = DebugHooks.screen == "settings"
    @State private var showSpeed = DebugHooks.screen == "speed"
    @State private var detail: TorrentRef?
    @State private var editing = false

    private var store: TorrentStore { model.store }

    var body: some View {
        NavigationStack {
            TorrentTableView(model: model, editing: editing, selectionRevision: store.selectionRevision,
                             problemLayout: store.sidebar.isProblemView) { detail = $0 }
                .overlay { IOSEmptyList(model: model) }
                .safeAreaInset(edge: .top, spacing: 0) { IOSBanners(model: model) { showSettings = true } }
                .navigationTitle(searchTab ? L("Search") : model.title(for: store.sidebar))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(editing ? .hidden : .automatic, for: .tabBar)
                .searchable(text: Binding(get: { store.search }, set: { store.search = $0 }), prompt: Text("Search names"))
                .toolbar { toolbar }
                .navigationDestination(item: $detail) { ref in TorrentDetailScreen(model: model, ref: ref) }
        }
        .sheet(isPresented: $showFilters) { FilterScreen(model: model) }
        .sheet(isPresented: $showSettings) { SettingsScreen(model: model) }
        .sheet(isPresented: $showSpeed) { SpeedScreen(model: model).presentationDetents([.medium, .large]) }
        .onAppear {
            model.openSettingsWindow = { showSettings = true }
            if searchTab { store.sidebar = .all }
        }
        .onChange(of: store.sidebar) { _, _ in if editing { store.selection = [] } }
        .task {
            if let s = ProcessInfo.processInfo.environment["TC_DEBUG_CLEANUP"], let t = Double(s) {
                try? await Task.sleep(for: .seconds(t))
                model.sheet = .cleanup
            }
            if let s = ProcessInfo.processInfo.environment["TC_DEBUG_OPEN_FIRST"], let t = Double(s) {
                try? await Task.sleep(for: .seconds(t))
                detail = store.order.first
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(model.title(for: store.sidebar)).font(.headline).lineLimit(1)
                Text(editing ? L("\(Fmt.count(store.selection.count)) selected") : store.search.isEmpty ? Fmt.torrents(store.visibleCount) : L("Matches: \(Fmt.count(store.visibleCount))"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        if editing {
            ToolbarItem(placement: .topBarLeading) {
                let all = store.selection.count == store.visibleCount && store.visibleCount > 0
                Button(all ? "Deselect All" : "Select All") { store.selection = all ? [] : Set(store.order) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { editing = false; store.selection = [] }.fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) { batchBar }
        } else {
            if !searchTab {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFilters = true } label: { Label("Views", systemImage: "line.3.horizontal.decrease.circle") }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.beginAdd() } label: { Label("Add", systemImage: "plus") }
                Menu {
                    Button { store.selection = []; editing = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    sortMenu
                    Button { showSpeed = true } label: { Label("Speed Limits", systemImage: "tortoise") }
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
    }

    private var sortMenu: some View {
        let keys: [ColumnKey] = [.name, .added, .size, .uploaded, .ratio, .seedTime, .speedUp, .speedDown, .eta, .site, .server]
        return Menu {
            Picker("Sort By", selection: Binding(get: { store.sortColumn }, set: { k in
                if store.sortColumn == k { store.ascending.toggle() } else { store.sortColumn = k; store.ascending = !k.defaultDescending }
            })) {
                ForEach(keys, id: \.self) { k in Text(k.title).tag(k) }
            }
            Divider()
            Picker("Order", selection: Binding(get: { store.ascending }, set: { store.ascending = $0 })) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
    }

    @ViewBuilder private var batchBar: some View {
        let refs = Array(store.selection)
        Button { model.perform(.start, on: refs) } label: { Label("Start", systemImage: "play.fill") }.disabled(refs.isEmpty)
        Spacer()
        Button { model.perform(.stop, on: refs) } label: { Label("Stop", systemImage: "pause.fill") }.disabled(refs.isEmpty)
        Spacer()
        Menu {
            Button { model.perform(.reannounce, on: refs); model.showToast(L("Reannounced \(Fmt.torrents(refs.count))")) } label: { Label("Reannounce", systemImage: "arrow.clockwise") }
            Button { model.perform(.recheck, on: refs) } label: { Label("Recheck", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
        } label: { Label("More", systemImage: "ellipsis.circle") }
            .disabled(refs.isEmpty)
        Spacer()
        Button(role: .destructive) { model.requestDelete(refs) } label: { Label("Delete", systemImage: "trash") }.disabled(refs.isEmpty)
    }
}

/// 列表为空：搜索无结果、问题视图没有问题（同 mac 的 EmptyListView）
struct IOSEmptyList: View {
    let model: AppModel

    var body: some View {
        let store = model.store
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
                    default:
                        let recent = store.counts.unreachableTransient
                        ContentUnavailableView("No Trackers Unreachable for Long", systemImage: "checkmark.seal",
                                               description: Text(recent > 0
                                                                 ? L("\(Fmt.torrents(recent)) can’t reach their tracker right now. They show up here if it lasts more than \(model.prefs.longUnreachableHours) h.")
                                                                 : L("Torrents whose tracker stays unreachable for more than \(model.prefs.longUnreachableHours) h show up here.")))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        }
    }
}

/// 列表上方的提示：服务器离线、证书待确认、核对进度、清理入口（v3：不用色块，只有健康度形状带颜色）
struct IOSBanners: View {
    let model: AppModel
    let openSettings: () -> Void
    private var store: TorrentStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.servers) { rt in
                if case .failed(let msg) = rt.status {
                    bar {
                        Image(systemName: "powerplug.portrait").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(rt.config.name) can’t connect").fontWeight(.semibold)
                            Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            Button("Retry") { rt.start() }
                            Button("Edit Server…") { model.settingsServerFocus = rt.id; openSettings() }
                        } label: { Image(systemName: "ellipsis.circle").imageScale(.large) }
                    }
                }
                if case .needsTrust(let ep, let fp) = rt.status {
                    bar {
                        Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rt.config.name): the certificate of \(ep.baseURL.absoluteString) isn’t trusted by the system").font(.callout)
                            Text("SHA256 \(fp)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Trust This Certificate") { model.trust(serverID: rt.id, endpoint: ep, fingerprint: fp) }
                                .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if store.sidebar == .rejected || store.sidebar == .unregistered, model.pendingMessageCount > 0 {
                bar {
                    ProgressView()
                    Text("Checking tracker messages for \(Fmt.torrents(model.pendingMessageCount))… “Likely Unregistered” may still grow.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            if store.sidebar == .unregistered, store.visibleCount > 0 {
                bar {
                    HealthMark.unregistered.view
                    Text("\(Fmt.torrents(store.visibleCount)) reported as unregistered by the tracker").font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Button("Clean Up…") { model.sheet = .cleanup }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.onInk)
                        .padding(.horizontal, 12).frame(height: 30).background(Color.ink, in: .capsule)
                }
            }
            if store.sidebar == .unreachable, store.visibleCount > 0 {
                bar {
                    HealthMark.timeout.view
                    Text("Unreachable trackers are usually temporary; deleting isn’t recommended").font(.footnote)
                    Spacer(minLength: 4)
                    Button("Reannounce All") {
                        model.perform(.reannounce, on: store.order)
                        model.showToast(L("Reannounced \(Fmt.torrents(store.order.count))"))
                    }
                    .font(.subheadline).foregroundStyle(.primary)
                }
            }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}
