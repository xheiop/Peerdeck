import SwiftUI
import TorrentKit
import UIKit

/// 主列表。和 mac 的 NSTableView 一样，只刷新可见的变化行：SwiftUI List 在 2 万行时每次更新都要整体 diff（M0 实测卡 0.2–0.5 s）。
/// 单元格内容用 UIHostingConfiguration 画（TorrentRow）。
struct TorrentTableView: UIViewRepresentable {
    let model: AppModel
    let editing: Bool
    /// 外部改了选择（全选、退出编辑）时触发 updateUIView
    let selectionRevision: Int
    /// 问题视图用另一种行布局（显示问题和 tracker 消息）
    let problemLayout: Bool
    let onOpen: (TorrentRef) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        let c = context.coordinator
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.dataSource = c
        table.delegate = c
        table.allowsMultipleSelectionDuringEditing = true
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.keyboardDismissMode = .onDrag
        c.table = table
        c.problemLayout = problemLayout
        model.store.observeUpdates(c) { [weak c] update in c?.apply(update) }
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let c = context.coordinator
        c.onOpen = onOpen
        if c.problemLayout != problemLayout {
            c.problemLayout = problemLayout
            table.reloadData()
        }
        if table.isEditing != editing { table.setEditing(editing, animated: true) }
        // 放到下一轮：这里可能正处在表格自己的回调里
        DispatchQueue.main.async { c.syncSelection() }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        let model: AppModel
        weak var table: UITableView?
        var problemLayout = false
        var onOpen: (TorrentRef) -> Void = { _ in }
        private var syncing = false

        init(model: AppModel) { self.model = model }
        var store: TorrentStore { model.store }

        func apply(_ update: TableUpdate) {
            guard let table else { return }
            switch update {
            case .reloadAll:
                table.reloadData()
                syncSelection()
            case .rows(let rows):
                let visible = (table.indexPathsForVisibleRows ?? []).filter { rows.contains($0.row) }
                if !visible.isEmpty { table.reconfigureRows(at: visible) }
            }
        }

        /// 编辑模式下把 store 里的选择同步到表格
        func syncSelection() {
            guard let table, table.isEditing else { return }
            syncing = true
            defer { syncing = false }
            let want = Set(store.selection.compactMap { store.row(of: $0) })
            let have = Set((table.indexPathsForSelectedRows ?? []).map(\.row))
            for r in have.subtracting(want) { table.deselectRow(at: IndexPath(row: r, section: 0), animated: false) }
            for r in want.subtracting(have) { table.selectRow(at: IndexPath(row: r, section: 0), animated: false, scrollPosition: .none) }
        }

        private func ref(_ ip: IndexPath) -> TorrentRef? { ip.row < store.order.count ? store.order[ip.row] : nil }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { store.order.count }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            if let ref = ref(indexPath), let t = store.torrent(ref) {
                cell.contentConfiguration = UIHostingConfiguration { TorrentRow(model: model, torrent: t, problemLayout: problemLayout) }
                    .margins(.vertical, 8)
            }
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            if tableView.isEditing {
                if !syncing, let ref = ref(indexPath) { store.selection.insert(ref) }
                return
            }
            tableView.deselectRow(at: indexPath, animated: true)
            if let ref = ref(indexPath) { onOpen(ref) }
        }

        func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
            if tableView.isEditing, !syncing, let ref = ref(indexPath) { store.selection.remove(ref) }
        }

        // 左滑：开始 / 停止、删除；右滑：重新汇报
        func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let ref = ref(indexPath), let t = store.torrent(ref) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: L("Delete")) { [model] _, _, done in
                model.requestDelete([ref]); done(false)
            }
            delete.image = UIImage(systemName: "trash")
            let stopped = t.state == .stopped
            let run = UIContextualAction(style: .normal, title: stopped ? L("Start") : L("Stop")) { [model] _, _, done in
                model.toggleRun([ref]); done(true)
            }
            run.image = UIImage(systemName: stopped ? "play.fill" : "pause.fill")
            run.backgroundColor = .systemIndigo
            return UISwipeActionsConfiguration(actions: [delete, run])
        }

        func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let ref = ref(indexPath) else { return nil }
            let re = UIContextualAction(style: .normal, title: L("Reannounce")) { [model] _, _, done in
                model.perform(.reannounce, on: [ref]); model.showToast(L("Reannounced")); done(true)
            }
            re.image = UIImage(systemName: "arrow.clockwise")
            re.backgroundColor = .systemTeal
            return UISwipeActionsConfiguration(actions: [re])
        }

        func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard !tableView.isEditing, let ref = ref(indexPath), let t = store.torrent(ref) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [model] _ in
                UIMenu(children: [
                    UIAction(title: L("Start"), image: UIImage(systemName: "play")) { _ in model.perform(.start, on: [ref]) },
                    UIAction(title: L("Stop"), image: UIImage(systemName: "pause")) { _ in model.perform(.stop, on: [ref]) },
                    UIAction(title: L("Reannounce"), image: UIImage(systemName: "arrow.clockwise")) { _ in model.perform(.reannounce, on: [ref]); model.showToast(L("Reannounced")) },
                    UIAction(title: L("Recheck"), image: UIImage(systemName: "checkmark.arrow.trianglehead.counterclockwise")) { _ in model.perform(.recheck, on: [ref]) },
                    UIAction(title: L("Set Location…"), image: UIImage(systemName: "folder")) { _ in model.requestSetLocation([ref]) },
                    UIMenu(options: .displayInline, children: [
                        UIAction(title: L("Show Only “\(model.siteName(model.store.siteID(of: t)))”"), image: UIImage(systemName: "globe")) { _ in model.store.sidebar = .site(model.store.siteID(of: t)) },
                        UIAction(title: L("Copy Name"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = t.name },
                    ]),
                    UIAction(title: L("Delete…"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in model.requestDelete([ref]) },
                ])
            }
        }
    }
}
