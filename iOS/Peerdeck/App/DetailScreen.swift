import SwiftUI
import TorrentKit

/// 种子详情（v3）：名字和状态在上；有问题时先给健康度形状和 tracker 原话；下面是账本式的键值行。
/// 操作放在底部工具栏（浮层，系统给玻璃），进来时隐藏标签栏
struct TorrentDetailScreen: View {
    let model: AppModel
    let ref: TorrentRef
    @State private var trackers: [Tracker]?
    @State private var trackerError: String?
    /// TC_DEBUG_FILES=1 时直接打开文件列表（截图用）
    @State private var showFiles = ProcessInfo.processInfo.environment["TC_DEBUG_FILES"] == "1"
    /// TC_DEBUG_PEERS=1 时直接打开 Peers（截图用）
    @State private var showPeers = ProcessInfo.processInfo.environment["TC_DEBUG_PEERS"] == "1"

    private var store: TorrentStore { model.store }

    var body: some View {
        let _ = store.revision
        if let t = store.torrent(ref) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(t).padding(.horizontal, 20).padding(.bottom, 18)
                    if store.rules.isProblem(t) { problem(t).padding(.horizontal, 20).padding(.bottom, 22) }
                    LedgerHeader(title: L("Overview")).padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 0) { facts(t) }
                    NavigationLink { FilesScreen(model: model, torrent: t) } label: {
                        HStack {
                            Text("Files").font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    NavigationLink { PeersScreen(model: model, torrent: t) } label: {
                        HStack {
                            Text("Peers").font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 20) }
                    LedgerHeader(title: "Tracker").padding(.top, 18).padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 0) { trackerRows }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle(t.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { actions(t) }
            .navigationDestination(isPresented: $showFiles) { FilesScreen(model: model, torrent: t) }
            .navigationDestination(isPresented: $showPeers) { PeersScreen(model: model, torrent: t) }
            .task(id: ref) {
                do { trackers = try await model.trackers(for: ref) } catch { trackerError = "\(error)" }
            }
        } else {
            // 删掉以后（或者服务器下线）
            ContentUnavailableView("This torrent is gone", systemImage: "tray")
        }
    }

    private func header(_ t: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.name).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 10) {
                Text(Fmt.state(t.state)).foregroundStyle(.secondary)
                if t.progress < 1 { Text(Fmt.percent(t.progress)) }
                Spacer()
                if t.downloadSpeed > 0 { Text("↓ \(Fmt.speed(t.downloadSpeed))") }
                if t.uploadSpeed > 0 { Text("↑ \(Fmt.speed(t.uploadSpeed))") }
            }
            .font(.data)
            if t.progress < 1 { ProgressBar(value: t.progress, dim: t.downloadSpeed == 0) }
        }
    }

    @ViewBuilder private func problem(_ t: Torrent) -> some View {
        let rules = store.rules
        let rejected = rules.isRejected(t)
        let mark: HealthMark = rejected ? (rules.isUnregistered(t) ? .unregistered : .rejected) : .timeout
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                mark.view
                Text(rejected
                     ? (rules.isUnregistered(t) ? L("Rejected by tracker · likely unregistered") : t.trackerHealth == .notWorking ? L("Tracker not working (cause unknown)") : L("Rejected by Tracker"))
                     : L("Tracker unreachable"))
                    .font(.subheadline.weight(.medium))
            }
            if !t.errorMessage.isEmpty {
                Text(t.errorMessage).font(.quote).textSelection(.enabled)
            }
            Text(explanation(t, rejected: rejected) + (store.firstSeen(t.ref).map { "  " + L("First seen: \(Fmt.ago($0))") } ?? ""))
                .font(.footnote).foregroundStyle(.secondary)
            if let n = store.cross[t.ref] {
                Text("This data is also used by \(n) other torrents, so files are kept when deleting.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func explanation(_ t: Torrent, rejected: Bool) -> String {
        rejected
            ? (store.rules.isUnregistered(t) ? L("The site deleted or replaced this torrent. Seeding it no longer counts toward your upload.") : L("The site rejected the account, client or torrent."))
            : L("Usually a temporary site or network problem. Consider acting only if it lasts more than a day.")
    }

    @ViewBuilder private func facts(_ t: Torrent) -> some View {
        kv(L("Server"), model.server(t.ref.server.rawValue)?.config.name ?? t.ref.server.rawValue)
        kv(L("Site"), model.siteName(store.siteID(of: t)))
        kv(L("Size"), Fmt.bytes(t.totalSize), mono: true)
        kv(L("Uploaded"), Fmt.bytes(t.uploaded), mono: true)
        kv(L("Ratio"), Fmt.ratio(t.ratio), mono: true)
        kv(L("Seeding Time"), Fmt.duration(t.seedingTime))
        kv(L("Added"), Fmt.date(t.addedAt))
        if let n = store.cross[t.ref], !store.rules.isProblem(t) { kv(L("Cross-seeds"), Fmt.count(n), mono: true) }
        if !t.category.isEmpty { kv(L("Category"), t.category) }
        if !t.tags.isEmpty { kv(L("Tags"), t.tags.joined(separator: ", ")) }
        if t.uploadLimit > 0 { kv(L("Upload Limit"), Fmt.speed(t.uploadLimit), mono: true) }
        kv(L("Save Path"), t.savePath, mono: true, stacked: true)
        kv("Hash", t.infoHashV1, mono: true, stacked: true)
    }

    @ViewBuilder private var trackerRows: some View {
        if let trackers {
            ForEach(Array(trackers.enumerated()), id: \.offset) { i, tr in
                if i > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 20) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(masked(tr.url)).font(.data).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "T\(tr.tier)").foregroundStyle(.secondary)
                        Text(Fmt.trackerStatus(tr.status))
                        if !tr.message.isEmpty { Text(tr.message).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, 20).padding(.vertical, 9)
            }
        } else if let trackerError {
            Text(trackerError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
        } else {
            ProgressView().padding(.horizontal, 20)
        }
    }

    @ToolbarContentBuilder private func actions(_ t: Torrent) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if t.state == .stopped {
                Button { model.perform(.start, on: [ref]) } label: { Label("Start", systemImage: "play.fill") }
            } else {
                Button { model.perform(.stop, on: [ref]) } label: { Label("Stop", systemImage: "pause.fill") }
            }
            Spacer()
            Button { model.perform(.reannounce, on: [ref]); model.showToast(L("Reannounced")) } label: { Label("Reannounce", systemImage: "arrow.clockwise") }
            Spacer()
            Menu {
                Button { model.perform(.recheck, on: [ref]) } label: { Label("Recheck", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
                Button { model.requestSetLocation([ref]) } label: { Label("Set Location…", systemImage: "folder") }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            Spacer()
            Button { model.requestDelete([ref]) } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    /// 键值行：左边灰色键，右边值；长的值（路径、hash）另起一行
    @ViewBuilder private func kv(_ k: String, _ v: String, mono: Bool = false, stacked: Bool = false) -> some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(k).foregroundStyle(.secondary)
                    Text(v).font(mono ? .data : .subheadline).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(k).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(v).font(mono ? .system(.subheadline, design: .monospaced) : .subheadline).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 20) }
    }

    private func masked(_ url: String) -> String {
        guard let pk = RetrackerDraft.passkey(url) else { return url }
        return url.replacingOccurrences(of: pk, with: RetrackerDraft.mask(pk))
    }
}

