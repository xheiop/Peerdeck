import SwiftUI
import TorrentKit

/// 清理「疑似未注册」的确认面板：按 tracker 原话分组，有辅种的自动保留。确认后进 10 秒撤销窗口
struct CleanupScreen: View {
    let model: AppModel
    @State private var plan: CleanupPlan
    @State private var keepFiles = true
    @State private var expanded: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _plan = State(initialValue: model.cleanupPlan())
    }

    var body: some View {
        let n = plan.removable.count
        let blockers = model.fileCheckBlockers
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
                    ForEach(Array(plan.groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { LedgerSeparator(digits: digits, small: true) }
                        groupRow(g)
                    }
                    if !plan.kept.isEmpty {
                        if !plan.groups.isEmpty { LedgerSeparator(digits: digits, small: true) }
                        keptRow
                    }
                    if blockers.isEmpty {
                        Toggle(isOn: $keepFiles) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Files").font(.subheadline)
                                Text("Only remove from the client; files on disk stay").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color.ink)
                        .padding(.horizontal, 20).padding(.vertical, 12).padding(.top, 12)
                    } else {
                        Text(L("Files can’t be deleted while \(blockers.joined(separator: L(", "))) is unavailable: its torrents might use the same files."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.top, 24)
                    }
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("Clean Up Likely Unregistered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
            .bottomBar {
                VStack(spacing: 8) {
                    Button { confirm() } label: {
                        Text(L("Remove \(Fmt.count(n))")).font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .foregroundStyle(Color.onInk)
                    .background(Color.ink.opacity(n == 0 ? 0.3 : 1), in: .capsule)
                    .disabled(n == 0)
                    Text("You can undo within 10 seconds").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .presentationDetents([.fraction(0.75), .large])
        // iOS 26 的半高面板默认是半透明玻璃；这里是要读的确认内容，用实底
        .presentationBackground(Color(uiColor: .systemBackground))
        .presentationDragIndicator(.visible)
    }

    /// 分组数字列的位数（数字是 .ledgerSmall）
    private var digits: Int { ledgerDigits(plan.groups.map(\.refs.count) + [plan.kept.count]) }

    private var summary: String {
        let n = plan.removable.count, k = plan.kept.count
        if n == 0 { return k == 0 ? L("Nothing to clean up right now.") : L("All \(Fmt.count(k)) have cross-seeds and are kept.") }
        return k == 0 ? L("Remove all \(Fmt.count(n)).") : L("Remove \(Fmt.count(n)) of them; the \(Fmt.count(k)) with cross-seeds stay.")
    }

    private func groupRow(_ g: CleanupPlan.Group) -> some View {
        let open = expanded.contains(g.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth) { if open { expanded.remove(g.id) } else { expanded.insert(g.id) } }
            } label: {
                LedgerRow(digits: digits, small: true, alignment: .center) {
                    Text(Fmt.count(g.refs.count)).font(.ledgerSmall)
                } content: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.message.isEmpty ? L("(no message)") : g.message).font(.quote).lineLimit(2).multilineTextAlignment(.leading)
                            Text(g.sites.map { "\($0.0) \($0.1)" }.joined(separator: L(", "))).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(open ? "Hide torrents" : "Show torrents"))
            if open { names(g.refs) }
        }
    }

    private var keptRow: some View {
        let open = expanded.contains("kept")
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth) { if open { expanded.remove("kept") } else { expanded.insert("kept") } }
            } label: {
                LedgerRow(digits: digits, small: true, alignment: .center) {
                    Text(Fmt.count(plan.kept.count)).font(.ledgerSmall).foregroundStyle(.secondary)
                } content: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kept").font(.subheadline)
                            Text(plan.keptElsewhere.isEmpty ? L("Their data is shared with other torrents")
                                 : L("Data still seeding on \(plan.keptElsewhere.prefix(3).joined(separator: L(" and ")))"))
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { names(plan.kept) }
        }
    }

    /// 展开后列出种子名（名字比原话更长，用正文字体）
    private func names(_ refs: [TorrentRef]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(refs, id: \.self) { ref in
                Text(model.store.all[ref]?.name ?? "—").font(.footnote).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private func confirm() {
        // 面板是打开那一刻的快照：确认时只删现在仍然符合的，也不会多删没给用户看过的
        let current = Set(model.cleanupPlan().removable)
        let refs = plan.removable.filter(current.contains)
        guard !refs.isEmpty else {
            model.showToast(L("Nothing to clean up right now."))
            dismiss()
            return
        }
        let withFiles = !keepFiles && model.fileCheckBlockers.isEmpty
        let what = Fmt.torrents(refs.count)
        model.scheduleDelete(refs, deleteDataFor: withFiles ? Set(refs) : [],
                             label: withFiles ? L("\(what) (with files)") : L("\(what) (keeping files)"),
                             keep: plan.kept, cleanup: true)
        dismiss()
    }
}

/// 撤销窗口里的底部附件条：倒计时圈 + 「已移除 N 个」+ 撤销。只在 10 秒窗口里出现
struct UndoAccessory: View {
    let model: AppModel
    /// 收进标签栏时用短文案（见 PlacedUndoAccessory）
    var short = false

    var body: some View {
        if let p = model.pending {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: CGFloat(p.secondsLeft) / 10)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: p.secondsLeft)
                    Text(verbatim: "\(p.secondsLeft)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Text(text(p)).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                Button("Undo") { model.undoDelete() }.font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
        }
    }

    private func text(_ p: PendingDeletion) -> String {
        let n = Fmt.count(p.refs.count)
        if short { return L("Removed \(n)") }
        return p.dataRefs.isEmpty ? L("Removed \(n), files still there") : L("Removed \(n) with files")
    }
}
