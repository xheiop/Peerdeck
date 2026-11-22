import AppKit
import SwiftUI
import TorrentKit
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    let model: AppModel
    @Bindable var draft: AddDraft
    @State private var importing = false
    @State private var clipboard: String?
    @State private var addingServer = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Torrents").font(.title3.weight(.semibold))
            if let clip = clipboard, draft.text.isEmpty {
                HStack {
                    Text("The clipboard has \(clip.split(whereSeparator: \.isNewline).count) links")
                    Spacer()
                    Button("Paste") { draft.text = clip; clipboard = nil }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .font(.callout)
                .padding(8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            // NSTextView 的文字左边自带 5pt 行片段内边距，占位文字要对上光标位置
            TextEditor(text: $draft.text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(.vertical, 7)
                .padding(.horizontal, 4)
                .frame(height: 84)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("One per line: magnet links, torrent download links (passkeys are fine), or drop .torrent files here")
                            .font(.callout).foregroundStyle(.tertiary)
                            .padding(.top, 7).padding(.leading, 9).padding(.trailing, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url, url.pathExtension.lowercased() == "torrent" { Task { @MainActor in draft.addFiles([url]) } }
                        }
                    }
                    return true
                }
            HStack(spacing: 12) {
                Button { importing = true } label: { Label("Choose .torrent Files…", systemImage: "doc.badge.plus") }
                    .controlSize(.large)
                Text("Download links are fetched and parsed by the app first (without login cookies); failures are handed to the client.").font(.caption).foregroundStyle(.secondary)
            }
            if !draft.items.isEmpty { itemList }
            // 不用 grouped Form：它要固定高度，推荐语一出现就会把最后一行挤出去。
            // 也不用 Grid：实测里面的输入框不会撑满宽度
            VStack(alignment: .leading, spacing: 10) {
                field(L("Server")) {
                    HStack(spacing: 10) {
                        Picker("Server", selection: Binding(get: { draft.server }, set: { draft.server = $0; draft.serverTouched = true })) {
                            ForEach(model.servers) { rt in
                                Text(rt.config.name + (rt.status.isOnline ? "" : L(" (offline)"))).tag(rt.id).disabled(!rt.status.isOnline)
                            }
                        }
                        .labelsHidden().fixedSize()
                        Button { addingServer = true } label: { Image(systemName: "plus") }
                            .help("Add Server…")
                            .accessibilityLabel(Text("Add Server…"))
                        if !draft.recommendation.isEmpty {
                            Text(draft.recommendation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                field(L("Save Path")) {
                    HStack {
                        TextField("Save Path", text: $draft.savePath, prompt: Text("Leave empty for the server default")).labelsHidden()
                        if !model.prefs.recentPaths.isEmpty {
                            Menu("Recent") { ForEach(model.prefs.recentPaths, id: \.self) { p in Button(p) { draft.savePath = p } } }.fixedSize()
                        }
                    }
                }
                if model.server(draft.server)?.config.kind == .qbittorrent {
                    field(L("Category")) { TextField(L("Category"), text: $draft.category, prompt: Text(L("Optional"))).labelsHidden() }
                }
                field(L("Tags")) { TextField(L("Tags"), text: $draft.tags, prompt: Text(L("Comma-separated"))).labelsHidden() }
                field("") { Toggle("Add paused", isOn: $draft.paused).toggleStyle(.checkbox) }
            }
            .padding(.top, 4)
            if let e = draft.error { Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Text(draft.parsing ? "Parsing…" : draft.badCount > 0 ? "\(draft.badCount) lines not recognized, will be skipped" : "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.validCount > 0 ? "Add \(draft.validCount) Torrents" : "Add") {
                    Task { if await draft.submit() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validCount == 0 || draft.parsing || draft.busy)
            }
        }
        .padding(20)
        .frame(width: 600)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { draft.addFiles(urls) }
        }
        .onAppear { readClipboard() }
        .sheet(isPresented: $addingServer) {
            SetupSheet(model: model) { id in draft.server = id; draft.serverTouched = true }
        }
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var itemList: some View {
        // 种子少时按内容高度显示，多了才滚动
        ViewThatFits(in: .vertical) {
            itemRows
            ScrollView { itemRows }
        }
        .frame(maxHeight: 190)
        .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    private var itemRows: some View {
        VStack(spacing: 0) {
                ForEach(draft.items) { it in
                    HStack(alignment: .top, spacing: 10) {
                        Text(tag(it)).font(.system(size: 9, weight: .bold)).frame(width: 36, height: 20)
                            .background(tint(it).opacity(0.15), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(tint(it))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.state == .parsing ? L("Downloading torrent file…") : (it.name.isEmpty ? mask(it.raw) : it.name)).lineLimit(2)
                            Text(note(it)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        if it.state == .parsing { ProgressView().controlSize(.small) }
                        else if it.size > 0 { Text(Fmt.bytes(it.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    if it.id != draft.items.last?.id { Divider() }
                }
            }
    }

    private func tag(_ it: AddItem) -> String {
        switch it.state {
        case .bad: "?"
        default: it.kind == .magnet ? "MAG" : it.kind == .file ? "TOR" : "URL"
        }
    }

    private func tint(_ it: AddItem) -> Color {
        switch it.state {
        case .bad: .red
        case .fallback: .orange
        default: .accentColor
        }
    }

    private func note(_ it: AddItem) -> String {
        switch it.state {
        case .parsing: return mask(it.raw)
        case .bad(let m): return m
        case .fallback(let m): return m
        case .ok:
            if it.kind == .magnet { return L("The client fetches metadata; files appear after adding") }
            var parts = [it.files.count == 1 ? L("1 file") : L("\(it.files.count) files")]
            if !it.host.isEmpty { parts.append(model.siteName(model.store.hostToSite[it.host] ?? it.host)) }
            if it.isPrivate { parts.append(L("Private")) }
            return parts.joined(separator: " · ")
        }
    }

    private func mask(_ s: String) -> String {
        guard let pk = RetrackerDraft.passkey(s) else { return s }
        return s.replacingOccurrences(of: pk, with: "•••")
    }

    private func readClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("magnet:?") || $0.lowercased().hasPrefix("http") }
        if !lines.isEmpty { clipboard = lines.joined(separator: "\n") }
    }
}
