import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// 海报缓存：独立的 URLCache（磁盘 100 MB，放在 Caches 目录，系统空间紧张时可以清掉）加一层内存缓存
final class PosterCache: @unchecked Sendable {
    static let shared = PosterCache()

    let session: URLSession
    private let urlCache: URLCache
    private let memory = NSCache<NSURL, PlatformImage>()

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Peerdeck/posters", directoryHint: .isDirectory)
        urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 100 << 20, directory: dir)
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.countLimit = 200
    }

    func cached(_ url: URL) -> PlatformImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> PlatformImage? {
        if let img = cached(url) { return img }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200, let img = PlatformImage(data: data) else { return nil }
        memory.setObject(img, forKey: url as NSURL)
        return img
    }

    func clear() {
        urlCache.removeAllCachedResponses()
        memory.removeAllObjects()
    }
}

/// 2:3 的海报，加载中和没有海报时显示灰色占位
struct PosterImage: View {
    let url: URL?
    var width: CGFloat = 72
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFill()
                #else
                Image(uiImage: image).resizable().scaledToFill()
                #endif
            } else if url == nil {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: url) {
            image = url.flatMap { PosterCache.shared.cached($0) }
            if image == nil, let url { image = await PosterCache.shared.image(url) }
        }
    }
}
