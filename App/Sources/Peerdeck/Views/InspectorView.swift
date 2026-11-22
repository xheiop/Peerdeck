import SwiftUI
import TorrentKit

struct InspectorView: View {
    let model: AppModel

    var body: some View {
        let store = model.store
        let _ = store.selectionRevision
        let sel = store.selection.compactMap { store.torrent($0) }
        Group {
            if sel.count == 1, let t = sel.first {
                TorrentDetail(model: model, torrent: t).id(t.ref)
            } else if sel.count > 1 {
                Form {
                    Section("\(Fmt.torrents(sel.count)) selected") {
                        LabeledContent("Total Size", value: Fmt.bytes(sel.reduce(0) { $0 + $1.totalSize }))
                        LabeledContent("Total Uploaded", value: Fmt.bytes(sel.reduce(0) { $0 + $1.uploaded }))
                        LabeledContent(String(localized: "Servers", table: "Groups"), value: Set(sel.compactMap { model.server($0.ref.server.rawValue)?.config.name }).sorted().joined(separator: L(", ")))
                        let cross = sel.filter { store.cross[$0.ref] != nil }.count
                        if cross > 0 { LabeledContent(L("Cross-seeds"), value: L("Shares data with \(Fmt.torrents(cross)) elsewhere")) }
                    }
                    Text("Batch actions are in the bar at the bottom of the list.").foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Select a torrent to see details", systemImage: "sidebar.right")
            }
        }
        .frame(minWidth: 280)
    }
}

private struct TorrentDetail: View {
    let model: AppModel
    let torrent: Torrent
    @State private var trackers: [Tracker]?
    @State private var trackerError: String?
    @State private var showInfo: Bool
    @State private var showTrackers: Bool
    /// TC_DEBUG_FILES=1 时默认展开（截图用）
    @State private var showFiles = ProcessInfo.processInfo.environment["TC_DEBUG_FILES"] == "1"
    @State private var files: [ContentFile]?
    @State private var filesError: String?

    init(model: AppModel, torrent: Torrent) {
        self.model = model
        self.torrent = torrent
        let problem = model.store.rules.isProblem(torrent)
        _showInfo = State(initialValue: !problem)
        _showTrackers = State(initialValue: problem)
    }

    private var store: TorrentStore { model.store }

