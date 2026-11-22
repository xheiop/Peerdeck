import SwiftUI
import TorrentKit

/// 菜单栏图标：总速度；有服务器故障时加角标
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 菜单栏标签一直存在，借它拿到 openWindow / openSettings，供 magnet 和横幅按钮用
        let _ = installOpeners()
        HStack(spacing: 2) {
            if !model.failedServers.isEmpty {
                Image(systemName: "exclamationmark.triangle")
            } else if model.altSpeedCount > 0 {
                Image(systemName: "tortoise.fill")
            } else {
                Image(nsImage: Self.glyph)
            }
            if model.totalDown > 0 || model.totalUp > 0 {
                Text("↓\(short(model.totalDown)) ↑\(short(model.totalUp))").monospacedDigit()
            }
        }
    }

    /// 平时的菜单栏图标：app 图标里的 P（碗里挖出菱形）。模板图，颜色跟随菜单栏。
    /// 坐标同 App/AppIcon.icon/Assets/P.svg 的 100 单位设计稿，取 14…86 这一块放进 18pt
    static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let k = rect.width / 72
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 14) * k, y: (y - 14) * k) }
            let p = NSBezierPath()
            p.move(to: pt(28, 50))
            p.appendArc(from: pt(28, 18), to: pt(53, 18), radius: 3 * k)
            p.line(to: pt(53, 18))
            p.appendArc(withCenter: pt(53, 38), radius: 20 * k, startAngle: -90, endAngle: 90, clockwise: false)
            p.line(to: pt(42, 58))
            p.appendArc(from: pt(42, 82), to: pt(28, 82), radius: 3 * k)
            p.appendArc(from: pt(28, 82), to: pt(28, 18), radius: 3 * k)
            p.close()
            p.move(to: pt(53, 29)); p.line(to: pt(62, 38)); p.line(to: pt(53, 47)); p.line(to: pt(44, 38)); p.close()
            p.windingRule = .evenOdd
            NSColor.black.setFill()
            p.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Peerdeck"
        return img
    }()

    private func installOpeners() {
        if model.openMainWindow == nil {
            let open = openWindow, settings = openSettings
            model.openMainWindow = { open(id: "main") }
            model.openSettingsWindow = { NSApp.activate(); settings() }
        }
    }

    private func short(_ v: Int64) -> String {
        v <= 0 ? "0" : ByteCountFormatter.string(fromByteCount: v, countStyle: .binary).replacingOccurrences(of: " ", with: "")
    }
}

struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let c = model.store.counts
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("↓ \(Fmt.speed(model.totalDown))")
                Text("↑ \(Fmt.speed(model.totalUp))")
            }
            .font(.headline).monospacedDigit()

            if c.rejected > 0 || c.unreachableLong > 0 {
                Button {
                    model.store.sidebar = c.unregistered > 0 ? .unregistered : .rejected
                    closePanel()
                    openMain()
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(c.unreachableLong > 0
                             ? L("Needs attention: \(Fmt.count(c.unregistered)) likely unregistered · \(Fmt.count(c.unreachableLong)) unreachable for long")
                             : L("Needs attention: \(Fmt.count(c.unregistered)) likely unregistered"))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            ForEach(model.servers) { rt in
                Divider()
                HStack {
                    ServerRow(runtime: rt, count: c.servers[rt.id] ?? 0)
                    if rt.status.isOnline, rt.config.kind.hasAlternativeSpeedLimits {
                        Toggle(isOn: Binding(get: { rt.stats.altSpeedEnabled }, set: { model.setAltSpeed($0, server: rt.id) })) {
                            Image(systemName: "tortoise")
                        }
                        .toggleStyle(.switch).controlSize(.mini)
                        .help("Alternative speed limits for \(rt.config.name)")
                    } else if case .failed = rt.status {
                        Button("Edit…") {
                            model.settingsTab = "servers"
                            model.settingsServerFocus = rt.id
                            closePanel()
                            model.openSettingsWindow?()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Divider()
            HStack {
                // 先收起面板再开别的窗口：面板还是 key 窗口时 Esc 才能把它正常收起
                Button("Open Window") { closePanel(); openMain() }
                Button("Add Torrents…") { closePanel(); model.beginAdd() }
                Spacer()
                Button("Settings…") { closePanel(); model.openSettingsWindow?() }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func openMain() {
        NSApp.activate()
        openWindow(id: "main")
    }

    /// MenuBarExtra 的 .window 样式没有收起面板的 API：跳到别的窗口后面板会一直挂着。
    /// 直接 close() 会让菜单栏图标以为面板还开着，下次要点两下才出来；给面板发 Esc 事件也收不起来（实测）。
    /// 这里等于替用户点一下菜单栏图标，走的是正常的收起路径
    private func closePanel() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let button = w.contentView.flatMap(Self.statusButton) { button.performClick(nil); return }
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = statusButton(in: sub) { return b } }
        return nil
    }
}
