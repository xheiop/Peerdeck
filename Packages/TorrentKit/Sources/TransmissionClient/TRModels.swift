import Foundation
import TorrentKit

struct TREnvelopeHeader: Decodable {
    var result: String
}

struct TREnvelope<T: Decodable>: Decodable {
    var result: String
    var arguments: T
}

struct TRSessionInfo: Decodable {
    var version: String
    var rpcVersion: Int?
    var semver: String?
    var altSpeedEnabled: Bool?
    var downloadDir: String?

    enum CodingKeys: String, CodingKey {
        case version
        case rpcVersion = "rpc-version"
        case semver = "rpc-version-semver"
        case altSpeedEnabled = "alt-speed-enabled"
        case downloadDir = "download-dir"
    }
}

/// 数值单位是 KB/s（app 里统一按 1024 换算，和单种限速一致）
struct TRSpeedSession: Decodable {
    var down: Int64?
    var downEnabled: Bool?
    var up: Int64?
    var upEnabled: Bool?
    var altDown: Int64?
    var altUp: Int64?

    enum CodingKeys: String, CodingKey {
        case down = "speed-limit-down"
        case downEnabled = "speed-limit-down-enabled"
        case up = "speed-limit-up"
        case upEnabled = "speed-limit-up-enabled"
        case altDown = "alt-speed-down"
        case altUp = "alt-speed-up"
    }
}

struct TRFileList: Decodable {
    struct Item: Decodable {
        struct File: Decodable { var name: String; var length: Int64?; var bytesCompleted: Int64? }
        struct Stat: Decodable { var wanted: Bool?; var priority: Int? }
        var files: [File]?
        var fileStats: [Stat]?
    }
    var torrents: [Item]

    func model() -> [ContentFile] {
        guard let t = torrents.first, let files = t.files else { return [] }
        return files.enumerated().map { i, f in
            let st = (t.fileStats ?? []).indices.contains(i) ? t.fileStats![i] : nil
            let p: FilePriority
            if st?.wanted == false { p = .skip }
            else if (st?.priority ?? 0) < 0 { p = .low }
            else if (st?.priority ?? 0) > 0 { p = .high }
            else { p = .normal }
            let size = f.length ?? 0
            return ContentFile(index: i, path: f.name, size: size, progress: size > 0 ? Double(f.bytesCompleted ?? 0) / Double(size) : 1, priority: p)
        }
    }
}

/// free-space 的返回（单位字节）
struct TRFreeSpace: Decodable {
    var sizeBytes: Int64?
    enum CodingKeys: String, CodingKey { case sizeBytes = "size-bytes" }
}

struct TRSessionStats: Decodable {
    struct Cumulative: Decodable {
        var uploadedBytes: Int64?
        var downloadedBytes: Int64?
    }
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var cumulative: Cumulative?
    enum CodingKeys: String, CodingKey { case downloadSpeed, uploadSpeed, cumulative = "cumulative-stats" }
}

struct TRTorrentList: Decodable {
    var torrents: [TRTorrent]
    var removed: [Int]?
}

struct TRTorrent: Decodable {
    struct TrackerEntry: Decodable {
        var announce: String
        var tier: Int?
        var id: Int?
    }

    var id: Int
    var hashString: String?
    var name: String?
    var status: Int?
    var error: Int?
    var errorString: String?
    var isStalled: Bool?
    var percentDone: Double?
    var sizeWhenDone: Int64?
    var downloadedEver: Int64?
    var uploadedEver: Int64?
    var uploadRatio: Double?
    var rateDownload: Int64?
    var rateUpload: Int64?
    var eta: Int64?
    var peersSendingToUs: Int?
    var peersGettingFromUs: Int?
    var addedDate: Int64?
    var doneDate: Int64?
    var secondsSeeding: Int64?
    var downloadDir: String?
    var labels: [String]?
    var isPrivate: Bool?
    var trackers: [TrackerEntry]?
    var uploadLimit: Int64?
    var uploadLimited: Bool?

