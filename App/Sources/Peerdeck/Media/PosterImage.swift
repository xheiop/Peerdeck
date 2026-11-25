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

/// 要放大看的海报：小图（详情里已经缓存的 w185）和原图
struct PosterZoom: Identifiable {
    let thumb: URL?
    let full: URL
    var id: URL { full }
}

/// 点海报看大图。先显示已缓存的小图，原图下好后换上；原图下不来就一直显示小图
struct PosterViewer: View {
    let poster: PosterZoom
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var loading = true

    var body: some View {
        content
            .task(id: poster.id) {
                image = PosterCache.shared.cached(poster.full) ?? poster.thumb.flatMap { PosterCache.shared.cached($0) }
                if let big = await PosterCache.shared.image(poster.full) { image = big }
                loading = false
            }
    }

    #if os(macOS)
    private var content: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            }
            if loading {
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: image == nil ? .center : .bottomTrailing)
                    .padding(10)
            }
        }
        .frame(width: 420, height: 630)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(Text("Close"))
            .padding(8)
        }
    }
    #else
    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImage(image: image) { dismiss() }
            }
            if loading {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: image == nil ? .center : .bottom)
                    .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .accessibilityLabel(Text("Close"))
            .padding(.trailing, 16).padding(.top, 8)
        }
        .statusBarHidden()
    }
    #endif
}

#if os(iOS)
/// 双指缩放、双击放大 / 还原、放大后拖动；没放大时往下拖关闭
private struct ZoomableImage: View {
    let image: UIImage
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: g.size.width, height: g.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .opacity(scale > 1 ? 1 : dragFade)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = min(max(baseScale * $0.magnification, 1), maxScale) }
                        .onEnded { _ in
                            baseScale = scale
                            withAnimation(.snappy) { offset = clamped(offset, in: g.size) }
                            baseOffset = offset
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            if scale > 1 {
                                offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height)
                            } else {
                                offset = CGSize(width: 0, height: max(v.translation.height, 0))
                            }
                        }
                        .onEnded { v in
                            if scale > 1 {
                                withAnimation(.snappy) { offset = clamped(offset, in: g.size) }
                                baseOffset = offset
                            } else if v.translation.height > 120 || v.predictedEndTranslation.height > 300 {
                                onDismiss()
                            } else {
                                withAnimation(.snappy) { offset = .zero }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                    }
                    baseScale = scale
                    baseOffset = offset
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Poster"))
                .accessibilityAddTraits(.isImage)
        }
        .ignoresSafeArea()
    }

    /// 没放大时往下拖，越拖越淡（最多淡到 0.6）
    private var dragFade: Double {
        let pulled = Double(max(offset.height, 0))
        return 1 - min(pulled / 600, 0.4)
    }

    /// 放大后不让图片拖出屏幕：每边最多移出放大多出来的一半
    private func clamped(_ o: CGSize, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let fit = fittedSize(in: size)
        let maxX = max((fit.width * scale - size.width) / 2, 0)
        let maxY = max((fit.height * scale - size.height) / 2, 0)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return size }
        let r = min(size.width / w, size.height / h)
        return CGSize(width: w * r, height: h * r)
    }
}
#endif
