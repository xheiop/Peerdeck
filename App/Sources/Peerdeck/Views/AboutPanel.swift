import AppKit

/// 「关于 Peerdeck」：系统的关于面板（图标、名字、版本号来自 Info.plist），加上仓库地址、许可证和版权
enum AboutPanel {
    @MainActor static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(string: "github.com/xheiop/Peerdeck", attributes: [
            .link: UpdateCheck.repository, .font: font, .paragraphStyle: center,
        ])
        credits.append(NSAttributedString(string: "\n" + L("Free and open source, licensed under GPL-3.0-only."), attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 xheiop",
        ])
        NSApp.activate()
    }
}
