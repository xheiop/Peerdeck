import SwiftUI
import TorrentKit

/// 切换视图（mac 的侧栏）：全部、需要处理、状态、服务器、站点、分类、标签。v3：左边数字列，颜色只在健康度形状上
struct FilterScreen: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = model.store.counts
        NavigationStack {
            List {
                Section {
                    row(.all, L("All"), count: c.total)
                    row(.active, L("Active"), count: c.active)
                }
                Section("Needs Attention") {
                    row(.unregistered, L("Likely Unregistered"), mark: .unregistered, count: c.unregistered,
                        sub: model.pendingMessageCount > 0 ? L("Checking \(Fmt.count(model.pendingMessageCount)) more…") : nil)
                    row(.rejected, L("Rejected by Tracker"), mark: .rejected, count: c.rejected)
                    row(.unreachable, L("Unreachable for Long"), mark: .timeout, count: c.unreachableLong,
                        sub: L("Over \(model.prefs.longUnreachableHours) h · \(Fmt.count(c.unreachableTransient)) more recent"))
                }
                Section("Status") {
                    ForEach(StateGroup.allCases, id: \.self) { g in
                        row(.state(g), g.title, count: c.states[g] ?? 0)
                    }
                }
                Section(String(localized: "Servers", table: "Groups")) {
                    ForEach(model.servers) { rt in
                        pick(.server(rt.id)) { ServerRow(runtime: rt, count: c.servers[rt.id] ?? 0) }
                    }
                }
                let sites = c.sites.keys.sorted { (c.siteProblems[$0] ?? 0, c.sites[$0] ?? 0) > (c.siteProblems[$1] ?? 0, c.sites[$1] ?? 0) }
                if !sites.isEmpty {
                    Section(String(localized: "Sites", table: "Groups")) {
                        ForEach(sites, id: \.self) { sid in
                            row(.site(sid), model.siteName(sid), count: c.sites[sid] ?? 0,
                                sub: (c.siteProblems[sid] ?? 0) > 0 ? L("\(c.siteProblems[sid] ?? 0) need attention") : nil)
                        }
                    }
                }
                if !c.categories.isEmpty {
                    Section(L("Categories")) {
                        ForEach(c.categories.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { n in
                            row(.category(n), n, count: c.categories[n] ?? 0)
                        }
                    }
                }
                if !c.tags.isEmpty {
                    Section(L("Tags")) {
                        ForEach(c.tags.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { n in
                            row(.tag(n), n, count: c.tags[n] ?? 0)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Views")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func pick(_ item: SidebarItem, @ViewBuilder _ label: () -> some View) -> some View {
        Button {
            model.store.sidebar = item
            dismiss()
        } label: {
            HStack {
                label()
                if model.store.sidebar == item { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 一行：名字在左（问题视图前面带健康度形状），数量灰色放行尾，同系统列表的习惯
    private func row(_ item: SidebarItem, _ title: String, mark: HealthMark? = nil, count: Int = 0, sub: String? = nil) -> some View {
        pick(item) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let mark { mark.view.opacity(count > 0 ? 1 : 0.35) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(Fmt.count(count)).font(.system(.callout, design: .monospaced)).foregroundStyle(count == 0 ? .tertiary : .secondary)
            }
        }
    }
}
