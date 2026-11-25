import MediaKit
import SwiftUI
import TorrentKit

/// 种子详情里的影视卡片：海报、片名年份、类型、评分、简介、TMDB / IMDb / 豆瓣链接。
/// mac 详情栏和 iOS 详情页共用；没开、没密钥、不像影视时什么都不显示
struct MediaCard: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.openURL) private var openURL
    let torrent: Torrent
    @State private var expanded = false
    @State private var matching = false
    @State private var zoom: PosterZoom?

    var body: some View {
        Group {
            if let state = media.state(for: torrent) {
                switch state {
                case .notVideo: EmptyView()
                case .loading: loading
                case .notFound: notFound
                case .failed(let msg): failed(msg)
                case .found(let entry): card(entry)
                }
            } else if media.isActive {
                loading
            }
        }
        .task(id: media.isActive ? media.signature(of: torrent) : "") {
            guard media.isActive else { return }
            // mac 上用方向键快速切换选中项时，停下来再查
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await media.load(torrent)
            // 调试：TC_DEBUG_POSTER=1 时匹配到就打开大图（截图用）
            if MediaDebug.openPoster, case .found(let e)? = media.state(for: torrent) {
                let path = e.season.flatMap { e.details.season($0) }?.posterPath ?? e.details.posterPath
                if let full = TMDBImage.url(path, size: "original") { zoom = PosterZoom(thumb: TMDBImage.url(path, size: "w185"), full: full) }
            }
        }
        .sheet(isPresented: $matching) {
            MediaMatchSheet(torrent: torrent)
        }
        #if os(macOS)
        .sheet(item: $zoom) { PosterViewer(poster: $0) }
        #else
        .fullScreenCover(item: $zoom) { PosterViewer(poster: $0) }
        #endif
    }

    private var loading: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: nil)
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking up on TMDB…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notFound: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(.tertiary)
            Text("No movie or TV show found").foregroundStyle(.secondary)
            Spacer()
            Button("Match…") { matching = true }
        }
        .font(.callout)
    }

    private func failed(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t load movie info").foregroundStyle(.secondary)
                Text(msg).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            Button("Retry") { Task { await media.retry(torrent) } }
        }
        .font(.callout)
    }

    private func card(_ e: MediaLibrary.Entry) -> some View {
        let d = e.details
        let season = e.season.flatMap { d.season($0) }
        return HStack(alignment: .top, spacing: 12) {
            poster(season?.posterPath ?? d.posterPath)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    (Text(d.title).font(.headline) + Text(verbatim: d.year.map { "  \($0)" } ?? "").foregroundStyle(.secondary))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    menu(e)
                }
                if d.originalTitle != d.title, !d.originalTitle.isEmpty {
                    Text(d.originalTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(facts(d, season: season)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if d.voteCount > 0 {
                    Text("★ \(d.voteAverage, format: .number.precision(.fractionLength(1)))").font(.caption.weight(.medium))
                        + Text(verbatim: "  TMDB").font(.caption2).foregroundStyle(.tertiary)
                }
                if !d.overview.isEmpty {
                    Text(d.overview)
                        .font(.callout)
                        .lineLimit(expanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                        .accessibilityAddTraits(.isButton)
                }
                if !e.confident {
                    HStack(spacing: 8) {
                        Text("Not sure this is the right one.").font(.caption).foregroundStyle(.secondary)
                        Button("Correct") { Task { await media.setMatch(torrent, kind: d.kind, id: d.id) } }
                        Button("Change…") { matching = true }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                links(d).padding(.top, 2)
            }
        }
    }

    /// 有海报时可以点开看大图
    @ViewBuilder private func poster(_ path: String?) -> some View {
        let thumb = TMDBImage.url(path, size: "w185")
        if let full = TMDBImage.url(path, size: "original") {
            Button { zoom = PosterZoom(thumb: thumb, full: full) } label: { PosterImage(url: thumb) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("View Poster"))
                #if os(macOS)
                .help(Text("View Poster"))
                #endif
        } else {
            PosterImage(url: thumb)
        }
    }

    private func facts(_ d: TMDBDetails, season: TMDBDetails.Season?) -> String {
        var parts: [String] = [d.kind == .movie ? L("Movie") : L("TV Show")]
        // 只有一季的剧，TMDB 的季名常常就是剧名
        if let season, !season.name.isEmpty, season.name != d.title { parts.append(season.name) }
        parts += d.genres.prefix(2)
        if let m = d.runtime { parts.append(Duration.seconds(m * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) }
        return parts.joined(separator: " · ")
    }

    private func links(_ d: TMDBDetails) -> some View {
        HStack(spacing: 12) {
            Link("TMDB", destination: d.tmdbURL)
            if let imdb = d.imdbURL { Link("IMDb", destination: imdb) }
            if MediaLibrary.isChineseUI, let search = d.doubanURL { doubanLink(d, fallback: search) }
        }
        .font(.caption)
        .task(id: d.imdbID) {
            guard MediaLibrary.isChineseUI, let imdb = d.imdbID else { return }
            await media.loadDouban(imdbID: imdb, kind: d.kind)
        }
    }

    /// 查到豆瓣条目时直达条目：iOS 先打开豆瓣 app，没装就开网页；mac 开网页。
    /// 还没查到、查不到、查询失败时用 IMDb 编号搜索（原来的做法）
    @ViewBuilder private func doubanLink(_ d: TMDBDetails, fallback: URL) -> some View {
        let subject = d.imdbID.flatMap { media.doubanSubject(imdbID: $0) }
        #if os(iOS)
        if let subject, let app = subject.appURL {
            Button("Douban") {
                openURL(app) { accepted in if !accepted { openURL(subject.webURL) } }
            }
        } else {
            Link("Douban", destination: subject?.webURL ?? fallback)
        }
        #else
        Link("Douban", destination: subject?.webURL ?? fallback)
        #endif
    }

    private func menu(_ e: MediaLibrary.Entry) -> some View {
        Menu {
            Button("Change Match…") { matching = true }
            Button("Not a Movie or TV Show") { media.markNotVideo(torrent) }
            if e.manual { Button("Use Automatic Match") { Task { await media.resetMatch(torrent) } } }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .accessibilityLabel(Text("Movie Info Options"))
    }
}

/// 手动匹配：按片名搜电影或剧集，点选一个
struct MediaMatchSheet: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    let torrent: Torrent
    @State private var query = ""
    @State private var kind: MediaKind = .movie
    @State private var year = ""
    @State private var results: [TMDBSearchResult]?
    @State private var error: String?
    @State private var searching = false

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text("Match Movie or TV Show").font(.headline)
            Text(torrent.name).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                TextField("Title", text: $query).onSubmit(search)
                TextField("Year", text: $year).frame(width: 60).onSubmit(search)
                kindPicker.labelsHidden().frame(width: 110)
                Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            resultList.frame(minHeight: 280)
            HStack {
                Button("Not a Movie or TV Show") { media.markNotVideo(torrent); dismiss() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear(perform: prefill)
        #else
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $query).onSubmit(search).submitLabel(.search)
                    TextField("Year (optional)", text: $year).keyboardType(.numberPad)
                    kindPicker
                    Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                } footer: {
                    Text(torrent.name).lineLimit(2)
                }
                Section { rows }
                Section {
                    Button("Not a Movie or TV Show", role: .destructive) { media.markNotVideo(torrent); dismiss() }
                }
            }
            .navigationTitle("Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear(perform: prefill)
        #endif
    }

    private var kindPicker: some View {
        Picker("Type", selection: $kind) {
            Text("Movie").tag(MediaKind.movie)
            Text("TV Show").tag(MediaKind.tv)
        }
        .onChange(of: kind) { search() }
    }

    #if os(macOS)
    private var resultList: some View {
        List { rows }.listStyle(.bordered)
    }
    #endif

    @ViewBuilder private var rows: some View {
        if searching {
            ProgressView().frame(maxWidth: .infinity)
        } else if let error {
            Text(error).foregroundStyle(.secondary)
        } else if let results {
            if results.isEmpty { Text("No results").foregroundStyle(.secondary) }
            ForEach(results) { r in
                Button {
                    Task { await media.setMatch(torrent, kind: kind, id: r.id); dismiss() }
                } label: {
                    HStack(spacing: 10) {
                        PosterImage(url: TMDBImage.url(r.posterPath, size: "w92"), width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: r.displayTitle + (r.year.map { "  \($0)" } ?? "")).lineLimit(1)
                            if r.originalDisplayTitle != r.displayTitle { Text(verbatim: r.originalDisplayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            if let o = r.overview, !o.isEmpty { Text(verbatim: o).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func prefill() {
        let r = media.release(of: torrent)
        query = r.titles.first ?? torrent.name
        year = r.year.map(String.init) ?? ""
        kind = r.kind == .tv ? .tv : .movie
        search()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                // 剧集的种子年份常是这一季的年份，不拿来过滤
                results = try await media.search(q, kind: kind, year: kind == .movie ? Int(year) : nil)
            } catch {
                self.error = "\(error)"
            }
            searching = false
        }
    }
}
