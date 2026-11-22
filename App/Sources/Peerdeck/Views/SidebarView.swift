import SwiftUI
import TorrentKit

struct SidebarView: View {
    let model: AppModel
    @State private var showAllSites = false
    @State private var showAllCategories = false
    @State private var showAllTags = false

    var body: some View {
        let c = model.store.counts
        let selection = Binding<SidebarItem?>(get: { model.store.sidebar }, set: { model.store.sidebar = $0 ?? .all })
        List(selection: selection) {
            Section {
                row(L("All"), "tray.full", count: c.total).tag(SidebarItem.all)
                row(L("Active"), "arrow.up.arrow.down", count: c.active).tag(SidebarItem.active)
            }

            // 这一节始终显示：有问题时才插入的话，下面的行整体移位，
            // SwiftUI 侧栏 List 在 diff 时会把选中项弄错（实测侧栏自己跳到了别的服务器）
            Section("Needs Attention") {
                row(L("Rejected by Tracker"), "exclamationmark.triangle.fill", tint: c.rejected > 0 ? .red : nil, badge: c.rejected, zero: true).tag(SidebarItem.rejected)
                row(L("Likely Unregistered"), "xmark.seal", tint: c.unregistered > 0 ? .red : nil, count: c.unregistered,
                    sub: model.pendingMessageCount > 0 ? L("Checking \(Fmt.count(model.pendingMessageCount)) more…") : nil)
                    .padding(.leading, 14)
                    .tag(SidebarItem.unregistered)
                row(L("Unreachable for Long"), "bolt.horizontal.circle", tint: c.unreachableLong > 0 ? .orange : nil, badge: c.unreachableLong, orange: true, zero: true,
                    sub: L("Over \(model.prefs.longUnreachableHours) h · \(Fmt.count(c.unreachableTransient)) more recent"))
                    .tag(SidebarItem.unreachable)
            }

            Section("Status") {
                ForEach(StateGroup.allCases, id: \.self) { g in
                    row(g.title, g.symbol, tint: g == .error && (c.states[g] ?? 0) > 0 ? .red : nil, count: c.states[g] ?? 0).tag(SidebarItem.state(g))
                }
            }

            Section(String(localized: "Servers", table: "Groups")) {
                ForEach(model.servers) { rt in
                    ServerRow(runtime: rt, count: c.servers[rt.id] ?? 0).tag(SidebarItem.server(rt.id))
                }
                Button { model.sheet = .setup } label: {
                    Label("Add Server…", systemImage: "plus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }

            Section(String(localized: "Sites", table: "Groups")) {
                let sites = c.sites.keys.sorted { (c.siteProblems[$0] ?? 0, c.sites[$0] ?? 0) > (c.siteProblems[$1] ?? 0, c.sites[$1] ?? 0) }
                ForEach(showAllSites ? sites : Array(sites.prefix(8)), id: \.self) { sid in
                    row(model.siteName(sid), "globe", badge: c.siteProblems[sid] ?? 0, count: c.sites[sid] ?? 0).tag(SidebarItem.site(sid))
                }
                if sites.count > 8 {
                    Button(showAllSites ? "Show Less" : "\(sites.count - 8) More Sites") { showAllSites.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            // 分类、标签放在最后：有数据才出现，插在末尾不会让上面的行移位（见「需要处理」那一节的说明）
            if !c.categories.isEmpty {
                Section(L("Categories")) {
                    let cats = c.categories.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    ForEach(showAllCategories ? cats : Array(cats.prefix(8)), id: \.self) { name in
                        row(name, "folder", count: c.categories[name] ?? 0).tag(SidebarItem.category(name))
                    }
                    if cats.count > 8 {
                        Button(showAllCategories ? "Show Less" : "\(cats.count - 8) More") { showAllCategories.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if !c.tags.isEmpty {
                Section(L("Tags")) {
                    let tags = c.tags.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    ForEach(showAllTags ? tags : Array(tags.prefix(8)), id: \.self) { name in
                        row(name, "tag", count: c.tags[name] ?? 0).tag(SidebarItem.tag(name))
                    }
                    if tags.count > 8 {
                        Button(showAllTags ? "Show Less" : "\(tags.count - 8) More") { showAllTags.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 颜色只放在图标和徽标上，文字保持主色
    private func row(_ title: String, _ symbol: String, tint: Color? = nil, badge: Int = 0, orange: Bool = false, zero: Bool = false, count: Int = 0, sub: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint ?? .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if badge > 0 {
                Text(Fmt.count(badge))
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(orange ? Color.orange : Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if count > 0 || (zero && badge == 0) { Text(Fmt.count(count)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}
