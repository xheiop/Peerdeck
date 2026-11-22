import Foundation
import Observation
import TorrentKit

/// 添加面板里的一项
struct AddItem: Identifiable, Equatable {
    enum Kind: Equatable { case magnet, link, file }
    enum State: Equatable {
        case parsing
        case ok
        /// 种子链接下载 / 解析失败：把链接直接交给下载器
        case fallback(String)
        case bad(String)
    }

    let id = UUID()
    var kind: Kind
    var raw: String
    var state: State
    var name = ""
    var size: Int64 = 0
    var files: [TorrentFile.Entry] = []
    var host = ""
    var isPrivate = false
    var data: Data?

    var isValid: Bool { if case .ok = state { true } else if case .fallback = state { true } else { false } }
}

func hostOf(_ url: String) -> String {
    guard let r = url.range(of: "://") else { return "" }
    let rest = url[r.upperBound...]
    let end = rest.firstIndex { $0 == "/" || $0 == ":" || $0 == "?" } ?? rest.endIndex
    return String(rest[..<end]).lowercased()
}

/// 添加种子面板的状态：每行一个 magnet / 种子链接，加上选的 .torrent 文件
@MainActor @Observable
final class AddDraft: Identifiable {
    let id = UUID()
    @ObservationIgnored weak var model: AppModel?
    var text: String { didSet { if text != oldValue { reparse() } } }
    private(set) var linkItems: [AddItem] = []
    private(set) var fileItems: [AddItem] = []
    var server: String
    var serverTouched = false
    var savePath = ""
    var category = ""
    var tags = ""
    var paused = false
    var busy = false
    var error: String?
    /// 同一个链接不重复下载
    @ObservationIgnored private var cache: [String: AddItem] = [:]

    var items: [AddItem] { fileItems + linkItems }

    init(model: AppModel, text: String = "", files: [URL] = []) {
        self.model = model
        self.text = text
        self.server = model.prefs.lastAddServer.flatMap { id in model.onlineServers.contains { $0.id == id } ? id : nil }
            ?? model.onlineServers.first?.id ?? model.servers.first?.id ?? ""
        reparse()
        addFiles(files)
    }

