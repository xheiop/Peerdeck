import SwiftUI
import TorrentKit

/// 服务器一行：状态图标、名称、版本 · 线路 · 剩余空间 · 上传速度。侧栏、菜单栏、设置页，以及 iOS 共用
struct ServerRow: View {
    let runtime: ServerRuntime
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.config.name).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if count > 0 { Text(Fmt.count(count)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        #if os(iOS)
        // iOS v3：颜色只留给 tracker 健康度，这里只用形状（实心点 = 在线，插头 = 离线，锁 = 证书）
        switch runtime.status {
        case .online: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.primary)
        case .connecting: ProgressView().controlSize(.mini)
        case .stopped: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "powerplug.portrait").foregroundStyle(.secondary)
        case .needsTrust: Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.secondary)
        }
        #else
        // 形状和颜色一起表达状态
        switch runtime.status {
        case .online: Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.green)
        case .connecting: ProgressView().controlSize(.mini)
        case .stopped: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .needsTrust: Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
        }
        #endif
    }

    private var subtitle: String {
        switch runtime.status {
        case .online(_, let ep):
            let v = runtime.info.map { "\($0.kind == .qbittorrent ? "qB" : "TR") \($0.version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: " ").first ?? "")" } ?? ""
            let up = runtime.stats.uploadSpeed > 0 ? " · ↑\(Fmt.speed(runtime.stats.uploadSpeed))" : ""
            // 默认下载目录所在磁盘的剩余空间
            let free = runtime.stats.freeSpace.map { " · " + L("\(Fmt.bytes($0)) free") } ?? ""
            return "\(v) · \(Fmt.endpointKind(ep.kind))\(free)\(up)\(runtime.stats.altSpeedEnabled ? " · " + L("limited") : "")"
        case .connecting: return L("Connecting…")
        case .stopped: return L("Off")
        case .failed: return L("Can’t connect")
        case .needsTrust: return L("Certificate needs review")
        }
    }

    private var help: String {
        switch runtime.status {
        case .online(let v, let ep): "\(v)\n\(ep.baseURL.absoluteString)" + (runtime.stats.freeSpace.map { "\n" + L("Free space in the default download folder: \(Fmt.bytes($0))") } ?? "")
        case .failed(let m): m
        case .needsTrust(let ep, let fp): "\(ep.baseURL.absoluteString)\nSHA256 \(fp)"
        default: ""
        }
    }
}
