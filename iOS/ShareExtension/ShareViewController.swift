import SwiftUI
import TorrentKit
import UIKit
import UniformTypeIdentifiers

/// 分享扩展：从 Safari、「文件」或别的 app 把 magnet、种子链接、.torrent 交给 Peerdeck。
/// 服务器配置从共享的 Keychain 组读；只连接服务器，不拉种子列表（扩展有内存上限）
final class ShareViewController: UIViewController {
    private let model = AppModel(configStore: KeychainConfigStore(), lightweight: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        model.load()
        Task { @MainActor in
            let (text, files) = await collect()
            let draft = AddDraft(model: model, text: text, files: files)
            let root = AddTorrentScreen(model: model, draft: draft, allowAddServer: false) { [weak self] added in
                self?.finish(added)
            }
            .tint(Color.ink)
            let host = UIHostingController(rootView: root)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    private func finish(_ added: Bool) {
        model.servers.forEach { $0.stop() }
        if added {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }

    /// 从分享内容里取出链接文本和 .torrent 文件。文件先拷到临时目录：附件的 URL 只在回调里有效
    private func collect() async -> (String, [URL]) {
        var lines: [String] = []
        var files: [URL] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let torrent = UTType(filenameExtension: "torrent") ?? .data
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(torrent.identifier) || p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await copyFile(p, type: p.hasItemConformingToTypeIdentifier(torrent.identifier) ? torrent : .fileURL), url.pathExtension.lowercased() == "torrent" {
                    files.append(url)
                    continue
                }
            }
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                lines.append(url.absoluteString)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                lines.append(s)
            }
        }
        return (lines.joined(separator: "\n"), files)
    }

    private func copyFile(_ p: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(for: type) { url, _, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
                cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)).map { dest })
            }
        }
    }
}
