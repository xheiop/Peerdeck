import SwiftUI

/// 设置页最下面的「关于」：版本号、手动检查更新、仓库地址。
/// iOS 不自动检查：AltStore / SideStore 的源自己会提示更新，这里主要给 TrollStore 和手动安装的用。
/// 结果在这一节自己弹：设置是弹出的面板，根视图的提示会被它挡住。
struct AboutSection: View {
    @State private var checking = false
    @State private var outcome: UpdateCheck.Outcome?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("Version", value: UpdateCheck.versionLabel)
            Button {
                checking = true
                Task {
                    outcome = await UpdateCheck.check()
                    checking = false
                }
            } label: {
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
        } header: {
            Text("About")
        } footer: {
            Text("Peerdeck is free and open source, licensed under GPL-3.0-only.")
        }
        .alert(outcome?.title ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } }), presenting: outcome) { o in
            if case .available(let release, _) = o {
                Button("View Release") { openURL(release.page) }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { o in
            Text(o.message())
        }
        // 调试：TC_DEBUG_ABOUT_CHECK=1 时一出现就检查一次（配合 TC_DEBUG_UPDATE_JSON 不联网，截图用）
        .onAppear {
            if ProcessInfo.processInfo.environment["TC_DEBUG_ABOUT_CHECK"] != nil, outcome == nil, !checking {
                checking = true
                Task { outcome = await UpdateCheck.check(); checking = false }
            }
        }
    }
}
