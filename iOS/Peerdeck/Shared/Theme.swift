import SwiftUI
import UIKit

// v3 视觉规则：白底墨字；颜色只表示 tracker 健康度，只出现在小形状上；
// 操作和开关一律墨色。色值取 Apple 系统色的高对比版本。

extension Color {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    /// 疑似未注册（琥珀）
    static let healthUnregistered = dynamic(0xB25000, 0xFFB340)
    /// 被拒绝（红）
    static let healthRejected = dynamic(0xD70015, 0xFF453A)
    /// 主操作的墨色填充，以及上面的字色
    static let ink = Color.primary
    static let onInk = Color(uiColor: .systemBackground)
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 下载器本地出错（文件丢失、磁盘满等，和 tracker 无关）：红色带叹号的三角，和「被拒绝」的实心三角区分开
enum LocalErrorMark {
    static var view: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.healthRejected)
            .accessibilityLabel(Text(LocalErrorCopy.title))
    }
}

/// 健康度的小形状：琥珀菱形 = 疑似未注册，红三角 = 被拒绝，空心圆 = tracker 超时。形状和颜色一起表达，色弱也分得开
enum HealthMark {
    case unregistered, rejected, timeout

    @ViewBuilder var view: some View {
        switch self {
        case .unregistered:
            Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(Color.healthUnregistered)
        case .rejected:
            Image(systemName: "triangle.fill").font(.system(size: 10)).foregroundStyle(Color.healthRejected)
        case .timeout:
            Image(systemName: "circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

/// 账本行：左边一条右对齐的数字列，右边是内容。只用在「数量就是答案」的地方（总览的问题堆、清理面板的分组）。
/// 数字列按位数定宽（同一组行传同一个 digits，数字才对得齐），不再固定 96pt 吃掉正文宽度。
/// 列宽是实测的：用同字体、同位数的一串 0 占位（隐藏），不同系统、不同字号下都刚好放得下，数字不会折行
struct LedgerRow<Number: View, Content: View>: View {
    let digits: Int
    /// 数字用的是 .ledgerSmall
    let small: Bool
    let alignment: VerticalAlignment
    @ViewBuilder let number: Number
    @ViewBuilder let content: Content

    init(digits: Int, small: Bool = false, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder number: () -> Number, @ViewBuilder content: () -> Content) {
        self.digits = digits
        self.small = small
        self.alignment = alignment
        self.number = number()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            // 占位的 0 串决定列宽和基线；真正的数字叠在上面右对齐
            LedgerColumnTemplate(digits: digits, small: small)
                .overlay(alignment: .trailing) { number.lineLimit(1).fixedSize() }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
    }
}

/// 数字列的宽度模板：等宽数字，每位一样宽，用 0 填满位数（千分位逗号比数字窄，按一位算会略宽一点）
private struct LedgerColumnTemplate: View {
    let digits: Int
    let small: Bool
    var body: some View {
        Text(verbatim: String(repeating: "0", count: max(digits, 1)))
            .font(small ? .ledgerSmall : .ledgerLarge)
            .lineLimit(1).fixedSize()
            .hidden()
            .accessibilityHidden(true)
    }
}

/// 一组数里最长的位数（千分位逗号按一位算），给同一组 LedgerRow / LedgerSeparator 用
func ledgerDigits(_ counts: [Int]) -> Int { counts.map { Fmt.count($0).count }.max() ?? 1 }

/// 账本里的分隔线：从文字列开始（iOS 内缩分隔线），不画通栏线
struct LedgerSeparator: View {
    let digits: Int
    var small = false
    var body: some View {
        HStack(spacing: 12) {
            LedgerColumnTemplate(digits: digits, small: small).frame(height: 0)
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
        }
        .padding(.leading, 20)
    }
}

/// 普通列表行之间的分隔线：从左边距开始
struct InsetSeparator: View {
    var leading: CGFloat = 20
    var body: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, leading)
    }
}

/// 小号灰色组标题
struct LedgerHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Font {
    /// 问题堆的计数
    static let ledgerLarge = Font.system(.largeTitle, weight: .semibold).monospacedDigit()
    /// 其余行的计数
    static let ledgerSmall = Font.system(.title2, weight: .semibold).monospacedDigit()
    /// tracker 原话
    static let quote = Font.system(.callout, design: .monospaced)
    /// 速度等数字
    static let data = Font.system(.footnote, design: .monospaced)
}
