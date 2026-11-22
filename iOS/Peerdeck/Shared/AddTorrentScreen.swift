import SwiftUI
import TorrentKit
import UniformTypeIdentifiers

/// 添加种子（app 和 Share Extension 共用）。逻辑在 AddDraft 里，和 mac 一样
struct AddTorrentScreen: View {
    let model: AppModel
    @Bindable var draft: AddDraft
    /// Share Extension 里不能再弹出添加服务器
    var allowAddServer = true
    /// 关闭时回调：true 表示已经添加
    var onFinish: ((Bool) -> Void)? = nil
    @State private var importing = false
    @State private var addingServer = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft.text)
                            .font(.callout.monospaced())
                            .frame(minHeight: 90)
                            // 网址键盘：中文输入法下直接打字母会被转成汉字
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if draft.text.isEmpty {
                            Text("One per line: magnet links, torrent download links (passkeys are fine), or drop .torrent files here")
                                .font(.callout).foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack {
                        // 系统的粘贴按钮：用户点了才读剪贴板，不会弹「允许粘贴」的询问
                        PasteButton(payloadType: String.self) { strings in
                            let text = strings.joined(separator: "\n")
                            Task { @MainActor in draft.append(text: text, files: []) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Spacer()
                        Button { importing = true } label: { Label("Choose .torrent Files…", systemImage: "doc.badge.plus") }
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("Download links are fetched and parsed by the app first (without login cookies); failures are handed to the client.")
                }
                if !draft.items.isEmpty {
                    Section {
                        ForEach(draft.items) { itemRow($0) }
                    } footer: {
                        if draft.parsing { Text("Parsing…") }
                        else if draft.badCount > 0 { Text("\(draft.badCount) lines not recognized, will be skipped") }
                    }
                }
                Section {
                    HStack {
                        Picker("Server", selection: Binding(get: { draft.server }, set: { draft.server = $0; draft.serverTouched = true })) {
                            ForEach(model.servers) { rt in
                                Text(rt.config.name + (rt.status.isOnline ? "" : L(" (offline)"))).tag(rt.id)
                            }
                        }
                        if allowAddServer {
                            Button { addingServer = true } label: { Image(systemName: "plus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Add Server…"))
                        }
                    }
                    FormField(L("Save Path"), text: $draft.savePath, prompt: L("Leave empty for the server default"))
                    if !model.prefs.recentPaths.isEmpty {
                        Menu("Recent") { ForEach(model.prefs.recentPaths, id: \.self) { p in Button(p) { draft.savePath = p } } }
                    }
                    if model.server(draft.server)?.config.kind == .qbittorrent {
                        FormField(L("Category"), text: $draft.category, prompt: L("Optional"))
                    }
                    FormField(L("Tags"), text: $draft.tags, prompt: L("Comma-separated"))
                    Toggle("Add paused", isOn: $draft.paused)
                } footer: {
                    if !draft.recommendation.isEmpty { Text(draft.recommendation) }
                }
                if let e = draft.error {
                    Section { Label(e, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled) }
                }
            }
            .navigationTitle("Add Torrents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.validCount > 0 ? "Add \(draft.validCount) Torrents" : "Add") {
                        Task { if await draft.submit() { finish(true) } }
                    }
                    .disabled(draft.validCount == 0 || draft.parsing || draft.busy)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { draft.addFiles(urls) }
            }
            .sheet(isPresented: $addingServer) {
                SetupScreen(model: model) { id in draft.server = id; draft.serverTouched = true }
            }
        }
    }

    private func finish(_ added: Bool) {
        if let onFinish { onFinish(added) } else { dismiss() }
    }

    private func itemRow(_ it: AddItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // v3：类型标记只用墨色描边，认不出的用虚线，不用颜色区分
            Text(tag(it)).font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 38, height: 20)
                .foregroundStyle(isBad(it) ? .secondary : .primary)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: isBad(it) ? [2, 2] : [])).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(it.state == .parsing ? L("Downloading torrent file…") : (it.name.isEmpty ? mask(it.raw) : it.name)).lineLimit(2)
                Text(note(it)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 4)
            if it.state == .parsing { ProgressView() }
            else if it.size > 0 { Text(Fmt.bytes(it.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func tag(_ it: AddItem) -> String {
        if case .bad = it.state { return "?" }
        return it.kind == .magnet ? "MAG" : it.kind == .file ? "TOR" : "URL"
    }

    private func isBad(_ it: AddItem) -> Bool {
        if case .bad = it.state { return true }
        return false
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
}
