import Foundation
import Observation
import TorrentKit

/// 批量替换 tracker 地址（站点换域名、重置 passkey）
@MainActor @Observable
final class RetrackerDraft: Identifiable {
    enum Scope: Hashable { case site, selection }
    enum Mode: String, CaseIterable { case host, passkey, custom }
    enum Phase: Equatable { case form, running(done: Int, total: Int), done }

    struct Change: Sendable { var ref: TorrentRef; var old: String; var new: String }

    let id = UUID()
    @ObservationIgnored weak var model: AppModel?
    let siteID: String?
    let selectionRefs: [TorrentRef]
    var scope: Scope { didSet { resetFind() } }
    var mode: Mode = .host { didSet { if mode != oldValue { replacement = ""; resetFind() } } }
    var find = ""
    var replacement = ""
    var reannounce = true
    var phase: Phase = .form
    private(set) var succeeded: [Change] = []
    private(set) var failures: [String] = []

    init(model: AppModel, siteID: String?, selection: [TorrentRef], scope: Scope) {
        self.model = model
        self.siteID = siteID
        self.selectionRefs = selection
        self.scope = (scope == .selection && selection.isEmpty) ? .site : scope
        resetFind()
    }

    var targets: [Torrent] {
        guard let store = model?.store else { return [] }
        switch scope {
        case .selection: return selectionRefs.compactMap { store.torrent($0) }
        case .site:
            guard let siteID else { return [] }
            return store.all.values.filter { store.siteID(of: $0) == siteID }
        }
    }

    private func resetFind() {
        let ts = targets
        switch mode {
        case .host:
            var count: [String: Int] = [:]
            for t in ts { for u in t.trackerURLs { count[hostOf(u), default: 0] += 1 } }
            find = count.max { $0.value < $1.value }?.key ?? ""
        case .passkey:
            find = ts.lazy.flatMap(\.trackerURLs).compactMap(Self.passkey).first ?? ""
        case .custom:
            find = ""
        }
    }

    static func passkey(_ url: String) -> String? {
        guard let r = url.range(of: "passkey=") else { return nil }
        return String(url[r.upperBound...].prefix { $0 != "&" })
    }

    static func mask(_ s: String) -> String { s.count <= 4 ? "••••" : "••••••" + s.suffix(4) }

    func rewrite(_ url: String) -> String? {
        let f = find.trimmingCharacters(in: .whitespaces), r = replacement.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !r.isEmpty, f != r else { return nil }
        switch mode {
        case .host:
            guard hostOf(url) == f.lowercased() else { return nil }
            return url.replacingOccurrences(of: "://" + f, with: "://" + r, options: .caseInsensitive)
        case .passkey:
            guard Self.passkey(url) == f else { return nil }
            return url.replacingOccurrences(of: "passkey=" + f, with: "passkey=" + r)
        case .custom:
            guard url.contains(f) else { return nil }
            return url.replacingOccurrences(of: f, with: r)
        }
    }

    var plan: [Change] {
        targets.flatMap { t in t.trackerURLs.compactMap { u in rewrite(u).map { Change(ref: t.ref, old: u, new: $0) } } }
    }

    /// 第一条匹配的地址，用来做预览（passkey 打码）
    var preview: (String, String)? {
        guard let c = plan.first else { return nil }
        let hide = { (s: String) in Self.passkey(s).map { s.replacingOccurrences(of: $0, with: Self.mask($0)) } ?? s }
        return mode == .passkey ? (hide(c.old), c.new.replacingOccurrences(of: replacement, with: Self.mask(replacement))) : (hide(c.old), hide(c.new))
    }

    func run() async {
        guard let model else { return }
        let changes = plan
        let offline = changes.filter { model.server($0.ref.server.rawValue)?.client == nil }
        let todo = changes.filter { model.server($0.ref.server.rawValue)?.client != nil }
        phase = .running(done: 0, total: todo.count)
        failures = offline.isEmpty ? [] : [L("\(offline.count) are on offline servers and weren’t changed")]
        succeeded = []
        var done = 0
        // 每台服务器 4 个并发（qB 只能逐个种子调用）
        for (sid, group) in Dictionary(grouping: todo, by: \.ref.server) {
            guard let client = model.server(sid.rawValue)?.client else { continue }
            for offset in stride(from: 0, to: group.count, by: 4) {
                let chunk = Array(group[offset..<min(offset + 4, group.count)])
                let results = await withTaskGroup(of: (Change, String?).self) { tg in
                    for c in chunk {
                        tg.addTask {
                            do { try await client.replaceTrackerURL(on: c.ref.id, from: c.old, to: c.new); return (c, nil) }
                            catch { return (c, "\(error)") }
                        }
                    }
                    var out: [(Change, String?)] = []
                    for await r in tg { out.append(r) }
                    return out
                }
                for (c, err) in results {
                    if let err { failures.append(Fmt.labeled(model.store.torrent(c.ref)?.name ?? c.ref.id, "\(err)")) } else { succeeded.append(c) }
                }
                done += chunk.count
                phase = .running(done: done, total: todo.count)
            }
            model.server(sid.rawValue)?.refreshNow()
        }
        let okRefs = Set(succeeded.map(\.ref))
        let newURLs = Dictionary(grouping: succeeded, by: \.ref)
        model.store.patchLocally(okRefs) { t in
            for c in newURLs[t.ref] ?? [] { t.trackerURLs = t.trackerURLs.map { $0 == c.old ? c.new : $0 } }
            if let first = t.trackerURLs.first { t.announceURL = first }
        }
        if reannounce, !okRefs.isEmpty { model.perform(.reannounce, on: okRefs) }
        if mode == .host, let siteID, !succeeded.isEmpty {
            model.siteMoved(siteID, from: find.lowercased(), to: replacement.trimmingCharacters(in: .whitespaces).lowercased())
        }
        phase = .done
    }

    /// 换回原地址
    func undo() async {
        guard let model else { return }
        let back = succeeded
        for c in back {
            try? await model.server(c.ref.server.rawValue)?.client?.replaceTrackerURL(on: c.ref.id, from: c.new, to: c.old)
        }
        if mode == .host, let siteID, let i = model.prefs.sites.firstIndex(where: { $0.id == siteID }) {
            let old = find.lowercased()
            var hosts = model.prefs.sites[i].hosts.filter { $0 != old }
            hosts.insert(old, at: 0)
            model.prefs.sites[i].hosts = hosts
        }
        let refs = Set(back.map(\.ref))
        model.store.patchLocally(refs) { t in
            for c in back where c.ref == t.ref { t.trackerURLs = t.trackerURLs.map { $0 == c.new ? c.old : $0 } }
            if let first = t.trackerURLs.first { t.announceURL = first }
        }
        for sid in Set(refs.map(\.server)) { model.server(sid.rawValue)?.refreshNow() }
        model.showToast(L("Switched back to the original URLs (\(back.count))"))
    }
}