    var body: some View {
        let t = torrent
        let rules = store.rules
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(t.name).font(.headline).textSelection(.enabled)

                if rules.isProblem(t) { problemCard(t) }
                if let n = store.cross[t.ref] { crossCard(t, n) }

                DisclosureGroup("Overview", isExpanded: $showInfo) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        kv(L("Server"), model.server(t.ref.server.rawValue)?.config.name ?? t.ref.server.rawValue)
                        kv(L("Site"), model.siteName(store.siteID(of: t)))
                        kv(L("Status"), Fmt.state(t.state) + (t.rawState.isEmpty ? "" : " (\(t.rawState))"))
                        kv(L("Progress"), Fmt.percent(t.progress))
                        kv(L("Size"), Fmt.bytes(t.totalSize))
                        kv(L("Uploaded"), Fmt.bytes(t.uploaded))
                        kv(L("Ratio"), Fmt.ratio(t.ratio))
                        kv(L("Seeding Time"), Fmt.duration(t.seedingTime))
                        kv(L("Added"), Fmt.date(t.addedAt))
                        if !t.category.isEmpty { kv(L("Category"), t.category) }
                        if !t.tags.isEmpty { kv(L("Tags"), t.tags.joined(separator: ", ")) }
                        if t.uploadLimit > 0 { kv(L("Upload Limit"), Fmt.speed(t.uploadLimit)) }
                        kv(L("Save Path"), t.savePath)
                        kv("Hash", t.infoHashV1, mono: true)
                    }
                    .padding(.top, 4)
                }
                DisclosureGroup(isExpanded: $showFiles) {
                    filesSection(t).padding(.top, 4)
                } label: {
                    Text(files.map { L("Files (\(Fmt.count($0.count)))") } ?? L("Files"))
                }
                DisclosureGroup("Tracker", isExpanded: $showTrackers) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let trackers {
                            ForEach(Array(trackers.enumerated()), id: \.offset) { _, tr in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("T\(tr.tier)").font(.caption).foregroundStyle(.secondary)
                                        Text(masked(tr.url)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: statusIcon(tr.status)).foregroundStyle(statusColor(tr.status))
                                        Text(Fmt.trackerStatus(tr.status))
                                        if !tr.message.isEmpty { Text(tr.message).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    .font(.caption)
                                }
                            }
                        } else if let trackerError {
                            Text(trackerError).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Replace Tracker…") {
                            model.sheet = .retracker(RetrackerDraft(model: model, siteID: store.siteID(of: t), selection: [t.ref], scope: .selection))
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
        }
        .task(id: t.ref) {
            do { trackers = try await model.trackers(for: t.ref) } catch { trackerError = "\(error)" }
        }
        // 文件列表展开时才去拿（大种子几百个文件，不展开就不请求）
        .task(id: showFiles) { if showFiles, files == nil { await loadFiles() } }
    }

    private func loadFiles() async {
        do { files = try await model.files(for: torrent.ref); filesError = nil } catch { filesError = "\(error)" }
    }

    @ViewBuilder private func filesSection(_ t: Torrent) -> some View {
        if let files {
            if files.isEmpty {
                Text("No file list yet: the client is still fetching metadata.").font(.callout).foregroundStyle(.secondary)
            } else {
                // 多文件种子的路径都以种子名开头，去掉这一层
                let root = t.name + "/"
                VStack(alignment: .leading, spacing: 6) {
                    if files.count > 1 {
                        HStack {
                            let skipped = files.filter { $0.priority == .skip }
                            Text(skipped.isEmpty ? L("All \(Fmt.count(files.count)) files will be downloaded")
                                 : L("Skipping \(Fmt.count(skipped.count)) of \(Fmt.count(files.count)) (\(Fmt.bytes(skipped.reduce(0) { $0 + $1.size })))"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            priorityMenu(nil, title: L("Set All")) { p in setPriority(p, files.map(\.index)) }
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(files) { f in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.path.hasPrefix(root) ? String(f.path.dropFirst(root.count)) : f.path)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(f.path)
                                    Text("\(Fmt.bytes(f.size)) · \(Fmt.percent(f.progress))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .foregroundStyle(f.priority == .skip ? .secondary : .primary)
                                Spacer(minLength: 4)
                                priorityMenu(f.priority, title: Self.title(f.priority)) { p in setPriority(p, [f.index]) }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        } else if let filesError {
            Text(filesError).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func priorityMenu(_ current: FilePriority?, title: String, _ set: @escaping (FilePriority) -> Void) -> some View {
        let low = model.supportsLowFilePriority(torrent.ref)
        return Menu(title) {
            ForEach(FilePriority.allCases.reversed().filter { $0 != .low || low }, id: \.self) { p in
                Button { set(p) } label: {
                    if p == current { Label(Self.title(p), systemImage: "checkmark") } else { Text(Self.title(p)) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(current == .skip ? .secondary : .primary)
    }

    /// 先改本地显示，再读回服务器上的实际值
    private func setPriority(_ p: FilePriority, _ indices: [Int]) {
        let set = Set(indices)
        files = files?.map { f in var f = f; if set.contains(f.index) { f.priority = p }; return f }
        let ref = torrent.ref
        Task {
            do { try await model.setFilePriority(p, files: indices, of: ref) } catch { model.alert = "\(error)" }
            await loadFiles()
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

    @ViewBuilder private func problemCard(_ t: Torrent) -> some View {
        let rules = store.rules
        let rejected = rules.isRejected(t)
        let title = rejected
            ? (rules.isUnregistered(t) ? L("Rejected by tracker · likely unregistered") : t.trackerHealth == .notWorking ? L("Tracker not working (cause unknown)") : L("Rejected by Tracker"))
            : L("Tracker unreachable")
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: rejected ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle")
                .font(.headline)
                .foregroundStyle(.primary)
                .labelStyle(TintedIconLabel(color: rejected ? .red : .orange))
            if !t.errorMessage.isEmpty {
                Text(t.errorMessage).font(.callout.monospaced()).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if let f = store.firstSeen(t.ref) {
                Text(L("First seen: \(Fmt.ago(f))")).font(.caption).foregroundStyle(.secondary)
            }
            Text(rejected
                 ? (rules.isUnregistered(t) ? "The site deleted or replaced this torrent. Seeding it no longer counts toward your upload." : "The site rejected the account, client or torrent.")
                 : "Usually a temporary site or network problem. Consider acting only if it lasts more than a day.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Reannounce")) { model.perform(.reannounce, on: [t.ref]); model.showToast(L("Reannounced")) }
                if rejected { Button("Delete…", role: .destructive) { model.requestDelete([t.ref]) } }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).stroke((rejected ? Color.red : Color.orange).opacity(0.45)))
    }

    private func crossCard(_ t: Torrent, _ n: Int) -> some View {
        let others = store.all.values.filter {
            $0.ref != t.ref && ((!t.infoHashV1.isEmpty && $0.infoHashV1 == t.infoHashV1) || ($0.name == t.name && $0.totalSize == t.totalSize))
        }.prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Cross-seeds").font(.headline)
            Text("This data is also used by \(n) other torrents, so files are kept when deleting.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(others), id: \.ref) { o in
                Text("\(model.siteName(store.siteID(of: o))) · \(model.server(o.ref.server.rawValue)?.config.name ?? "")").font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).stroke(.separator))
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(mono ? .caption.monospaced() : .body).textSelection(.enabled).lineLimit(mono ? 2 : 3)
        }
        .font(.callout)
    }

    /// passkey 打码显示
    private func masked(_ url: String) -> String {
        guard let pk = RetrackerDraft.passkey(url) else { return url }
        return url.replacingOccurrences(of: pk, with: RetrackerDraft.mask(pk))
    }

    private func statusIcon(_ s: TrackerStatus) -> String {
        switch s {
        case .working: "checkmark.circle.fill"
        case .trackerError, .notWorking: "exclamationmark.triangle.fill"
        case .unreachable: "bolt.horizontal.circle"
        default: "circle.dashed"
        }
    }

    private func statusColor(_ s: TrackerStatus) -> Color {
        switch s {
        case .working: .green
        case .trackerError, .notWorking: .red
        case .unreachable: .orange
        default: .secondary
        }
    }
}

/// 图标着色、文字保持主色
struct TintedIconLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}
