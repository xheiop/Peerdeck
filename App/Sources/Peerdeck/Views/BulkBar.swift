import SwiftUI
import TorrentKit

/// 多选时浮在表格底部的操作条
struct BulkBar: View {
    let model: AppModel
    @State private var tagsText = ""
    @State private var tagMode: TagMode = .add
    @State private var limitKB = "1024"
    @State private var newCategory = ""
    @State private var pop: String?

    private var refs: [TorrentRef] { Array(model.store.selection) }

    var body: some View {
        let sel = refs.compactMap { model.store.torrent($0) }
        HStack(spacing: 10) {
            Text("\(Fmt.count(sel.count)) selected").fontWeight(.semibold).monospacedDigit()
            Text("· " + Fmt.bytes(sel.reduce(0) { $0 + $1.totalSize })).foregroundStyle(.secondary).padding(.leading, -6)
            Button { model.toggleRun(refs) } label: {
                sel.allSatisfy { $0.state == .stopped } ? Label("Start", systemImage: "play.fill") : Label("Stop", systemImage: "pause.fill")
            }
            Divider().frame(height: 16)
            Menu {
                let cats = model.store.categories
                let noCategory = sel.filter { model.server($0.ref.server.rawValue)?.config.kind != .qbittorrent }.count
                if noCategory > 0 { Text("\(noCategory) torrents will be skipped (only qBittorrent has categories)") }
                ForEach(cats, id: \.self) { c in Button(c) { model.setCategory(c, on: refs) } }
                Divider()
                Button("New Category…") { pop = "cat" }
                Button("Clear Category") { model.setCategory("", on: refs) }
            } label: { Label("Category", systemImage: "square.grid.2x2") }
                .menuStyle(.borderlessButton).fixedSize()
                .popover(isPresented: binding("cat"), arrowEdge: .top) {
                    form(L("New Category")) {
                        TextField("Category name", text: $newCategory).frame(width: 200)
                    } apply: { model.setCategory(newCategory, on: refs) }
                }
            Button { pop = "tags" } label: { Label("Tags", systemImage: "tag") }
                .popover(isPresented: binding("tags"), arrowEdge: .top) {
                    form(L("Tags · \(Fmt.torrents(sel.count))")) {
                        TextField("Comma-separated, e.g. keep, 4k", text: $tagsText).frame(width: 240)
                        Picker("", selection: $tagMode) {
                            Text("Add").tag(TagMode.add)
                            Text("Remove").tag(TagMode.remove)
                            Text("Replace").tag(TagMode.replace)
                        }.pickerStyle(.segmented).labelsHidden()
                    } apply: {
                        model.updateTags(tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, mode: tagMode, on: refs)
                    }
                }
            Button { pop = "limit" } label: { Label("Upload Limit", systemImage: "arrow.up.to.line") }
                .popover(isPresented: binding("limit"), arrowEdge: .top) {
                    form(L("Upload Limit · \(Fmt.torrents(sel.count))")) {
                        HStack { TextField("", text: $limitKB).frame(width: 90); Text("KB/s per torrent") }
                        Button("Unlimited") { model.setUploadLimit(0, on: refs); pop = nil }
                        let noLimit = sel.filter { model.server($0.ref.server.rawValue)?.config.kind.hasTorrentUploadLimit == false }.count
                        if noLimit > 0 {
                            Text("\(noLimit) on Flood will be skipped (no per-torrent limits)").font(.caption).foregroundStyle(.secondary)
                        }
                    } apply: { model.setUploadLimit((Int64(limitKB) ?? 0) * 1024, on: refs) }
                }
            Button { model.requestSetLocation(refs) } label: { Label("Set Location", systemImage: "folder") }
            Button {
                let site = sel.first.map { model.store.siteID(of: $0) }
                model.sheet = .retracker(RetrackerDraft(model: model, siteID: site, selection: refs, scope: .selection))
            } label: { Label("Replace Tracker", systemImage: "arrow.left.arrow.right") }
            Divider().frame(height: 16)
            Button(role: .destructive) { model.requestDelete(refs) } label: { Label("Delete", systemImage: "trash") }
            Button { model.store.selection = [] } label: { Image(systemName: "xmark") }.help("Deselect (Esc)")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator))
        .shadow(radius: 10, y: 3)
        .fixedSize()
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { pop == key }, set: { if !$0, pop == key { pop = nil } })
    }

    private func form<C: View>(_ title: String, @ViewBuilder _ content: () -> C, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            // popover 里默认按钮接不到回车，在输入框上直接提交
            content().onSubmit { apply(); pop = nil }
            HStack {
                Spacer()
                Button("Cancel") { pop = nil }
                Button("Apply") { apply(); pop = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
