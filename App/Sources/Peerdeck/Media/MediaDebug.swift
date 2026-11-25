import SwiftUI
import TorrentKit
#if os(macOS)
import AppKit
#endif

/// 调试：TC_DEBUG_MEDIA_PREVIEW="种子名|种子名|…" 时，用这些名字造几个假种子，把影视卡片排在一个窗口（iOS 是一个弹出面板）里，
/// 不用连服务器就能看匹配结果和卡片样式（数据是真的去查 TMDB）。同时会打开「影视信息」开关（只在这次运行的偏好里）
enum MediaDebug {
    static var names: [String]? {
        ProcessInfo.processInfo.environment["TC_DEBUG_MEDIA_PREVIEW"].map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    static func torrents(_ names: [String]) -> [Torrent] {
        names.enumerated().map { i, name in
            var t = Torrent(ref: TorrentRef(server: ServerID("debug"), id: "media-\(i)"))
            t.name = name
            return t
        }
    }

    #if os(macOS)
    @MainActor private static var panels: [NSPanel] = []

    @MainActor static func installIfNeeded(_ media: MediaLibrary) {
        guard let names else { return }
        // 等偏好加载完再开（加载会整个替换偏好）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            media.enabled = true
            let panel = NSPanel(contentRect: NSRect(x: 120, y: 80, width: 340, height: 900), styleMask: [.titled, .utilityWindow, .resizable], backing: .buffered, defer: false)
            panel.title = "Movie Info (Debug)"
            panel.contentView = NSHostingView(rootView: MediaPreviewList(torrents: torrents(names)).environment(media))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
    #endif
}

struct MediaPreviewList: View {
    let torrents: [Torrent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(torrents) { t in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        MediaCard(torrent: t)
                    }
                    Divider()
                }
            }
            .padding(16)
        }
    }
}
