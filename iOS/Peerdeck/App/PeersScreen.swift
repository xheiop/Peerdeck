import SwiftUI
import TorrentKit

/// 种子当前连着的对端。打开时轮询，返回上一页就停（逻辑在 PeerFeed，和 mac 详情面板共用）
struct PeersScreen: View {
    let model: AppModel
    let torrent: Torrent
    @State private var feed: PeerFeed

    init(model: AppModel, torrent: Torrent) {
        self.model = model
        self.torrent = torrent
        _feed = State(initialValue: PeerFeed(ref: torrent.ref))
    }

    var body: some View {
        Group {
            if let peers = feed.peers {
                if peers.isEmpty {
                    ContentUnavailableView(torrent.state == .stopped ? L("The torrent is stopped, so no peers are connected.") : L("No peers connected right now."),
                                           systemImage: "person.2.slash")
                } else {
                    list(peers)
                }
            } else if let error = feed.error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(feed.peers.map { L("Peers (\(Fmt.count($0.count)))") } ?? L("Peers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await feed.run(model) }
    }

    private func list(_ peers: [Peer]) -> some View {
        List {
            Section {
                ForEach(Array(peers.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.clientLabel).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 8)
                            if !p.flags.isEmpty { Text(verbatim: p.flags).font(.data).foregroundStyle(.secondary) }
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: [p.countryCode, p.endpoint].compactMap { $0 }.joined(separator: " "))
                                .font(.data).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(verbatim: p.statusLine).font(.data).monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                let total = feed.totals
                Text(verbatim: "↓ \(Fmt.speed(total.down)) · ↑ \(Fmt.speed(total.up))").monospacedDigit()
            }
        }
        .listStyle(.plain)
    }
}
