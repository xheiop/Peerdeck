import SwiftUI
import TorrentKit

/// 表格上方的横幅区：载入中、服务器故障、证书待确认、站点汇总、能力说明、清理条
struct BannersView: View {
    let model: AppModel
    private var store: TorrentStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.servers) { rt in
                if rt.status.isOnline, !rt.loaded {
                    Bar(tint: .secondary) {
                        ProgressView().controlSize(.small)
                        Text("Loading torrents from \(rt.config.name)…").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if case .failed(let msg) = rt.status {
                    Bar(tint: .red) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(rt.config.name) can’t connect").fontWeight(.semibold)
                            Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Retry") { rt.start() }
                        Button("Edit Server…") { openSettings(rt.id) }
                    }
                }
                if case .needsTrust(let ep, let fp) = rt.status {
                    Bar(tint: .orange) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(rt.config.name): the certificate of \(ep.baseURL.absoluteString) isn’t trusted by the system")
                            Text("SHA256 \(fp)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Trust This Certificate") { model.trust(serverID: rt.id, endpoint: ep, fingerprint: fp) }
                    }
                }
            }

            if case .site = store.sidebar, let s = store.siteSummary { SiteSummaryBar(model: model, summary: s) }

            if store.sidebar.isProblemView, store.counts.noHealth > 0 {
                Bar(tint: .secondary) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    if store.noHealthServers.contains(where: { model.server($0)?.config.kind == .flood }) {
                        Text("\(noHealthNames): tracker status isn’t reliable here, so \(Fmt.torrents(store.counts.noHealth)) aren’t listed. Behind Flood, connect to the client directly; qBittorrent 5.1.x needs 5.2 or later.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(noHealthNames) doesn’t report tracker status (qBittorrent 5.1.x), so its \(Fmt.torrents(store.counts.noHealth)) aren’t listed here. Upgrade to 5.2 or later.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // qB 的报错原文是后台逐个补查的，查完之前「疑似未注册」会继续增加
            if store.sidebar == .rejected || store.sidebar == .unregistered, model.pendingMessageCount > 0 {
                Bar(tint: .secondary) {
                    ProgressView().controlSize(.small)
                    Text("Checking tracker messages for \(Fmt.torrents(model.pendingMessageCount))… “Likely Unregistered” may still grow.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if store.sidebar == .unregistered, store.visibleCount > 0 {
                Bar(tint: .accentColor) {
                    Image(systemName: "xmark.seal").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Fmt.torrents(store.visibleCount)) reported as unregistered by the tracker").fontWeight(.semibold)
                        Text(L("\(byServer(store.order)) · usually deleted by the site or replaced (dupe)")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clean Up…") { model.requestDelete(store.order, cleanup: true) }.buttonStyle(.borderedProminent)
                }
            }

            if store.sidebar == .unreachable, store.visibleCount > 0 {
                Bar(tint: .orange) {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unreachable trackers are usually temporary; deleting isn’t recommended").fontWeight(.semibold)
                        Text(topSites(store.order)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reannounce All") {
                        model.perform(.reannounce, on: store.order)
                        model.showToast(L("Reannounced \(Fmt.torrents(store.order.count))"))
                    }
                }
            }
        }
    }

    private var noHealthNames: String {
        store.noHealthServers.compactMap { model.server($0)?.config.name }.sorted().joined(separator: L(", "))
    }

    private func openSettings(_ id: String) {
        model.settingsTab = "servers"
        model.settingsServerFocus = id
        model.openSettingsWindow?()
    }

    private func byServer(_ refs: [TorrentRef]) -> String {
        Fmt.breakdown(Dictionary(grouping: refs, by: \.server).map { (model.server($0.key.rawValue)?.config.name ?? $0.key.rawValue, $0.value.count) })
    }

    private func topSites(_ refs: [TorrentRef]) -> String {
        var c: [String: Int] = [:]
        for r in refs { if let t = store.torrent(r) { c[store.siteID(of: t), default: 0] += 1 } }
        return Fmt.breakdown(c.sorted { $0.value > $1.value }.prefix(3).map { (model.siteName($0.key), $0.value) })
    }
}

/// 一条横幅
struct Bar<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.07))
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// 站点视图顶部的收益汇总
struct SiteSummaryBar: View {
    let model: AppModel
    let summary: SiteSummary

    var body: some View {
        let s = summary
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.siteName(s.siteID)).font(.title3.weight(.semibold))
                Text(hostsLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(Fmt.breakdown(s.byServer.map { (model.server($0.key)?.config.name ?? $0.key, $0.value) }))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            metric(L("Seeding"), "\(Fmt.count(s.seeding)) / \(Fmt.count(s.total))")
            metric(L("Total Size"), Fmt.bytes(s.size))
            metric(L("Total Uploaded"), Fmt.bytes(s.uploaded))
            metric(L("Overall Ratio"), s.size > 0 ? Fmt.ratio(Double(s.uploaded) / Double(s.size)) : "—")
            metric(L("Uploading Now"), s.uploadSpeed > 0 ? Fmt.speed(s.uploadSpeed) : L("Idle"))
            VStack(alignment: .leading, spacing: 1) {
                Text("Needs Attention").font(.caption2).foregroundStyle(.secondary)
                if s.problems > 0 {
                    Button("\(Fmt.count(s.problems)) ›") { model.store.sidebar = .rejected }.buttonStyle(.link).font(.headline)
                } else {
                    Text("0").font(.headline)
                }
            }
            Spacer()
            Button("Replace Tracker…") {
                model.sheet = .retracker(RetrackerDraft(model: model, siteID: s.siteID, selection: Array(model.store.selection), scope: .site))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var hostsLine: String {
        let site = model.site(summary.siteID)
        let current = summary.hosts.joined(separator: L(", "))
        let old = (site?.hosts ?? []).filter { !summary.hosts.contains($0) }.joined(separator: L(", "))
        return old.isEmpty ? current : L("\(current) (formerly \(old))")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }
}
