import SwiftUI
import TorrentKit

/// 更改保存位置：右键菜单和多选操作条都从这里进
struct SetLocationSheet: View {
    let model: AppModel
    let refs: [TorrentRef]
    @State private var path = ""
    @State private var moveFiles = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ctx = model.locationContext(refs)
        VStack(alignment: .leading, spacing: 12) {
            Text(ctx.torrents.count == 1 ? L("Set Location") : L("Set Location · \(Fmt.torrents(ctx.torrents.count))"))
                .font(.title3.weight(.semibold))
            if ctx.torrents.count == 1, let t = ctx.torrents.first {
                Text(t.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Current").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(ctx.commonPath ?? L("Several folders")).font(.body.monospaced())
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                GridRow {
                    Text("New Path").foregroundStyle(.secondary)
                    HStack {
                        TextField("Save Path", text: $path).font(.body.monospaced())
                            .onSubmit { if ctx.canApply(path, moveFiles: moveFiles) { apply() } }
                        if !model.prefs.recentPaths.isEmpty {
                            Menu("Recent") { ForEach(model.prefs.recentPaths, id: \.self) { p in Button(p) { path = p } } }.fixedSize()
                        }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Move files too", isOn: $moveFiles)
                }
            }
            Group {
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
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ctx.canApply(path, moveFiles: moveFiles))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { path = ctx.initialPath(recent: model.prefs.recentPaths) }
    }

    private func apply() {
        model.move(path, moveFiles: moveFiles, on: refs)
        dismiss()
    }
}
