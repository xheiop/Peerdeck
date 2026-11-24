import SwiftUI
import TorrentKit

/// 种子改名（逻辑同 mac 的 RenameTorrentSheet）：详情页「更多」和长按菜单进来
struct RenameTorrentScreen: View {
    let model: AppModel
    let ref: TorrentRef
    @State private var name = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let notes = model.renameNotes(ref, newName: name)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { if model.canRename(ref, to: name) { apply() } }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notes.info)
                        if let warning = notes.warning {
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(L("Rename Torrent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") { apply() }.disabled(!model.canRename(ref, to: name))
                }
            }
        }
        .onAppear {
            name = model.store.torrent(ref)?.name ?? ""
            focused = true
        }
    }

    private func apply() {
        model.renameTorrent(ref, to: name)
        dismiss()
    }
}
