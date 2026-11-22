import SwiftUI
import TorrentKit

/// 工具栏「限速」弹窗：每台服务器的全局限速、备用限速数值，以及备用限速开关
struct SpeedLimitsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Speed Limits").font(.headline).frame(width: Self.labelWidth, alignment: .leading)
                Text("↓ Download").frame(width: Self.fieldWidth, alignment: .trailing)
                Text("↑ Upload").frame(width: Self.fieldWidth, alignment: .trailing)
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.bottom, 10)
            if model.onlineServers.isEmpty {
                Text("No servers online").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.onlineServers) { rt in
                            ServerLimitsEditor(model: model, runtime: rt)
                            if rt.id != model.onlineServers.last?.id { Divider().padding(.vertical, 10) }
                        }
                    }
                }
                .contentMargins(.trailing, 14, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.vertical, 10)
            HStack {
                Text("KB/s · empty means unlimited").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Alternative On for All") { model.setAltSpeed(true) }.controlSize(.small)
                Button("Off for All") { model.setAltSpeed(false) }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    static let labelWidth: CGFloat = 150
    static let fieldWidth: CGFloat = 100
}

private struct ServerLimitsEditor: View {
    let model: AppModel
    let runtime: ServerRuntime
    @State private var loaded: SpeedLimits?
    @State private var down = ""
    @State private var up = ""
    @State private var altDown = ""
    @State private var altUp = ""
    @State private var error: String?
    @State private var saving = false

    private var isTR: Bool { runtime.config.kind == .transmission }
    private var alt: Bool { runtime.stats.altSpeedEnabled }
    private var hasAlt: Bool { runtime.config.kind.hasAlternativeSpeedLimits }

    private var edited: SpeedLimits {
        SpeedLimits(download: Self.bytes(down), upload: Self.bytes(up), altDownload: Self.bytes(altDown), altUpload: Self.bytes(altUp))
    }
    private var dirty: Bool { loaded != nil && edited != loaded }
    /// TR 的备用限速没有「不限」，0 就是真的 0
    private var invalid: Bool { isTR && (edited.altDownload == 0 || edited.altUpload == 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runtime.config.name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                if hasAlt {
                    Toggle(isOn: Binding(get: { alt }, set: { model.setAltSpeed($0, server: runtime.id) })) {
                        Label("Alternative", systemImage: alt ? "tortoise.fill" : "tortoise")
                    }
                    .toggleStyle(.button)
                    .help("Switch between normal and alternative limits")
                }
            }
            if loaded == nil, error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    row(L("Normal"), active: !alt, $down, $up, placeholder: L("Unlimited"))
                    if hasAlt { row(L("Alternative"), active: alt, $altDown, $altUp, placeholder: isTR ? L("Required") : L("Unlimited")) }
                }
                HStack {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    } else if invalid {
                        Text("Transmission’s alternative limits can’t be unlimited").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    if dirty {
                        Button("Revert") { if let loaded { fill(loaded) } }.controlSize(.small)
                    }
                    Button("Apply") { Task { await apply() } }
                        .controlSize(.small)
                        .keyboardShortcut(dirty ? .defaultAction : nil)
                        .disabled(!dirty || invalid || saving)
                }
            }
        }
        .task(id: runtime.id) { await load() }
    }

    private func row(_ title: String, active: Bool, _ d: Binding<String>, _ u: Binding<String>, placeholder: String) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(title).fontWeight(active ? .semibold : .regular)
                if active { Text("In Use").font(.caption2).padding(.horizontal, 4).padding(.vertical, 1).background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint) }
            }
            .frame(width: SpeedLimitsView.labelWidth, alignment: .leading)
            field(d, placeholder)
            field(u, placeholder)
        }
    }

    private func field(_ text: Binding<String>, _ placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(placeholder))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: SpeedLimitsView.fieldWidth)
            .onSubmit { if dirty, !invalid { Task { await apply() } } }
    }

    private func load() async {
        guard let client = runtime.client else { error = L("Not connected yet"); return }
        do { let l = try await client.speedLimits(); loaded = l; fill(l); error = nil }
        catch { self.error = "\(error)" }
    }

    private func fill(_ l: SpeedLimits) {
        down = Self.text(l.download); up = Self.text(l.upload)
        altDown = Self.text(l.altDownload); altUp = Self.text(l.altUpload)
    }

    private func apply() async {
        guard let client = runtime.client else { return }
        saving = true
        defer { saving = false }
        let want = edited
        do {
            try await client.setSpeedLimits(want)
            let got = try await client.speedLimits()
            loaded = got; fill(got); error = nil
            model.showToast(L("Speed limits updated: \(runtime.config.name)"))
            runtime.refreshNow()
        } catch {
            self.error = "\(error)"
        }
    }

    static func text(_ bps: Int64) -> String { bps > 0 ? String(bps / 1024) : "" }
    static func bytes(_ s: String) -> Int64 {
        let digits = s.filter(\.isNumber)
        return max(0, Int64(digits) ?? 0) * 1024
    }
}