/// 文件列表和下载优先级
struct FilesScreen: View {
    let model: AppModel
    let torrent: Torrent
    @State private var files: [ContentFile]?
    @State private var error: String?

    var body: some View {
        Group {
            if let files {
                if files.isEmpty {
                    ContentUnavailableView("No file list yet: the client is still fetching metadata.", systemImage: "doc")
                } else {
                    list(files)
                }
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(files.map { L("Files (\(Fmt.count($0.count)))") } ?? L("Files"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func list(_ files: [ContentFile]) -> some View {
        let root = torrent.name + "/"
        let skipped = files.filter { $0.priority == .skip }
        return List {
            Section {
                ForEach(files) { f in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.path.hasPrefix(root) ? String(f.path.dropFirst(root.count)) : f.path).lineLimit(2).truncationMode(.middle)
                            Text("\(Fmt.bytes(f.size)) · \(Fmt.percent(f.progress))").font(.data).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(f.priority == .skip ? .secondary : .primary)
                        Spacer(minLength: 8)
                        priorityMenu(f.priority) { set($0, [f.index]) }
                    }
                }
            } header: {
                if files.count > 1 {
                    Text(skipped.isEmpty ? L("All \(Fmt.count(files.count)) files will be downloaded")
                         : L("Skipping \(Fmt.count(skipped.count)) of \(Fmt.count(files.count)) (\(Fmt.bytes(skipped.reduce(0) { $0 + $1.size })))"))
                }
            }
        }
        .toolbar {
            if files.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(L("Set All")) { options(nil) { set($0, files.map(\.index)) } }
                }
            }
        }
        .listStyle(.plain)
        .toolbar(.hidden, for: .tabBar)
    }

    private func priorityMenu(_ current: FilePriority, _ apply: @escaping (FilePriority) -> Void) -> some View {
        Menu { options(current, apply) } label: {
            HStack(spacing: 2) {
                Text(Self.title(current))
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.callout)
            .foregroundStyle(current == .skip ? .secondary : .primary)
        }
    }

    @ViewBuilder private func options(_ current: FilePriority?, _ apply: @escaping (FilePriority) -> Void) -> some View {
        let low = model.supportsLowFilePriority(torrent.ref)
        ForEach(FilePriority.allCases.reversed().filter { $0 != .low || low }, id: \.self) { p in
            Button { apply(p) } label: {
                if p == current { Label(Self.title(p), systemImage: "checkmark") } else { Text(Self.title(p)) }
            }
        }
    }

    private func load() async {
        do { files = try await model.files(for: torrent.ref); error = nil } catch { self.error = "\(error)" }
    }

    /// 先改本地显示，再读回服务器上的实际值
    private func set(_ p: FilePriority, _ indices: [Int]) {
        let s = Set(indices)
        files = files?.map { f in var f = f; if s.contains(f.index) { f.priority = p }; return f }
        let ref = torrent.ref
        Task {
            do { try await model.setFilePriority(p, files: indices, of: ref) } catch { model.alert = "\(error)" }
            await load()
        }
    }

    static func title(_ p: FilePriority) -> String {
        switch p {
        case .skip: L("Don’t Download")
        case .low: L("Low Priority")
        case .normal: L("Normal Priority")
        case .high: L("High Priority")
        }
    }
}
