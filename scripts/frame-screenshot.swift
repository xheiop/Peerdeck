#!/usr/bin/env swift
// 给 README 用的截图加展示效果：渐变背景、标题、圆角和阴影；iPhone 截图另外画一圈机身边框。
// 参考 App Store 截图的常见做法（上面一行大标题、一行说明，下面是设备）和 macshot 的美化（留白、圆角、阴影）。
//
//   swift scripts/frame-screenshot.swift mac <窗口截图.png> <输出.png> "<标题>" "<说明>"
//   swift scripts/frame-screenshot.swift ios <模拟器截图.png> <输出.png> "<标题>" "<说明>"
//
// mac 的窗口截图用 app 的 TC_SNAPSHOT 调试开关拍（2 倍图，没有圆角和阴影）；
// iPhone 用 xcrun simctl io <设备> screenshot 拍（全屏、方角）。标题和说明可以留空。
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, ["mac", "ios"].contains(args[1]) else {
    FileHandle.standardError.write(Data("用法：frame-screenshot.swift mac|ios <输入.png> <输出.png> [标题] [说明]\n".utf8))
    exit(1)
}
let kind = args[1]
let title = args.count > 4 ? args[4] : ""
let subtitle = args.count > 5 ? args[5] : ""
guard let source = NSImage(contentsOfFile: args[2]), let shot = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("读不了 \(args[2])\n".utf8))
    exit(1)
}

let w = CGFloat(shot.width), h = CGFloat(shot.height)
let isMac = kind == "mac"
// 设备在画布里的大小和留白都按截图宽度算，2 倍图和 3 倍图出来的比例一样
let unit = w / (isMac ? 100 : 40)
let bezel = isMac ? 0 : unit * 1.3
let deviceW = w + bezel * 2, deviceH = h + bezel * 2
let side = isMac ? unit * 6 : unit * 3.2
let hasText = !title.isEmpty || !subtitle.isEmpty
let titleSize = isMac ? unit * 3.0 : unit * 2.9
let subtitleSize = titleSize * (isMac ? 0.52 : 0.6)
let textBlock: CGFloat = hasText ? titleSize * 1.25 + (subtitle.isEmpty ? 0 : subtitleSize * 1.9) + unit * (isMac ? 3 : 2.4) : 0
let top = (isMac ? unit * 5 : unit * 3.6) + textBlock
let bottom = isMac ? unit * 6 : unit * 3.4
let canvas = CGSize(width: deviceW + side * 2, height: deviceH + top + bottom)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 背景：暖色浅渐变（和图标的黑底橙色呼应），右上角再叠一团淡淡的橙色光
let bg = CGGradient(colorsSpace: space, colors: [color(0xFBF7F1), color(0xEFE4D4)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0xF2A65A, 0.28), color(0xF2A65A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: canvas.width * 0.85, y: canvas.height * 0.9), startRadius: 0,
                       endCenter: CGPoint(x: canvas.width * 0.85, y: canvas.height * 0.9), endRadius: canvas.width * 0.7, options: [])

// 标题和说明（居中）
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, centerY: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .paragraphStyle: p])
    let bounds = s.boundingRect(with: CGSize(width: canvas.width - side * 2, height: size * 3), options: [.usesLineFragmentOrigin])
    s.draw(with: CGRect(x: side, y: centerY - bounds.height / 2, width: canvas.width - side * 2, height: bounds.height), options: [.usesLineFragmentOrigin])
}
if hasText {
    var y = canvas.height - (isMac ? unit * 5 : unit * 3.6) - titleSize * 0.6
    if !title.isEmpty {
        draw(title, size: titleSize, weight: .bold, color: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1), centerY: y)
        y -= titleSize * 0.65 + subtitleSize * 1.3
    }
    if !subtitle.isEmpty {
        draw(subtitle, size: subtitleSize, weight: .regular, color: NSColor(srgbRed: 0.36, green: 0.33, blue: 0.30, alpha: 1), centerY: y)
    }
}

// 设备：阴影 → 机身（iPhone）→ 截图（圆角裁切）→ 细描边
let device = CGRect(x: side, y: bottom, width: deviceW, height: deviceH)
let outerRadius = isMac ? unit * 1.25 : unit * 6.2
let screenRadius = isMac ? outerRadius : outerRadius - bezel
let screen = device.insetBy(dx: bezel, dy: bezel)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -unit * 1.2), blur: unit * 4, color: color(0x3A2A18, 0.28))
ctx.addPath(CGPath(roundedRect: device, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
ctx.setFillColor(isMac ? color(0xFFFFFF) : color(0x111111))
ctx.fillPath()
ctx.restoreGState()

if !isMac {
    // 机身外沿一圈浅色金属边
    ctx.addPath(CGPath(roundedRect: device.insetBy(dx: unit * 0.12, dy: unit * 0.12), cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
    ctx.setStrokeColor(color(0x8A8580, 0.9))
    ctx.setLineWidth(unit * 0.24)
    ctx.strokePath()
}

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.clip()
ctx.draw(shot, in: screen)
ctx.restoreGState()

if isMac {
    ctx.addPath(CGPath(roundedRect: device.insetBy(dx: 0.5, dy: 0.5), cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
    ctx.setStrokeColor(color(0x000000, 0.14))
    ctx.setLineWidth(max(1, unit * 0.06))
    ctx.strokePath()
}

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print(args[3], Int(canvas.width), "×", Int(canvas.height))
