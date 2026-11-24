import SwiftUI
import TorrentKit

/// 更改保存位置（逻辑同 mac 的 SetLocationSheet）：详情页、长按菜单、多选工具栏都从这里进
struct SetLocationScreen: View {
    let model: AppModel
    let refs: [TorrentRef]
    @State private var path = ""
    @State private var moveFiles = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ctx = model.locationContext(refs)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current") {
                        Text(ctx.commonPath ?? L("Several folders")).font(.data).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    TextField("Save Path", text: $path, prompt: Text(verbatim: "/downloads/…"))
                        .font(.data)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if ctx.canApply(path, moveFiles: moveFiles) { apply() } }
                } header: {
                    if ctx.torrents.count == 1, let t = ctx.torrents.first { Text(t.name).lineLimit(1).truncationMode(.middle) }
                }
                if !model.prefs.recentPaths.isEmpty {
                    Section("Recent") {
                        ForEach(model.prefs.recentPaths, id: \.self) { p in
                            Button { path = p } label: {
                                HStack {
                                    Text(p).font(.data).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if p == path { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Move files too", isOn: $moveFiles)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if moveFiles {
                            Text("The client moves the files on the server.")
                            if ctx.cross > 0 {
                                Label("\(ctx.cross) of them are cross-seeded: after moving files, the other torrents won’t find the data.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Only update the recorded path (for files you already moved).")
                            if ctx.cannotRelocate > 0 {
                                Label("\(ctx.cannotRelocate) will be skipped: their client always moves files when changing the path.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle(ctx.torrents.count == 1 ? L("Set Location") : L("Set Location · \(Fmt.torrents(ctx.torrents.count))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(!ctx.canApply(path, moveFiles: moveFiles))
                }
            }
        }
        .onAppear { path = ctx.initialPath(recent: model.prefs.recentPaths) }
    }

    private func apply() {
        model.move(path, moveFiles: moveFiles, on: refs)
        model.store.selection = []
        dismiss()
    }
}
