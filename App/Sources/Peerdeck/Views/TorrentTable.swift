import AppKit
import SwiftUI
import SyncEngine
import TorrentKit

/// 主列表。用 NSTableView：只刷新可见的变化行（SwiftUI Table 在 2 万行时每次更新卡 0.4 s）。
struct TorrentTable: NSViewRepresentable {
    let model: AppModel
    /// 当前要显示的列（随视图和用户选择变化）
    let columns: [ColumnKey]
    /// 列集：normal / problem（右键表头时改的是这一套）
    let columnSet: String
    /// 选择变化时触发 updateNSView，把外部改的选择（Esc、调试开关）同步到表格
    let selectionRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 2)
        let c = context.coordinator
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = c.rowMenu()
        table.headerView?.menu = c.headerMenu()
        c.table = table
        c.setColumns(columns, set: columnSet)
        model.store.observeUpdates(c) { [weak c] update in c?.apply(update) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setColumns(columns, set: columnSet)
        // 放到下一轮 run loop：updateNSView 可能正处在表格自己的代理回调里，直接改选择会重入
        let c = context.coordinator
        DispatchQueue.main.async { c.syncSelection() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var keys: [ColumnKey] = []
        private var set = "normal"
        private var restoringSelection = false
        /// 正在处理表格自己的选择变化：这期间 SwiftUI 回调 updateNSView 时不要反过来改表格（会重入）
        private var handlingSelection = false
        /// 代码设置 sortDescriptors 时会回调 sortDescriptorsDidChange，这时不要写回 store
        private var settingColumns = false

        init(model: AppModel) { self.model = model }
        var store: TorrentStore { model.store }

        func setColumns(_ new: [ColumnKey], set: String) {
            self.set = set
            guard let table, new != keys else { return }
            keys = new
            for c in table.tableColumns { table.removeTableColumn(c) }
            for k in new {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(k.rawValue))
                c.title = k.title
                c.width = k.width
                c.minWidth = 40
                c.headerCell.alignment = k.rightAligned ? .right : .left
                c.sortDescriptorPrototype = NSSortDescriptor(key: k.rawValue, ascending: !k.defaultDescending)
                table.addTableColumn(c)
            }
            settingColumns = true
            table.sortDescriptors = [NSSortDescriptor(key: store.sortColumn.rawValue, ascending: store.ascending)]
            settingColumns = false
            table.reloadData()
        }

        func apply(_ update: TableUpdate) {
            guard let table else { return }
            switch update {
            case .reloadAll:
                restoringSelection = true
                table.reloadData()
                var rows = IndexSet()
                for ref in store.selection { if let r = store.row(of: ref) { rows.insert(r) } }
                table.selectRowIndexes(rows, byExtendingSelection: false)
                restoringSelection = false
            case .rows(let rows):
                let visible = table.rows(in: table.visibleRect)
                let target = rows.intersection(IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
                if !target.isEmpty { table.reloadData(forRowIndexes: target, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
            }
        }

        /// 外部改了选择（比如调试开关、Esc），同步到表格
        func syncSelection() {
            guard let table, !handlingSelection else { return }
            var rows = IndexSet()
            for ref in store.selection { if let r = store.row(of: ref) { rows.insert(r) } }
            if rows != table.selectedRowIndexes {
                restoringSelection = true
                table.selectRowIndexes(rows, byExtendingSelection: false)
                restoringSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { store.order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let key = ColumnKey(rawValue: tableColumn.identifier.rawValue),
                  row < store.order.count, let t = store.torrent(store.order[row]) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell." + key.rawValue)
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.lineBreakMode = key == .name || key == .message || key == .path ? .byTruncatingMiddle : .byTruncatingTail
                tf.maximumNumberOfLines = 1
                tf.cell?.usesSingleLineMode = true
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.alignment = key.rightAligned ? .right : .left
                tf.font = key.rightAligned ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            if let tf = cell.textField {
                // 富文本默认按词换行，会盖住下一行；显式带上截断方式
                let s = NSMutableAttributedString(attributedString: content(key, t))
                s.addAttribute(.paragraphStyle, value: paragraph(key), range: NSRange(location: 0, length: s.length))
                tf.attributedStringValue = s
            }
            cell.textField?.toolTip = key == .name ? t.name : key == .message ? t.errorMessage : nil
            return cell
        }

        // MARK: 单元格内容。颜色只放在图标上，文字保持主色（系统红、黄当文字色时对比度达不到 WCAG AA）

        private func text(_ parts: [(String, NSColor)]) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (str, color) in parts { s.append(NSAttributedString(string: str, attributes: [.foregroundColor: color])) }
            return s
        }

        private var paragraphs: [ColumnKey: NSParagraphStyle] = [:]
        private func paragraph(_ key: ColumnKey) -> NSParagraphStyle {
            if let p = paragraphs[key] { return p }
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = key == .name || key == .message || key == .path ? .byTruncatingMiddle : .byTruncatingTail
            p.alignment = key.rightAligned ? .right : .left
            paragraphs[key] = p
            return p
        }

        private func plain(_ s: String, secondary: Bool = false) -> NSAttributedString {
            text([(s, secondary ? .secondaryLabelColor : .labelColor)])
        }

        private func problemTail(_ t: Torrent) -> [(String, NSColor)] {
            if store.rules.isRejected(t) { return [("  ▲", .systemRed)] }
            if store.rules.isLongUnreachable(t, firstSeen: store.firstSeen(t.ref)) { return [("  ◆", .systemOrange)] }
            return []
        }

        private func content(_ key: ColumnKey, _ t: Torrent) -> NSAttributedString {
            switch key {
            case .name: return plain(t.name)
            case .site: return plain(model.siteName(store.siteID(of: t)))
            case .server: return plain(model.server(t.ref.server.rawValue)?.config.name ?? t.ref.server.rawValue)
            case .status:
                switch StateGroup.of(t.state) {
                case .seeding:
                    return text((t.uploadSpeed > 0 ? [("↑ ", .systemGreen), (Fmt.speed(t.uploadSpeed), .labelColor)] : [(L("Seeding"), .secondaryLabelColor)]) + problemTail(t))
                case .downloading:
                    return text([(Fmt.percent(t.progress), .labelColor)] + (t.downloadSpeed > 0 ? [("  ↓ ", .systemBlue), (Fmt.speed(t.downloadSpeed), .labelColor)] : []) + problemTail(t))
                case .stopped: return text([(L("Stopped"), .secondaryLabelColor)] + problemTail(t))
                case .waiting: return text([(t.state == .checking ? L("Checking \(Fmt.percent(t.progress))") : Fmt.state(t.state), .secondaryLabelColor)])
                case .error: return text([("▲ ", .systemRed), (L("Error"), .labelColor)])
                case nil: return plain(Fmt.state(t.state), secondary: true)
                }
            case .uploaded: return plain(Fmt.bytes(t.uploaded))
            case .ratio: return plain(Fmt.ratio(t.ratio))
            case .seedTime: return plain(t.seedingTime > 0 ? Fmt.duration(t.seedingTime) : "—", secondary: t.seedingTime == 0)
            case .size: return plain(Fmt.bytes(t.totalSize))
            case .added: return plain(Fmt.date(t.addedAt), secondary: true)
            case .problem:
                let since = store.firstSeen(t.ref).map { "  · " + Fmt.ago($0) } ?? ""
                if store.rules.isRejected(t) {
                    let label = store.rules.isUnregistered(t) ? L("Unregistered") : t.trackerHealth == .notWorking ? L("Not working (?)") : L("Rejected")
                    return text([("▲ ", .systemRed), (label, .labelColor), (since, .secondaryLabelColor)])
                }
                if t.trackerHealth == .unreachable { return text([("◆ ", .systemOrange), (L("Unreachable"), .labelColor), (since, .secondaryLabelColor)]) }
                if t.trackerHealth == .trackerWarning { return plain(L("Warning"), secondary: true) }
                return plain("—", secondary: true)
            case .message: return plain(t.errorMessage.isEmpty ? "—" : t.errorMessage, secondary: true)
            case .cross: return plain(store.cross[t.ref].map { L("\($0)") } ?? "—", secondary: store.cross[t.ref] == nil)
            case .category: return plain(t.category.isEmpty ? "—" : t.category, secondary: t.category.isEmpty)
            case .tags: return plain(t.tags.isEmpty ? "—" : t.tags.joined(separator: ", "), secondary: t.tags.isEmpty)
            case .path: return plain(t.savePath, secondary: true)
            case .limit: return plain(t.uploadLimit > 0 ? Fmt.speed(t.uploadLimit) : "—", secondary: t.uploadLimit == 0)
            case .speedDown: return plain(t.downloadSpeed > 0 ? Fmt.speed(t.downloadSpeed) : "—", secondary: t.downloadSpeed == 0)
            case .speedUp: return plain(t.uploadSpeed > 0 ? Fmt.speed(t.uploadSpeed) : "—", secondary: t.uploadSpeed == 0)
            case .eta:
                // 下完了或者算不出来（没速度）都显示「—」
                let known = t.progress < 1 && t.eta > 0
                return plain(known ? Fmt.duration(t.eta) : "—", secondary: !known)
            case .peers: return plain("\(Fmt.count(t.seeds)) / \(Fmt.count(t.peers))", secondary: t.seeds == 0 && t.peers == 0)
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !settingColumns, let d = tableView.sortDescriptors.first, let key = d.key, let k = ColumnKey(rawValue: key) else { return }
            store.sortColumn = k
            store.ascending = d.ascending
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !restoringSelection, let table else { return }
            handlingSelection = true
            defer { handlingSelection = false }
            store.selection = Set(table.selectedRowIndexes.compactMap { $0 < store.order.count ? store.order[$0] : nil })
        }

        @objc func doubleClicked(_ sender: Any?) { model.showInspector = true }

        // MARK: 表头右键：选择显示哪些列

        func headerMenu() -> NSMenu {
            let m = NSMenu()
            m.identifier = NSUserInterfaceItemIdentifier("header")
            m.delegate = self
            return m
        }

        func rowMenu() -> NSMenu {
            let m = NSMenu()
            m.identifier = NSUserInterfaceItemIdentifier("row")
            m.delegate = self
            return m
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu.identifier?.rawValue == "header" { buildHeaderMenu(menu) } else { buildRowMenu(menu) }
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            let all = ColumnKey.all(for: set)
            let chosen = Set(model.prefs.columns[set].map { $0.compactMap(ColumnKey.init(rawValue:)) } ?? ColumnKey.defaults(for: set))
            let heading = set == "problem" ? L("Columns in problem views") : set == "downloading" ? L("Columns in the Downloading view") : L("Columns in regular views")
            let title = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for k in all {
                let it = NSMenuItem(title: k.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = k.rawValue
                it.state = chosen.contains(k) ? .on : .off
                it.isEnabled = k != .name
                menu.addItem(it)
            }
            menu.addItem(.separator())
            let reset = NSMenuItem(title: L("Restore Defaults"), action: #selector(resetColumns), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let k = ColumnKey(rawValue: raw) else { return }
            var cur = model.prefs.columns[set].map { $0.compactMap(ColumnKey.init(rawValue:)) } ?? ColumnKey.defaults(for: set)
            if let i = cur.firstIndex(of: k) { cur.remove(at: i) } else { cur.append(k) }
            model.prefs.columns[set] = cur.map(\.rawValue)
        }

        @objc func resetColumns() { model.prefs.columns[set] = nil }

        // MARK: 行右键

        private var targetRefs: [TorrentRef] {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                return clicked < store.order.count ? [store.order[clicked]] : []
            }
            return Array(store.selection)
        }

        private func buildRowMenu(_ menu: NSMenu) {
            let refs = targetRefs
            guard !refs.isEmpty else { return }
            let multi = refs.count > 1
            func add(_ title: String, _ action: Selector) {
                let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
                it.target = self
                menu.addItem(it)
            }
            add(multi ? L("Start (\(refs.count))") : L("Start"), #selector(start))
            add(multi ? L("Stop (\(refs.count))") : L("Stop"), #selector(stop))
            menu.addItem(.separator())
            add(L("Reannounce"), #selector(reannounce))
            add(L("Recheck"), #selector(recheck))
            add(L("Replace Tracker…"), #selector(retracker))
            menu.addItem(.separator())
            if refs.count == 1, let t = store.torrent(refs[0]) {
                add(L("Show Only “\(model.siteName(store.siteID(of: t)))”"), #selector(showSite))
                add(L("Copy Name"), #selector(copyName))
                if !t.infoHashV1.isEmpty { add(L("Copy Hash"), #selector(copyHash)) }
                menu.addItem(.separator())
            }
            add(multi ? L("Delete (\(refs.count))…") : L("Delete…"), #selector(delete))
        }

        @objc func start() { model.perform(.start, on: targetRefs) }
        @objc func stop() { model.perform(.stop, on: targetRefs) }
        @objc func recheck() { model.perform(.recheck, on: targetRefs) }
        @objc func reannounce() { model.perform(.reannounce, on: targetRefs); model.showToast(L("Reannounced \(Fmt.torrents(targetRefs.count))")) }
        @objc func delete() { model.requestDelete(targetRefs) }
        @objc func retracker() {
            let refs = targetRefs
            let site = refs.first.flatMap { store.torrent($0) }.map { store.siteID(of: $0) }
            model.sheet = .retracker(RetrackerDraft(model: model, siteID: site, selection: refs, scope: .selection))
        }
        @objc func showSite() {
            guard let ref = targetRefs.first, let t = store.torrent(ref) else { return }
            store.sidebar = .site(store.siteID(of: t))
        }
        @objc func copyName() {
            guard let ref = targetRefs.first, let t = store.torrent(ref) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.name, forType: .string)
        }
        @objc func copyHash() {
            guard let ref = targetRefs.first, let t = store.torrent(ref) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.infoHashV1, forType: .string)
        }
    }
}
