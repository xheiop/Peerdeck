import SwiftUI
import TorrentKit

/// 备用限速开关（每台服务器一个）。具体限速数值在 mac 上改
struct SpeedScreen: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.onlineServers.isEmpty {
                    Text("No servers online").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(model.onlineServers) { rt in
                            Toggle(isOn: Binding(get: { rt.stats.altSpeedEnabled }, set: { model.setAltSpeed($0, server: rt.id) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rt.config.name)
                                    Text("↓ \(Fmt.speed(rt.stats.downloadSpeed))  ↑ \(Fmt.speed(rt.stats.uploadSpeed))")
                                        .font(.data).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alternative")
                            Text("Switch between normal and alternative limits").font(.footnote).foregroundStyle(.secondary).textCase(nil)
                        }
                    }
                    Section {
                        Button("Alternative On for All") { model.setAltSpeed(true) }
                        Button("Off for All") { model.setAltSpeed(false) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Speed Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // 半高面板默认是半透明玻璃，这里有开关要读，用实底
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}
