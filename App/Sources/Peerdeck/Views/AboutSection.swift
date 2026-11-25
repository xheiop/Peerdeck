import SwiftUI

/// 「关于」：版本号、手动检查更新、仓库地址、许可证和 TMDB 署名。
/// iOS 放在设置页最下面；mac 放在设置的「关于」标签页（AboutTab），和「关于 Peerdeck」面板内容一致。
/// iOS 不自动检查：AltStore / SideStore 的源自己会提示更新，这里主要给 TrollStore 和手动安装的用。
/// 结果在这一节自己弹：iOS 的设置是弹出的面板，根视图的提示会被它挡住；mac 的设置是单独的窗口，结果也该弹在这里
struct AboutSection: View {
    @State private var checking = false
    @State private var outcome: UpdateCheck.Outcome?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("Version", value: UpdateCheck.versionLabel)
            #if os(macOS)
            LabeledContent("Updates") {
                HStack {
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check for Updates", action: check).disabled(checking)
                }
            }
            LabeledContent("Source Code") {
                Link("github.com/xheiop/Peerdeck", destination: UpdateCheck.repository)
            }
            #else
            Button(action: check) {
                HStack {
                    Text("Check for Updates")
                    Spacer()
                    if checking { ProgressView() }
                }
            }
            .disabled(checking)
            Link(destination: UpdateCheck.repository) {
                LabeledContent("Source Code", value: "GitHub")
            }
            #endif
        } header: {
            #if os(iOS)
            Text("About")
            #endif
        } footer: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Peerdeck is free and open source, licensed under GPL-3.0-only.")
                // TMDB 的使用条款要求注明来源
                TMDBAttribution()
            }
            .footnoteStyle()
        }
        .alert(outcome?.title ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } }), presenting: outcome) { o in
            if case .available(let release, _) = o {
                Button("View Release") { openURL(release.page) }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { o in
            #if os(macOS)
            Text(o.message(homebrew: UpdateCheck.installedWithHomebrew))
            #else
            Text(o.message())
            #endif
        }
        // 调试：TC_DEBUG_ABOUT_CHECK=1 时一出现就检查一次（配合 TC_DEBUG_UPDATE_JSON 不联网，截图用）
        .onAppear {
            if ProcessInfo.processInfo.environment["TC_DEBUG_ABOUT_CHECK"] != nil, outcome == nil, !checking { check() }
        }
    }

    private func check() {
        checking = true
        Task {
            outcome = await UpdateCheck.check()
            checking = false
        }
    }
}
