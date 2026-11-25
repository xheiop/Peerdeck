import SwiftUI
import TorrentKit

/// 总览：此刻的上传下载速度、下载器记的累计总量，下面是种子按状态分的几行。
/// 「需要处理」和其他状态一样只是一行，详情在二级页 AttentionScreen。
struct OverviewScreen: View {
    let model: AppModel
    @Namespace private var glass
    @State private var path: [OverviewPage] = DebugHooks.screen == "attention" ? [.attention] : []
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var totalSize: CGFloat = 24

    private var store: TorrentStore { model.store }
    private var tri: Triage { store.triage }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    capsules.padding(.horizontal, 20).padding(.bottom, 22)
                    // 多视图的 ViewBuilder，modifier 要加在外面包的 VStack 上，否则会加到每个子视图上
                    VStack(alignment: .leading, spacing: 0) { now }
                    VStack(alignment: .leading, spacing: 0) { allTime }.padding(.top, 26)
                    VStack(alignment: .leading, spacing: 0) { torrents }.padding(.top, 30)
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .navigationTitle(String(localized: "Overview", table: "Groups"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.beginAdd() } label: { Label("Add Torrents…", systemImage: "plus") }
                }
            }
            .navigationDestination(for: OverviewPage.self) { _ in AttentionScreen(model: model) }
        }
    }

    // MARK: 下载器胶囊：只说在线 / 离线（速度在下面）；离线的分离出来，2 台以上离线合成一颗

    private var capsules: some View {
        let online = model.servers.filter { $0.status.isOnline }
        let offline = model.servers.filter { rt in
            switch rt.status {
            case .failed, .needsTrust: true
            default: false
            }
        }
        return GlassGroup(spacing: 8) {
            HStack(spacing: 6) {
                Button { model.selectedTab = "servers" } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.primary).accessibilityHidden(true)
                        Text(L("\(online.count) online")).font(.subheadline)
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                }
                .buttonStyle(.plain)
                .glassCapsule(interactive: true)
                .glassID("online", in: glass)

                if offline.count == 1, let rt = offline.first {
                    Button { model.selectedTab = "servers" } label: {
                        HStack(spacing: 6) {
                            Image(systemName: offlineSymbol(rt)).font(.footnote).foregroundStyle(.secondary)
                            Text(rt.config.name).font(.subheadline).lineLimit(1)
                            Text(offlineWord(rt)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true)
                    .glassID("offline", in: glass)
                } else if offline.count > 1 {
                    Button { model.selectedTab = "servers" } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "powerplug.portrait").font(.footnote).foregroundStyle(.secondary)
                            Text(L("\(offline.count) offline")).font(.subheadline)
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true)
                    .glassID("offline", in: glass)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth, value: offline.map(\.id))
    }

    private func offlineSymbol(_ rt: ServerRuntime) -> String {
        if case .needsTrust = rt.status { return "lock.trianglebadge.exclamationmark" }
        return "powerplug.portrait"
    }

    private func offlineWord(_ rt: ServerRuntime) -> String {
        if case .needsTrust = rt.status { return L("Certificate") }
        return L("Offline")
    }

    // MARK: 此刻 / 累计

    /// 「此刻 · 不含 nas-home」：离线的下载器不算进数字时，在小标题上说明
    private func header(_ title: String) -> String {
        model.offlineNote.map { "\(title) · \($0)" } ?? title
    }

    /// Flood 没有历史总量：和离线的一样，说明没算进来，不能让人以为是全部
    private func allTimeHeader(_ online: [ServerRuntime]) -> String {
        let names = model.servers.filter { store.offlineServers.contains($0.id) }.map(\.config.name)
            + online.filter { $0.config.kind == .flood }.map(\.config.name)
        guard !names.isEmpty else { return L("All Time") }
        return "\(L("All Time")) · \(L("excluding \(names.joined(separator: L(", ")))"))"
    }

    @ViewBuilder private var now: some View {
        LedgerHeader(title: header(L("Now"))).padding(.bottom, 6)
        HStack(alignment: .top, spacing: 12) {
            figure(tri.downloadSpeed, perSecond: true, size: speedSize, unitFont: .subheadline, label: L("↓ Download"), name: L("Download"))
            figure(tri.uploadSpeed, perSecond: true, size: speedSize, unitFont: .subheadline, label: L("↑ Upload"), name: L("Upload"))
        }
        .padding(.horizontal, 20)
    }

    /// 下载器自己记的历史总量（qB alltime_*、TR cumulative-stats），只加在线的；一台都没拿到时显示 —
    @ViewBuilder private var allTime: some View {
        let rts = model.servers.filter { $0.status.isOnline && !store.offlineServers.contains($0.id) }
        let up = rts.compactMap(\.stats.allTimeUploaded), down = rts.compactMap(\.stats.allTimeDownloaded)
        LedgerHeader(title: allTimeHeader(rts)).padding(.bottom, 6)
        HStack(alignment: .top, spacing: 12) {
            figure(up.isEmpty ? nil : up.reduce(0, +), size: totalSize, unitFont: .footnote, label: L("Total uploaded"), name: L("Total uploaded"))
            figure(down.isEmpty ? nil : down.reduce(0, +), size: totalSize, unitFont: .footnote, label: L("Total downloaded"), name: L("Total downloaded"))
        }
        .padding(.horizontal, 20)
    }

    /// 大数字 + 小一号灰色单位，下面一行说明
    private func figure(_ bytes: Int64?, perSecond: Bool = false, size: CGFloat, unitFont: Font, label: String, name: String) -> some View {
        let parts = bytes.map(Fmt.bytesParts) ?? (value: "—", unit: "")
        let unit = parts.unit.isEmpty ? "" : parts.unit + (perSecond ? "/s" : "")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: parts.value).font(.system(size: size, weight: .semibold).monospacedDigit()).kerning(-0.5)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(verbatim: unit).font(unitFont).foregroundStyle(.secondary) }
            }
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Fmt.labeled(name, bytes.map { perSecond ? Fmt.speed($0) : Fmt.bytes($0) } ?? "—")))
    }

    // MARK: 种子：需要处理和其他状态同一种行

    @ViewBuilder private var torrents: some View {
        let problems = tri.unregistered.count + tri.rejected.count + tri.unreachable.count
        LedgerHeader(title: L("Torrents")).padding(.bottom, 2)
        NavigationLink(value: OverviewPage.attention) { row(problems, L("Needs Attention")) }
            .buttonStyle(.plain)
        if tri.localError > 0 {
            InsetSeparator()
            Button { model.showTorrents(.state(.error)) } label: { row(tri.localError, LocalErrorCopy.title, localError: true) }.buttonStyle(.plain)
        }
        InsetSeparator()
        Button { model.showTorrents(.active) } label: { row(tri.active, L("Active")) }.buttonStyle(.plain)
        InsetSeparator()
        Button { model.showTorrents(.state(.downloading)) } label: { row(tri.downloading, L("Downloading")) }.buttonStyle(.plain)
        InsetSeparator()
        Button { model.showTorrents(.state(.seeding)) } label: { row(tri.seeding, L("Seeding fine")) }.buttonStyle(.plain)
        InsetSeparator()
        Button { model.showTorrents(.state(.stopped)) } label: { row(tri.stopped, L("Stopped")) }.buttonStyle(.plain)
    }

    private func row(_ n: Int, _ title: String, localError: Bool = false) -> some View {
        HStack(spacing: 10) {
            if localError { LocalErrorMark.view }
            Text(title).font(.subheadline)
            Spacer(minLength: 6)
            Text(Fmt.count(n)).font(.system(.subheadline, design: .monospaced)).foregroundStyle(n == 0 ? .tertiary : .secondary)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

enum OverviewPage: Hashable { case attention }

/// 需要处理（从总览推进来）：按 tracker 健康度分堆，每堆用服务器原话当标题，左边账本式数字列。
struct AttentionScreen: View {
    let model: AppModel

    private var store: TorrentStore { model.store }
    private var tri: Triage { store.triage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                VStack(alignment: .leading, spacing: 0) { problems }
            }
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .navigationTitle(L("Needs Attention"))
        .navigationBarTitleDisplayMode(.large)
    }

    /// 「3 类 · 刚刚核对过 · 不含 nas-home」
    private var subtitle: String {
        let n = tri.problemKinds
        let checked = model.pendingMessageCount > 0 ? L("Still checking \(Fmt.count(model.pendingMessageCount))") : L("Just checked")
        return ([n > 0 ? L("\(n) kinds") : nil, checked, model.offlineNote].compactMap { $0 }).joined(separator: " · ")
    }

    private var piles: [(Triage.Pile, HealthMark)] {
        [(tri.unregistered, .unregistered), (tri.rejected, .rejected), (tri.unreachable, .timeout)].filter { $0.0.count > 0 }
    }

    /// 问题堆数字列的位数（「已清理」「没有」行的对勾也放在这一列）
    private var digits: Int { ledgerDigits(piles.map(\.0.count)) }

    @ViewBuilder private var problems: some View {
        if let p = model.pending, p.cleanup {
            LedgerRow(digits: digits, alignment: .center) {
                Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Likely unregistered: cleaned up").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(p.keptRefs.isEmpty ? L("Removed \(Fmt.count(p.refs.count))") : L("Removed \(Fmt.count(p.refs.count)), kept \(Fmt.count(p.keptRefs.count)) with cross-seeds"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            if tri.problemKinds > 0 { LedgerSeparator(digits: digits) }
        }
        if tri.problemKinds == 0 && model.pending?.cleanup != true {
            LedgerRow(digits: digits, alignment: .center) {
                Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } content: {
                Text("Nothing").font(.subheadline)
            }
            .padding(.vertical, 10)
        }
        ForEach(Array(piles.enumerated()), id: \.offset) { i, item in
            if i > 0 { LedgerSeparator(digits: digits) }
            pileRow(item.0, item.1)
        }
    }

    private func pileRow(_ p: Triage.Pile, _ mark: HealthMark) -> some View {
        LedgerRow(digits: digits) {
            Text(Fmt.count(p.count)).font(.ledgerLarge).foregroundStyle(mark == .timeout ? .secondary : .primary)
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    mark.view
                    Text(label(mark)).font(.subheadline.weight(.medium)).foregroundStyle(mark == .timeout ? .secondary : .primary)
                    Spacer(minLength: 6)
                    action(mark)
                }
                if !p.topMessage.isEmpty {
                    Text(p.topMessage).font(.quote).foregroundStyle(mark == .timeout ? .secondary : .primary).lineLimit(2)
                }
                Text(meta(p, mark) + (p.otherMessageCount > 0 ? " · " + L("\(p.otherMessageCount) more wordings") : "")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 10)
    }

    private func label(_ m: HealthMark) -> String {
        switch m {
        case .unregistered: L("Likely Unregistered")
        case .rejected: L("Rejected")
        case .timeout: L("Tracker timed out")
        }
    }

    private func meta(_ p: Triage.Pile, _ m: HealthMark) -> String {
        let sites = p.sites.map { model.siteName($0) }.sorted()
        let siteText = sites.count <= 2 ? sites.joined(separator: L(" and ")) : L("\(sites.count) sites")
        switch m {
        case .unregistered:
            return p.crossSeeded > 0 ? L("\(siteText), \(p.crossSeeded) with cross-seeds") : siteText
        case .rejected:
            return siteText
        case .timeout:
            return p.since.map { L("\(siteText), for \(Fmt.duration(Int64(Date().timeIntervalSince1970) - $0))") } ?? siteText
        }
    }

    @ViewBuilder private func action(_ m: HealthMark) -> some View {
        switch m {
        case .unregistered:
            let checking = model.pendingMessageCount > 0
            Button(checking ? L("Checking…") : L("Clean Up")) { model.sheet = .cleanup }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.onInk)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Color.ink.opacity(checking ? 0.3 : 1), in: .capsule)
                .disabled(checking)
        case .rejected:
            Button("View") { model.showTorrents(.rejected) }.font(.subheadline).foregroundStyle(.primary)
        case .timeout:
            Button("Reannounce") {
                let refs = store.all.values.filter { store.rules.isLongUnreachable($0, firstSeen: store.firstSeen($0.ref)) && !store.offlineServers.contains($0.ref.server.rawValue) }.map(\.ref)
                model.perform(.reannounce, on: refs)
                model.showToast(L("Reannounced \(Fmt.torrents(refs.count))"))
            }
            .font(.subheadline).foregroundStyle(.primary)
        }
    }
}