    func append(text more: String, files: [URL]) {
        if !more.isEmpty { text = text.isEmpty ? more : text + "\n" + more }
        addFiles(files)
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var item = AddItem(kind: .file, raw: url.lastPathComponent, state: .ok, name: url.lastPathComponent)
            if let data = try? Data(contentsOf: url) {
                item.data = data
                fill(&item, from: data)
            } else {
                item.state = .bad(L("Can’t read this file"))
            }
            fileItems.append(item)
        }
        recommend()
    }

    private func fill(_ item: inout AddItem, from data: Data) {
        do {
            let t = try TorrentFile.parse(data)
            item.name = t.name
            item.size = t.totalSize
            item.files = t.files
            item.host = t.trackers.first.map(hostOf) ?? ""
            item.isPrivate = t.isPrivate
            item.state = .ok
        } catch {
            item.state = .bad(L("Not a valid .torrent file"))
        }
    }

    private func reparse() {
        var out: [AddItem] = []
        for raw in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            if let cached = cache[raw] { out.append(cached); continue }
            if raw.lowercased().hasPrefix("magnet:?") {
                let comps = URLComponents(string: raw)
                let dn = comps?.queryItems?.first { $0.name == "dn" }?.value ?? ""
                let tr = comps?.queryItems?.first { $0.name == "tr" }?.value ?? ""
                out.append(AddItem(kind: .magnet, raw: raw, state: .ok, name: dn.isEmpty ? L("(magnet has no name)") : dn, host: hostOf(tr)))
            } else if let url = Self.localTorrent(raw) {
                // 把 .torrent 拖到文本框上时，TextEditor 自己接住了拖放，插进来的是文件路径
                var item = AddItem(kind: .file, raw: raw, state: .ok, name: url.lastPathComponent)
                if let data = try? Data(contentsOf: url) {
                    item.data = data
                    fill(&item, from: data)
                } else {
                    item.state = .bad(L("Can’t read this file"))
                }
                cache[raw] = item
                out.append(item)
            } else if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                let item = AddItem(kind: .link, raw: raw, state: .parsing, host: hostOf(raw))
                out.append(item)
                download(item)
            } else {
                out.append(AddItem(kind: .link, raw: raw, state: .bad(L("Not a magnet or http(s) link, will be skipped"))))
            }
        }
        linkItems = out
        recommend()
    }

    /// 一行是不是本机的 .torrent 文件（绝对路径、~/ 或 file:// 链接）
    static func localTorrent(_ raw: String) -> URL? {
        guard raw.lowercased().hasSuffix(".torrent") else { return nil }
        let url: URL
        if raw.lowercased().hasPrefix("file://") {
            guard let u = URL(string: raw), u.isFileURL else { return nil }
            url = u
        } else if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 由 app 下载 .torrent 在本地解析。不带任何 cookie：要登录的链接会失败，失败就交给下载器去下载
    private func download(_ item: AddItem) {
        let raw = item.raw, id = item.id
        Task {
            var result = item
            do {
                guard let url = URL(string: raw) else { throw URLError(.badURL) }
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false
                config.httpCookieAcceptPolicy = .never
                config.timeoutIntervalForRequest = 15
                let (data, resp) = try await URLSession(configuration: config).data(from: url)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw AddDownloadError.http(status) }
                guard data.count < 20_000_000 else { throw AddDownloadError.tooLarge }
                result.data = data
                fill(&result, from: data)
                if case .bad = result.state { throw AddDownloadError.notTorrent }
                result.kind = .file
            } catch {
                result.data = nil
                result.state = .fallback(L("Couldn’t download the torrent file (\(Self.describe(error))). The link will be handed to the client, so files can’t be previewed."))
            }
            cache[raw] = result
            if let i = linkItems.firstIndex(where: { $0.id == id }) { linkItems[i] = result }
            recommend()
        }
    }

    enum AddDownloadError: Error { case http(Int), tooLarge, notTorrent }

    static func describe(_ e: Error) -> String {
        switch e {
        case AddDownloadError.http(let s): s == 401 || s == 403 ? L("HTTP \(s), probably needs a login cookie") : "HTTP \(s)"
        case AddDownloadError.tooLarge: L("File too large")
        case AddDownloadError.notTorrent: L("Didn’t get a torrent file, maybe a login page")
        case let u as URLError: u.code == .timedOut ? L("Timed out") : u.localizedDescription
        default: "\(e)"
        }
    }

    /// 所有项来自同一个站时，按站点设置的默认服务器推荐
    private(set) var recommendation = ""

    private func recommend() {
        guard let model else { return }
        let sites = Set(items.filter(\.isValid).compactMap { $0.host.isEmpty ? nil : model.store.hostToSite[$0.host] ?? $0.host })
        if sites.count == 1, let sid = sites.first {
            let name = model.siteName(sid)
            if let def = model.site(sid)?.defaultServer, model.server(def) != nil {
                if !serverTouched { server = def }
                recommendation = L("All from \(name); adding to \(model.server(def)?.config.name ?? def) by default (change in Settings › Sites)")
            } else {
                recommendation = L("From \(name). You can set a default server for it in Settings › Sites.")
            }
        } else {
            recommendation = sites.count > 1 ? L("From several sites; using your last choice") : ""
        }
    }

    var validCount: Int { items.filter(\.isValid).count }
    var parsing: Bool { items.contains { $0.state == .parsing } }
    var badCount: Int { items.filter { if case .bad = $0.state { true } else { false } }.count }

    func submit() async -> Bool {
        guard let model, let rt = model.server(server), let client = rt.client else {
            error = L("Server is offline")
            return false
        }
        busy = true
        defer { busy = false }
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let opts = AddOptions(savePath: savePath.isEmpty ? nil : savePath,
                              category: category.isEmpty || rt.config.kind != .qbittorrent ? nil : category,
                              tags: tagList, paused: paused)
        var added = 0, failed: [String] = []
        for item in items where item.isValid {
            do {
                if let data = item.data {
                    try await client.add(.file(data, filename: (item.name.isEmpty ? "torrent" : item.name) + ".torrent"), options: opts)
                } else {
                    try await client.add(.url(item.raw), options: opts)
                }
                added += 1
            } catch {
                failed.append(Fmt.labeled(item.name.isEmpty ? item.raw : item.name, "\(error)"))
            }
        }
        model.prefs.lastAddServer = server
        model.rememberPath(savePath)
        rt.refreshNow()
        if !failed.isEmpty {
            error = L("\(failed.count) couldn’t be added:") + "\n" + failed.joined(separator: "\n")
            return false
        }
        let fb = items.filter { if case .fallback = $0.state { true } else { false } }.count
        model.showToast(L("Added \(Fmt.torrents(added)) to \(rt.config.name)") + (fb > 0 ? L(" (\(fb) via link download on the client)") : ""))
        return true
    }
}
