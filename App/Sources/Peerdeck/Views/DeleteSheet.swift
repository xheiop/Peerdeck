import SwiftUI
import TorrentKit

/// 删除确认。cleanup=true 是「清理未注册」：按站点和服务器列出分布，默认排除辅种
struct DeleteSheet: View {
    let model: AppModel
    let refs: [TorrentRef]
    let cleanup: Bool
    @State private var includeCross = false
    @State private var deleteFiles = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.store
        let all = refs.compactMap { store.torrent($0) }
        let shared = store.sharedWithKept(all)
        let cross = all.filter { shared.contains($0.ref) }
        let targets = cleanup && !includeCross ? all.filter { !shared.contains($0.ref) } : all
        let size = targets.filter { !shared.contains($0.ref) }.reduce(0) { $0 + $1.totalSize }
        VStack(alignment: .leading, spacing: 14) {
            if cleanup {
                Text("Clean Up Unregistered Torrents").font(.title3.weight(.semibold))
                Text("These torrents were deleted or replaced by their sites. Seeding them no longer counts toward your upload.").foregroundStyle(.secondary)
                if targets.isEmpty {
                    // 全是辅种时分布表是空的，直接说明原因
                    Text("Nothing to clean up: these are all cross-seeds whose data is still used by other torrents. Tick the option below to delete them anyway.").font(.callout)
                } else {
                    breakdown(targets)
                }
                if model.pendingMessageCount > 0 {
                    Label("Still checking tracker messages for \(Fmt.torrents(model.pendingMessageCount)), so more unregistered torrents may turn up. You can run the cleanup again afterwards.", systemImage: "hourglass")
                        .font(.callout)
                        .labelStyle(TintedIconLabel(color: .orange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $includeCross) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also delete cross-seeds (\(Fmt.count(cross.count)))")
                        Text("Their data is also used by torrents outside this cleanup (same infohash, or same name and size). Kept by default: they can keep seeding on other sites.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            } else {
                Text("Delete \(Fmt.torrents(all.count))?").font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(all.prefix(3), id: \.ref) { Text($0.name).lineLimit(1).truncationMode(.middle) }
                    if all.count > 3 { Text("…and \(Fmt.count(all.count - 3)) more").foregroundStyle(.secondary) }
                }
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                // 全是辅种时下面会单独说明，这里不重复
                if !cross.isEmpty && size > 0 { Text("\(cross.count) of them are cross-seeded; their files will always be kept.").font(.callout).foregroundStyle(.secondary) }
            }
            if size > 0 {
                Picker("", selection: $deleteFiles) {
                    Text("Delete torrents only, keep files").tag(false)
                    Text("Delete files too (\(Fmt.bytes(size)), can’t be undone; files shared with other torrents are kept)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } else if !targets.isEmpty {
                // 全是辅种时没有能删的文件，不给一个「删除 0 字节」的选项
                Text("All their files are still used by other torrents, so only the torrents will be deleted, not the files.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("You can undo for 10 seconds").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete \(Fmt.torrents(targets.count))", role: .destructive) {
                    let refs = targets.map(\.ref)
                    let data = deleteFiles && size > 0 ? Set(targets.filter { !shared.contains($0.ref) }.map(\.ref)) : []
                    let what = !cleanup ? Fmt.torrents(refs.count) : refs.count == 1 ? L("1 unregistered torrent") : L("\(Fmt.count(refs.count)) unregistered torrents")
                    model.scheduleDelete(refs, deleteDataFor: data, label: data.isEmpty ? L("\(what) (keeping files)") : L("\(what) (with files)"))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func breakdown(_ ts: [Torrent]) -> some View {
        let store = model.store
        let servers = Array(Set(ts.map(\.ref.server.rawValue))).sorted()
        var bySite: [String: [String: Int]] = [:]
        for t in ts { bySite[store.siteID(of: t), default: [:]][t.ref.server.rawValue, default: 0] += 1 }
        let rows = bySite.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
        return Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Site").gridColumnAlignment(.leading)
                ForEach(servers, id: \.self) { Text(model.server($0)?.config.name ?? $0) }
                Text("Total")
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(rows.prefix(6), id: \.key) { site, counts in
                GridRow {
                    Text(model.siteName(site))
                    ForEach(servers, id: \.self) { s in Text(counts[s].map(Fmt.count) ?? "—") }
                    Text(Fmt.count(counts.values.reduce(0, +)))
                }
            }
            if rows.count > 6 {
                GridRow {
                    Text("\(rows.count - 6) other sites").foregroundStyle(.secondary)
                    ForEach(servers, id: \.self) { _ in Text("") }
                    Text(Fmt.count(rows.dropFirst(6).reduce(0) { $0 + $1.value.values.reduce(0, +) }))
                }
            }
        }
        .monospacedDigit()
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).stroke(.separator))
    }
}
