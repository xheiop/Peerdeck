import SwiftUI
import TorrentKit

/// 列表里的一行（v3）：墨字，数字等宽；颜色只出现在健康度小形状上（菱形 / 三角 / 空心圆）
struct TorrentRow: View {
    let model: AppModel
    let torrent: Torrent
    let problemLayout: Bool

    private var store: TorrentStore { model.store }

    var body: some View {
        let t = torrent
        VStack(alignment: .leading, spacing: 4) {
            Text(t.name).lineLimit(2).truncationMode(.middle)
            if problemLayout { problemLine(t) } else { statusLine(t) }
            if StateGroup.of(t.state) == .downloading || t.state == .checking {
                ProgressBar(value: t.progress, dim: t.state == .checking || t.downloadSpeed == 0)
            }
            Text(meta(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func statusLine(_ t: Torrent) -> some View {
        HStack(spacing: 5) {
            switch StateGroup.of(t.state) {
            case .seeding:
                Text(t.uploadSpeed > 0 ? "↑ " + Fmt.speed(t.uploadSpeed) : L("Seeding")).foregroundStyle(t.uploadSpeed > 0 ? .primary : .secondary)
            case .downloading:
                Text(downloadText(t))
            case .stopped:
                Text(t.progress < 1 ? L("Stopped · \(Fmt.percent(t.progress))") : L("Stopped")).foregroundStyle(.secondary)
            case .waiting:
                Text(t.state == .checking ? L("Checking \(Fmt.percent(t.progress))") : Fmt.state(t.state)).foregroundStyle(.secondary)
            case .error:
                // 下载器本地出错时这里是报错原文（TR 的 "No data found!…"），前面加红色标记
                LocalErrorMark.view
                Text(t.errorMessage.isEmpty ? L("Error") : t.errorMessage).lineLimit(1)
            case nil:
                Text(Fmt.state(t.state)).foregroundStyle(.secondary)
            }
            if let mark = healthMark(t) {
                mark.view.accessibilityLabel(Text(mark == .timeout ? "Unreachable for Long" : "Rejected by Tracker"))
            }
            Spacer(minLength: 6)
            Text(Fmt.bytes(t.totalSize)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    private func healthMark(_ t: Torrent) -> HealthMark? {
        let rules = store.rules
        if rules.isUnregistered(t) { return .unregistered }
        if rules.isRejected(t) { return .rejected }
        if rules.isLongUnreachable(t, firstSeen: store.firstSeen(t.ref)) { return .timeout }
        return nil
    }

    private func downloadText(_ t: Torrent) -> String {
        var parts = [Fmt.percent(t.progress)]
        if t.downloadSpeed > 0 { parts.append("↓ " + Fmt.speed(t.downloadSpeed)) }
        if t.eta > 0, t.progress < 1 { parts.append(L("\(Fmt.duration(t.eta)) left")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func problemLine(_ t: Torrent) -> some View {
        let rules = store.rules
        let since = store.firstSeen(t.ref).map { " · " + Fmt.ago($0) } ?? ""
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if rules.isRejected(t) {
                    (rules.isUnregistered(t) ? HealthMark.unregistered : .rejected).view
                    Text((rules.isUnregistered(t) ? L("Unregistered") : t.trackerHealth == .notWorking ? L("Not working (?)") : L("Rejected")) + since)
                } else if t.trackerHealth == .unreachable {
                    HealthMark.timeout.view
                    Text(L("Unreachable") + since).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.state(t.state)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let n = store.cross[t.ref] { Text(L("Cross-seeded ×\(n)")).foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            if !t.errorMessage.isEmpty {
                Text(t.errorMessage).font(.quote).lineLimit(2)
            }
        }
    }

    private func meta(_ t: Torrent) -> String {
        var parts = [model.siteName(store.siteID(of: t))]
        if model.servers.count > 1, case .server = store.sidebar {} else if model.servers.count > 1 {
            parts.append(model.server(t.ref.server.rawValue)?.config.name ?? t.ref.server.rawValue)
        }
        if t.uploaded > 0 { parts.append("↑ " + Fmt.bytes(t.uploaded)) }
        parts.append(L("Ratio \(Fmt.ratio(t.ratio))"))
        if t.seedingTime > 0 { parts.append(Fmt.duration(t.seedingTime)) }
        return parts.joined(separator: " · ")
    }
}

/// 细进度条：墨色，没在下载（排队、校验、0 速度）时变淡
struct ProgressBar: View {
    let value: Double
    var dim = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.ink.opacity(dim ? 0.35 : 1)).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue(Text(Fmt.percent(value)))
    }
}