extension AppModel {
    /// 「不含 nas-home」：有下载器离线、它的种子和速度没算进来时的说明
    var offlineNote: String? {
        let names = servers.filter { store.offlineServers.contains($0.id) }.map(\.config.name)
        return names.isEmpty ? nil : L("excluding \(names.joined(separator: L(", ")))")
    }

    /// 跳到「种子」标签并切到某个视图
    func showTorrents(_ item: SidebarItem) {
        store.search = ""
        store.sidebar = item
        selectedTab = "torrents"
    }
}

/// 服务器一行：状态形状、名字、种子数和速度、剩余空间、备用限速开关（总览「一切正常」和「服务器」标签共用）。
/// 种子数不是这里的重点，放进第二行的小字
struct ServerLedgerRow: View {
    let model: AppModel
    let runtime: ServerRuntime
    /// 文字列的左边距（分隔线、故障说明从这里开始）
    static let textInset: CGFloat = 20 + 14 + 12

    var body: some View {
        let rt = runtime
        HStack(spacing: 12) {
            status.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(rt.config.name).font(.subheadline).lineLimit(1)
                    .foregroundStyle(rt.status.isOnline ? .primary : .secondary)
                // 这一行混着中文，等宽字体太宽会被截断；用比例字体 + 等宽数字
                Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if rt.status.isOnline, rt.config.kind.hasAlternativeSpeedLimits {
                Image(systemName: rt.stats.altSpeedEnabled ? "tortoise.fill" : "tortoise").font(.footnote).foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { rt.stats.altSpeedEnabled }, set: { model.setAltSpeed($0, server: rt.id) })) {
                    Text(L("Alternative speed limits for \(rt.config.name)"))
                }
                .labelsHidden()
                .tint(Color.switchOn)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// 实心点 = 在线，插头 = 离线，锁 = 证书待确认（同 iOS 的 ServerRow）
    @ViewBuilder private var status: some View {
        switch runtime.status {
        case .online: Image(systemName: "circle.fill").font(.system(size: 8))
        case .connecting: ProgressView().controlSize(.mini)
        case .stopped: Image(systemName: "pause.circle").font(.footnote).foregroundStyle(.secondary)
        case .failed: Image(systemName: "powerplug.portrait").font(.footnote).foregroundStyle(.secondary)
        case .needsTrust: Image(systemName: "lock.trianglebadge.exclamationmark").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let rt = runtime
        switch rt.status {
        case .online:
            let free = rt.stats.freeSpace.map { "  " + L("\(Fmt.bytes($0)) free") } ?? ""
            let speeds = rt.stats.altSpeedEnabled ? L("limited ") : ""
            let n = model.store.counts.servers[rt.id] ?? 0
            return "\(Fmt.torrents(n)) · \(speeds)↓\(Fmt.compactSpeed(rt.stats.downloadSpeed)) ↑\(Fmt.compactSpeed(rt.stats.uploadSpeed))\(free)"
        case .connecting: return L("Connecting…")
        case .stopped: return L("Off")
        case .failed: return L("Offline")
        case .needsTrust: return L("Certificate needs review")
        }
    }
}
