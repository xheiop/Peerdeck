import SwiftUI
import TorrentKit

/// 种子改名：右键菜单和详情面板都从这里进
struct RenameTorrentSheet: View {
    let model: AppModel
    let ref: TorrentRef
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let notes = model.renameNotes(ref, newName: name)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Torrent").font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .onSubmit { if model.canRename(ref, to: name) { apply() } }
            Group {
                Text(notes.info).foregroundStyle(.secondary)
                if let warning = notes.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canRename(ref, to: name))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { name = model.store.torrent(ref)?.name ?? "" }
    }

    private func apply() {
        model.renameTorrent(ref, to: name)
        dismiss()
    }
}