    func patch() -> TorrentPatch {
        var p = TorrentPatch()
        p.name = name
        p.infoHashV1 = hashString
        let state = TRState.map(status: status ?? -1, error: error ?? 0, stalled: isStalled ?? false)
        p.state = state
        p.rawState = "status=\(status ?? -1) error=\(error ?? 0)"
        p.progress = percentDone
        p.totalSize = sizeWhenDone
        p.downloaded = downloadedEver
        p.uploaded = uploadedEver
        p.ratio = uploadRatio.map { max($0, 0) }
        p.downloadSpeed = rateDownload
        p.uploadSpeed = rateUpload
        p.eta = eta.map { $0 < 0 ? -1 : $0 }
        p.seeds = peersSendingToUs
        p.peers = peersGettingFromUs
        p.addedAt = addedDate
        p.completedAt = doneDate
        p.seedingTime = secondsSeeding
        p.savePath = downloadDir
        p.category = ""
        p.tags = labels
        p.isPrivate = isPrivate
        p.currentTracker = trackers?.first?.announce ?? ""
        p.announceURL = trackers?.first?.announce ?? ""
        p.trackerCount = trackers?.count ?? 0
        p.trackerURLs = trackers.map { $0.sorted { ($0.tier ?? 0) < ($1.tier ?? 0) }.map(\.announce) }
        if let limited = uploadLimited { p.uploadLimit = limited ? (uploadLimit ?? 0) * 1024 : 0 }
        p.errorMessage = errorString ?? ""
        p.trackerHealth = TRState.health(state: state, error: error ?? 0, message: errorString ?? "", trackerCount: trackers?.count ?? 0)
        return p
    }
}

enum TRState {
    static func map(status: Int, error: Int, stalled: Bool) -> TorrentState {
        if error == 3 { return .error } // 本地错误（磁盘、文件丢失）
        return switch status {
        case 0: .stopped
        case 1, 2: .checking
        case 3, 5: .queued
        case 4: stalled ? .stalledDownloading : .downloading
        case 6: stalled ? .stalledSeeding : .seeding
        default: .unknown
        }
    }

    /// error: 0 正常 / 1 tracker warning / 2 tracker error / 3 本地错误
    static func health(state: TorrentState, error: Int, message: String, trackerCount: Int) -> TrackerHealth {
        switch error {
        case 1: return .trackerWarning
        case 2: return isConnectivity(message) ? .unreachable : .trackerError
        default: break
        }
        if trackerCount == 0 { return .unknown }
        switch state {
        case .stopped, .queued, .checking, .metadata, .unknown: return .unknown
        default: return .working // 注意：还没汇报过的活动种子也会落在这里
        }
    }

    /// TR 把连不上 / HTTP 错误也算 error=2，靠消息区分。实测：
    /// "Tracker HTTP response 0 (No Response)"、"Tracker HTTP response 500 (Internal Server Error)"
    static func isConnectivity(_ m: String) -> Bool {
        let s = m.lowercased()
        return s.hasPrefix("tracker http response") || s.contains("could not connect")
            || s.contains("timed out") || s.contains("couldn't resolve")
    }
}

struct TRTrackerStatsList: Decodable {
    struct Item: Decodable { var trackerStats: [TRTrackerStat]? }
    var torrents: [Item]
}

struct TRTrackerStat: Decodable {
    var announce: String
    var tier: Int
    var hasAnnounced: Bool
    var lastAnnounceSucceeded: Bool
    var lastAnnounceResult: String
    var seederCount: Int?
    var leecherCount: Int?

    func model() -> Tracker {
        let status: TrackerStatus
        if !hasAnnounced {
            status = .notContacted
        } else if lastAnnounceSucceeded {
            status = .working
        } else {
            status = TRState.isConnectivity(lastAnnounceResult) ? .unreachable : .trackerError
        }
        let msg = lastAnnounceSucceeded && lastAnnounceResult == "Success" ? "" : lastAnnounceResult
        return Tracker(
            url: announce, tier: tier, status: status, message: msg,
            seeds: seederCount.flatMap { $0 >= 0 ? $0 : nil },
            leeches: leecherCount.flatMap { $0 >= 0 ? $0 : nil }
        )
    }
}
