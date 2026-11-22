import SwiftUI
import TorrentKit

/// 「站点」标签：每个站一行，有问题的站排在前面、问题数放在名字下面；种子总数是次要信息，放在行尾
struct SitesScreen: View {
    let model: AppModel

    var body: some View {
        let c = model.store.counts
        let sites = c.sites.keys.sorted { (c.siteProblems[$0] ?? 0, c.sites[$0] ?? 0, $1) > (c.siteProblems[$1] ?? 0, c.sites[$1] ?? 0, $0) }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sites.enumerated()), id: \.element) { i, sid in
                        if i > 0 { InsetSeparator() }
                        Button { show(.site(sid)) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.siteName(sid)).font(.subheadline).lineLimit(1)
                                    // 站点的问题数混了被拒绝和长时间超时，不用某一种健康度形状，只写字；有问题时替换掉域名那一行
                                    if let n = c.siteProblems[sid], n > 0 {
                                        Text(L("\(n) need attention")).font(.footnote.weight(.medium))
                                    } else if sid != model.siteName(sid) {
                                        Text(sid).font(.data).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    totals(sid, c)
                                }
                                Spacer(minLength: 6)
                                Text(Fmt.count(c.sites[sid] ?? 0)).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            .overlay {
                if sites.isEmpty { ContentUnavailableView("No Sites Yet", systemImage: "globe") }
            }
            .navigationTitle("Sites")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { IOSSitesScreen(model: model) } label: { Label("Edit Sites", systemImage: "slider.horizontal.3") }
                }
            }
        }
    }

    /// 这个站所有种子的已上传 / 已下载 / 体积合计
    private func totals(_ sid: String, _ c: SidebarCounts) -> some View {
        let up = Fmt.bytes(c.siteUploaded[sid] ?? 0), down = Fmt.bytes(c.siteDownloaded[sid] ?? 0)
        let size = Fmt.bytes(c.siteSize[sid] ?? 0)
        return Text(verbatim: "↑ \(up)  ↓ \(down)  " + L("\(size) total"))
            .font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            .accessibilityLabel(Text(Fmt.labeled(L("Total uploaded"), up) + ", " + Fmt.labeled(L("Total downloaded"), down) + ", " + L("\(size) total")))
    }

    private func show(_ item: SidebarItem) {
        model.store.search = ""
        model.store.sidebar = item
        model.selectedTab = "torrents"
    }
}

/// 「服务器」标签：每台一行（状态、速度、剩余空间、备用限速），点进去编辑；右上角添加和设置
struct ServersScreen: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var showSettings = DebugHooks.screen == "settings"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.servers.enumerated()), id: \.element.id) { i, rt in
                        if i > 0 { InsetSeparator(leading: ServerLedgerRow.textInset) }
                        NavigationLink(value: rt.id) {
                            ServerLedgerRow(model: model, runtime: rt).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if case .failed(let msg) = rt.status {
                            Text(msg).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                .padding(.leading, ServerLedgerRow.textInset).padding(.trailing, 20).padding(.bottom, 8)
                        }
                        if case .needsTrust(let ep, let fp) = rt.status {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The certificate of \(ep.baseURL.absoluteString) isn’t trusted by the system").font(.footnote)
                                Text("SHA256 \(fp)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Trust This Certificate") { model.trust(serverID: rt.id, endpoint: ep, fingerprint: fp) }
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                            }
                            .padding(.leading, ServerLedgerRow.textInset).padding(.trailing, 20).padding(.bottom, 10)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle(String(localized: "Servers", table: "Groups"))
            .navigationDestination(for: String.self) { id in
                if let c = model.server(id)?.config { ServerEditScreen(model: model, original: c) } else { EmptyView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Label("Add Server…", systemImage: "plus") }
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $adding) { SetupScreen(model: model) }
            .sheet(isPresented: $showSettings) { SettingsScreen(model: model) }
        }
    }
}
