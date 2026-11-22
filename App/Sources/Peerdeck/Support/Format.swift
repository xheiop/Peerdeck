import Foundation
import TorrentKit

// mac 和 iOS 共用：日志、格式化、本地化入口。不要在这里引入 AppKit / UIKit。

/// 文案都从 app 主 bundle 的 Localizable 里查（两个平台的 app 各自带一份同样的 catalog）
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

enum Log {
    static let enabled = ProcessInfo.processInfo.environment["TC_LOG"] == "1"

    static func info(_ s: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Peerdeck] \(s())")
        fflush(stdout)
    }
}

enum Fmt {
    static func bytes(_ v: Int64) -> String {
        v == 0 ? "0" : ByteCountFormatter.string(fromByteCount: v, countStyle: .binary)
    }

    static func speed(_ v: Int64) -> String { bytes(v) + "/s" }

    /// 大数字和单位分开排版时用：("186.4", "TB")。换算同 bytes；0 时单位为空
    static func bytesParts(_ v: Int64) -> (value: String, unit: String) {
        guard v != 0 else { return ("0", "") }
        let num = ByteCountFormatter(), unit = ByteCountFormatter()
        num.countStyle = .binary; unit.countStyle = .binary
        num.includesUnit = false
        unit.includesCount = false
        return (num.string(fromByteCount: v), unit.string(fromByteCount: v))
    }

    /// 窄地方用的速度：12.4M、850K、0（每秒，十进制单位，和 bytes 一致）
    static func compactSpeed(_ v: Int64) -> String {
        if v < 1000 { return v == 0 ? "0" : "\(v)B" }
        var x = Double(v) / 1000
        for unit in ["K", "M", "G"] {
            if x < 1000 || unit == "G" {
                return (x < 100 ? x.formatted(.number.precision(.fractionLength(1))) : x.formatted(.number.precision(.fractionLength(0)))) + unit
            }
            x /= 1000
        }
        return ""
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    static func ratio(_ v: Double) -> String { String(format: "%.2f", v) }

    /// 「名字：内容」，中文用全角冒号，英文用半角
    static func labeled(_ name: String, _ value: String) -> String { L("\(name): \(value)") }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

    /// 「N 个种子」。英文要分单复数，数字又要带千分位，所以单独处理 1 的情况
    static func torrents(_ n: Int) -> String { n == 1 ? L("1 torrent") : L("\(count(n)) torrents") }

    static func date(_ unix: Int64) -> String {
        guard unix > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .numeric, time: .shortened)
    }

    /// 某个时间点距今：「刚刚」「3 小时前」
    static func ago(_ timestamp: Int64) -> String {
        let s = Int64(Date().timeIntervalSince1970) - timestamp
        return s < 60 ? L("just now") : L("\(duration(s)) ago")
    }

    /// 「qB 5.3：800 · TR 4.1：431」。名字里常带版本号，用冒号隔开数字
    static func breakdown(_ pairs: [(String, Int)]) -> String {
        pairs.sorted { $0.1 > $1.1 }.map { labeled($0.0, count($0.1)) }.joined(separator: " · ")
    }

    static func duration(_ seconds: Int64) -> String {
        guard seconds >= 60 else { return seconds > 0 ? L("just now") : "—" }
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d >= 30 { return L("\(d / 30) mo") }
        if d > 0 { return d < 7 && h > 0 ? L("\(d) d \(h) h") : L("\(d) d") }
        if h > 0 { return L("\(h) h") }
        return L("\(m) min")
    }

    static func state(_ s: TorrentState) -> String {
        switch s {
        case .downloading: L("Downloading")
        case .seeding: L("Seeding")
        case .stalledDownloading: L("Stalled")
        case .stalledSeeding: L("Seeding")
        case .stopped: L("Stopped")
        case .queued: L("Queued")
        case .checking: L("Checking")
        case .metadata: L("Fetching metadata")
        case .moving: L("Moving")
        case .error: L("Error")
        case .unknown: L("Unknown")
        }
    }

    static func endpointKind(_ k: Endpoint.Kind) -> String {
        switch k {
        case .lan: L("LAN")
        case .overlay: L("Overlay")
        case .ddns: "DDNS"
        case .proxy: L("Proxy")
        }
    }

    static func trackerStatus(_ s: TrackerStatus) -> String {
        switch s {
        case .working: L("Working")
        case .notContacted: L("Not contacted")
        case .updating: L("Updating")
        case .notWorking: L("Not working")
        case .trackerError: L("Rejected")
        case .unreachable: L("Unreachable")
        case .disabled: L("Disabled")
        case .unknown: L("Unknown")
        }
    }
}
