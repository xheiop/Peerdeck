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
        // TMDB 的使用条款要求注明来源：官方 logo 加一句声明
        credits.append(NSAttributedString(string: "\n\n", attributes: [.font: font, .paragraphStyle: center]))
        if let logo = NSImage(named: "TMDBLogo") {
            let attachment = NSTextAttachment()
            attachment.image = logo
            let height: CGFloat = 9
            attachment.bounds = CGRect(x: 0, y: 0, width: height * logo.size.width / max(logo.size.height, 1), height: height)
            let line = NSMutableAttributedString(attachment: attachment)
            line.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: line.length))
            credits.append(line)
            credits.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: center]))
        }
        credits.append(NSAttributedString(string: L("This product uses the TMDB API but is not endorsed or certified by TMDB."), attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 xheiop",
        ])
        NSApp.activate()
    }
}
