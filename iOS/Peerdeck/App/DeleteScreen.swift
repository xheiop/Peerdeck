import SwiftUI
import TorrentKit

/// 删除确认（逻辑同 mac 的 DeleteSheet，v3 样式同清理面板）。清理疑似未注册在 iOS 上走 CleanupScreen
struct DeleteScreen: View {
    let model: AppModel
    let refs: [TorrentRef]
    @State private var keepFiles = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.store
        let all = refs.compactMap { store.torrent($0) }
        let blockers = model.fileCheckBlockers
        let shared = store.sharedWithKept(all)
        let cross = all.filter { shared.contains($0.ref) }
        let size = all.filter { !shared.contains($0.ref) }.reduce(0) { $0 + $1.totalSize }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(all.prefix(5), id: \.ref) { Text($0.name).font(.subheadline).lineLimit(1).truncationMode(.middle) }
                        if all.count > 5 { Text("…and \(Fmt.count(all.count - 5)) more").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 20).padding(.top, 4)
                    if !cross.isEmpty {
                        Text(size > 0 ? L("\(cross.count) of them are cross-seeded; their files will always be kept.")
                             : L("All their files are still used by other torrents, so only the torrents will be deleted, not the files."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.top, 12)
                    }
                    if size > 0, !blockers.isEmpty {
                        Text(L("Files can’t be deleted while \(blockers.joined(separator: L(", "))) is unavailable: its torrents might use the same files."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.top, 12)
                    } else if size > 0 {
                        Toggle(isOn: $keepFiles) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Files").font(.subheadline)
                                Text(keepFiles ? L("Only remove from the client; files on disk stay")
                                     : L("Delete files too (\(Fmt.bytes(size)), can’t be undone; files shared with other torrents are kept)"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color.ink)
                        .padding(.horizontal, 20).padding(.vertical, 12).padding(.top, 12)
                    }
                }
                .padding(.bottom, 16)
            }
            .navigationTitle(L("Delete \(Fmt.torrents(all.count))?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
            .bottomBar {
                VStack(spacing: 8) {
                    Button {
                        let refs = all.map(\.ref)
                        let data: Set<TorrentRef> = !keepFiles && blockers.isEmpty && size > 0 ? Set(all.filter { !shared.contains($0.ref) }.map(\.ref)) : []
                        let what = Fmt.torrents(refs.count)
                        model.scheduleDelete(refs, deleteDataFor: data, label: data.isEmpty ? L("\(what) (keeping files)") : L("\(what) (with files)"))
                        store.selection = []
                        dismiss()
                    } label: {
                        Text("Delete \(Fmt.torrents(all.count))").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .foregroundStyle(Color.onInk)
                    .background(Color.ink.opacity(all.isEmpty ? 0.3 : 1), in: .capsule)
                    .disabled(all.isEmpty)
                    Text("You can undo within 10 seconds").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}
