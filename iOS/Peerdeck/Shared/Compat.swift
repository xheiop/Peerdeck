import SwiftUI

// 最低支持 iOS 17。iOS 26 的玻璃、iOS 18 的 Tab 等新 API 都包在这里，
// 调用处只写一个修饰符；老系统退回到 material 底 / 普通写法，布局不变。

extension View {
    /// 胶囊形玻璃。iOS 26 以下用 regularMaterial 胶囊代替
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        }
    }

    /// 玻璃元素的融合动画 ID；iOS 26 以下没有这个效果，直接忽略
    @ViewBuilder
    func glassID(_ id: some Hashable & Sendable, in ns: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: ns)
        } else {
            self
        }
    }

    /// 底部固定操作区。iOS 26 用 safeAreaBar（带边缘模糊），以下用 safeAreaInset + material 底
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: bar)
        } else {
            safeAreaInset(edge: .bottom) {
                bar().padding(.top, 8).frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    /// 下滑时收起标签栏，iOS 26 才有
    @ViewBuilder
    func minimizeTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// GlassEffectContainer 的包装：iOS 26 以下就是原样的内容
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
