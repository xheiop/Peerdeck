import SwiftUI

/// 设置里的「影视信息」：开关、自己的 TMDB 密钥、清缓存。mac「通用」和 iOS 设置共用
struct MediaSettingsSection: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        @Bindable var media = media
        Section {
            Toggle("Show movie and TV info in torrent details", isOn: $media.enabled)
            #if os(macOS)
            SecureField("Your TMDB API key", text: $key, prompt: Text(media.builtInKey == nil ? "Required" : "Optional"))
                .onSubmit(save)
            #else
            // iOS 表单里的 SecureField 不显示标题，用和服务器编辑页一样的带标题输入框
            FormField(L("Your TMDB API key"), text: $key, prompt: media.builtInKey == nil ? L("Required") : L("Optional"), secure: true)
            #endif
            HStack {
                Button("Save Key", action: save).disabled(busy || key == media.userKey)
                Button("Test") { Task { busy = true; message = await media.testActiveKey() ?? L("The key works."); busy = false } }
                    .disabled(busy || media.activeKey == nil)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Get a Key…") { openURL(URL(string: "https://www.themoviedb.org/settings/api")!) }
            }
            #if os(macOS)
            .buttonStyle(.bordered)
            #else
            .buttonStyle(.borderless)
            #endif
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Button("Clear Movie Info Cache") { media.clearCache(); message = L("Cache cleared.") }
        } header: {
            Text("Movie & TV Info")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When on, torrent names are sent to TMDB to look up posters and plots.")
                if media.builtInKey == nil {
                    Text("This build has no built-in key, so enter your own (free at themoviedb.org).")
                } else {
                    Text("Leave the key empty to use the built-in one.")
                }
            }
            .footnoteStyle()
        }
        .onAppear { key = media.userKey }
    }

    private func save() {
        busy = true
        message = nil
        Task {
            if let err = await media.saveUserKey(key) {
                message = err
            } else {
                message = key.isEmpty ? L("Using the built-in key.") : L("Key saved.")
            }
            busy = false
        }
    }
}
