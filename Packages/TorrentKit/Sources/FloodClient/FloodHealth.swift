import Foundation
import TorrentKit

/// Flood 只有一个 message 加几个状态标记，含义按后端不同。
///
/// 实测（Flood 4.16.4，2026-11）：
/// - rTorrent：`Tracker: [Failure reason "Unregistered torrent"]` 是 tracker 拒绝；
///   `Tracker: [Server returned nothing …]`、`Tracker: [Could not parse bencoded data …]` 是连不上 / HTTP 错误；
///   warning message 完全不透传；本地错误没有 `Tracker:` 前缀
/// - Transmission：error=1 变成 warning，error=2（tracker）和 error=3（本地）都变成 error，只能按原话区分
/// - qBittorrent：有报错原文就标 warning，而且原文会被缓存 1 小时
///
/// 分不清时一律不算「被拒绝」：被拒绝 + 命中关键词就会进清理，错了是删种。
enum FloodHealth {
    struct Diagnosis: Equatable {
        var health: TrackerHealth
        var message: String
        var localError = false
    }

    static func diagnose(_ t: FloodTorrent, backend: FloodBackend) -> Diagnosis {
        let message = t.message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch backend {
        case .rTorrent: return rTorrent(t, message)
        case .transmission: return transmission(t, message)
        case .qBittorrent, .neptune:
            let failed = t.status.contains("error")
            return Diagnosis(health: message.isEmpty ? .unknown : .trackerWarning, message: message, localError: failed)
        case .deluge, .unknown:
            let failed = t.status.contains("error")
            // Deluge 正常时 message 是 "OK"
            return Diagnosis(health: .unknown, message: failed ? message : "", localError: failed)
        }
    }

    private static func idle(_ t: FloodTorrent) -> TrackerHealth {
        guard !t.trackerDomains.isEmpty, !t.status.contains("stopped"), !t.status.contains("checking") else { return .unknown }
        return t.status.contains("seeding") || t.status.contains("downloading") ? .working : .unknown
    }

    private static func rTorrent(_ t: FloodTorrent, _ message: String) -> Diagnosis {
        guard !message.isEmpty else { return Diagnosis(health: idle(t), message: "") }
        let prefix = "Tracker: ["
        guard message.hasPrefix(prefix) else {
            if message.hasPrefix("Tried all trackers") { return Diagnosis(health: .unreachable, message: message) }
            return Diagnosis(health: .unknown, message: message, localError: true)
        }
        var inner = String(message.dropFirst(prefix.count))
        if inner.hasSuffix("]") { inner.removeLast() }
        let marker = "Failure reason \""
        guard inner.hasPrefix(marker) else { return Diagnosis(health: .unreachable, message: inner) }
        var reason = String(inner.dropFirst(marker.count))
        if reason.hasSuffix("\"") { reason.removeLast() }
        // d.message 只记最近一次失败。挂了多个站时，别的 tracker 可能是好的：只算警告，不能进清理
        return Diagnosis(health: t.trackerDomains.count > 1 ? .trackerWarning : .trackerError, message: reason)
    }

    private static func transmission(_ t: FloodTorrent, _ message: String) -> Diagnosis {
        if t.status.contains("warning") { return Diagnosis(health: .trackerWarning, message: message) }
        guard t.status.contains("error") else { return Diagnosis(health: idle(t), message: message) }
        if isConnectivity(message) { return Diagnosis(health: .unreachable, message: message) }
        if message.isEmpty || isLocal(message) { return Diagnosis(health: .unknown, message: message, localError: true) }
        return Diagnosis(health: .trackerError, message: message)
    }

    static func isConnectivity(_ m: String) -> Bool {
        let s = m.lowercased()
        return s.hasPrefix("tracker http response") || s.contains("could not connect") || s.contains("did not respond")
            || s.contains("timed out") || s.contains("couldn't resolve") || s.hasPrefix("connection failed")
    }

    /// TR 的本地错误原话
    static func isLocal(_ m: String) -> Bool {
        let s = m.lowercased()
        return ["no data found", "please verify local data", "no space left", "permission denied", "read-only file system",
                "input/output error", "no such file or directory", "unable to save resume file", "couldn't create",
                "couldn't open", "couldn't read", "couldn't write", "couldn't get", "couldn't save"].contains { s.contains($0) }
    }
}
