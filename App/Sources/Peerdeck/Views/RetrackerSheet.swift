import SwiftUI
import TorrentKit

struct RetrackerSheet: View {
    let model: AppModel
    @Bindable var draft: RetrackerDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace Tracker · \(scopeTitle)").font(.title3.weight(.semibold))
            switch draft.phase {
            case .form: form
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Replacing \(Fmt.count(done)) / \(Fmt.count(total))… (qBittorrent needs one call per torrent)").foregroundStyle(.secondary)
            case .done: result
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(draft.phase != .form && draft.phase != .done)
    }

    private var scopeTitle: String {
        draft.scope == .site ? model.siteName(draft.siteID ?? "") : L("\(Fmt.torrents(draft.selectionRefs.count)) selected")
    }

    @ViewBuilder private var form: some View {
        Text("Use this when a site changes its domain or you reset your passkey. Only tracker URLs change; seeding data isn’t touched.").foregroundStyle(.secondary)
        let plan = draft.plan
        let targets = draft.targets
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Scope").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("", selection: $draft.scope) {
                    if let s = draft.siteID { Text("All torrents on \(model.siteName(s))").tag(RetrackerDraft.Scope.site) }
                    if !draft.selectionRefs.isEmpty { Text("Selected (\(Fmt.count(draft.selectionRefs.count)))").tag(RetrackerDraft.Scope.selection) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            GridRow {
                Text("Method").foregroundStyle(.secondary)
                Picker("", selection: $draft.mode) {
                    Text("Change domain").tag(RetrackerDraft.Mode.host)
                    Text("Change passkey").tag(RetrackerDraft.Mode.passkey)
                    Text("Custom").tag(RetrackerDraft.Mode.custom)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            GridRow {
                Text(draft.mode == .custom ? "Find" : "Current").foregroundStyle(.secondary)
                if draft.mode == .custom {
                    TextField("Text to replace in the URL", text: $draft.find)
                } else {
                    Text(draft.mode == .passkey ? RetrackerDraft.mask(draft.find) : (draft.find.isEmpty ? "—" : draft.find)).font(.body.monospaced())
                }
            }
            GridRow {
                Text(draft.mode == .host ? "New domain" : draft.mode == .passkey ? "New passkey" : "Replace with").foregroundStyle(.secondary)
                TextField(draft.mode == .host ? "e.g. tracker.new-domain.example" : draft.mode == .passkey ? "New passkey from your profile page on the site" : "Replacement text", text: $draft.replacement)
            }
        }
        let fixed = targets.filter { model.server($0.ref.server.rawValue)?.config.kind.canReplaceTrackers == false }.count
        if fixed > 0 {
            Label("\(fixed) on Flood won’t be changed: Flood can’t replace a single tracker URL safely.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let (from, to) = draft.preview {
            VStack(alignment: .leading, spacing: 3) {
                Text("− " + from).foregroundStyle(.secondary).strikethrough()
                Text("+ " + to)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        }
        let refs = Set(plan.map(\.ref))
        let byServer = Dictionary(grouping: refs, by: \.server).map { (model.server($0.key.rawValue)?.config.name ?? "", $0.value.count) }
        Text(draft.replacement.trimmingCharacters(in: .whitespaces).isEmpty ? L("Fill in the fields above to see which torrents will change")
             : refs.isEmpty ? L("No matching torrents")
             : targets.count > refs.count ? L("Will change \(Fmt.torrents(refs.count)): \(Fmt.breakdown(byServer)) · \(Fmt.count(targets.count - refs.count)) don’t match and won’t be changed")
             : L("Will change \(Fmt.torrents(refs.count)): \(Fmt.breakdown(byServer))"))
            .font(.callout).foregroundStyle(.secondary)
        Toggle("Reannounce after replacing", isOn: $draft.reannounce).toggleStyle(.checkbox)
        HStack {
            Text("You can switch back to the original URLs afterwards").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Replace on \(Fmt.torrents(refs.count))") { Task { await draft.run() } }
                .keyboardShortcut(.defaultAction)
                .disabled(refs.isEmpty)
        }
    }

    @ViewBuilder private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(draft.reannounce ? L("Replaced on \(Fmt.torrents(Set(draft.succeeded.map(\.ref)).count)) and reannounced") : L("Replaced on \(Fmt.torrents(Set(draft.succeeded.map(\.ref)).count))"), systemImage: "checkmark.circle.fill")
                .labelStyle(TintedIconLabel(color: .green))
            ForEach(draft.failures.prefix(5), id: \.self) { f in
                Label(f, systemImage: "exclamationmark.triangle.fill").labelStyle(TintedIconLabel(color: .red)).font(.callout)
            }
            if draft.failures.count > 5 { Text("…and \(draft.failures.count - 5) more failed").foregroundStyle(.secondary) }
            if draft.mode == .host, let s = draft.siteID, !draft.succeeded.isEmpty {
                Text("\(draft.find) is now recorded as an old domain of \(model.siteName(s)), so the site view and stats stay together.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).stroke(.separator))
        HStack {
            Spacer()
            Button("Switch Back") { Task { await draft.undo(); dismiss() } }.disabled(draft.succeeded.isEmpty)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}
