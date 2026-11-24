import Foundation
import TorrentKit

// 字段名和 qB 返回的 JSON 保持一致（snake_case），只解需要的字段。

struct QBMainData: Decodable {
    var rid: Int
    var full_update: Bool?
    var torrents: [String: QBTorrent]?
    var torrents_removed: [String]?
    var server_state: QBServerState?
    /// tracker URL -> 用这个 tracker 的种子 hash 列表（4.6.7 / 5.3.0 都有）。增量时只下发变化的 URL，值是完整列表。
    var trackers: [String: [String]]?
    var trackers_removed: [String]?
}

struct QBTorrent: Decodable {
    var name: String?
    var infohash_v1: String?
    var infohash_v2: String?
    var state: String?
    var progress: Double?
    var size: Int64?
    var downloaded: Int64?
    var uploaded: Int64?
    var ratio: Double?
    var dlspeed: Int64?
    var upspeed: Int64?
    var eta: Int64?
    var num_seeds: Int?
    var num_leechs: Int?
    var added_on: Int64?
    var completion_on: Int64?
    var seeding_time: Int64?
    var save_path: String?
    var category: String?
    var tags: String?
    var isPrivate: Bool?
    var tracker: String?
    var trackers_count: Int?
    var up_limit: Int64?
    var has_tracker_error: Bool?
    var has_tracker_warning: Bool?
    var has_other_announce_error: Bool?

    enum CodingKeys: String, CodingKey {
        case name, infohash_v1, infohash_v2, state, progress, size, downloaded, uploaded, ratio
        case dlspeed, upspeed, eta, num_seeds, num_leechs, added_on, completion_on, seeding_time
        case save_path, category, tags, tracker, trackers_count, up_limit
        case has_tracker_error, has_tracker_warning, has_other_announce_error
        case isPrivate = "private"
    }

    /// qB 用 8640000（100 天）表示 ETA 无穷
    static let infiniteETA: Int64 = 8_640_000

    func patch() -> TorrentPatch {
        var p = TorrentPatch()
        p.name = name
        p.infoHashV1 = infohash_v1
        p.infoHashV2 = infohash_v2
        if let s = state {
            p.state = QBState.map(s)
            p.rawState = s
        }
        p.progress = progress
        p.totalSize = size
        p.downloaded = downloaded
        p.uploaded = uploaded
        p.ratio = ratio
        p.downloadSpeed = dlspeed
        p.uploadSpeed = upspeed
        p.eta = eta.map { $0 >= Self.infiniteETA ? -1 : $0 }
        p.seeds = num_seeds
        p.peers = num_leechs
        p.addedAt = added_on
        p.completedAt = completion_on.map { max($0, 0) }
        p.seedingTime = seeding_time
        p.savePath = save_path
        p.category = category
        p.tags = tags.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        p.isPrivate = isPrivate
        p.currentTracker = tracker
        p.trackerCount = trackers_count
        p.uploadLimit = up_limit.map { max(0, $0) }
        return p
    }
}

struct QBServerState: Decodable {
    var dl_info_speed: Int64?
    var up_info_speed: Int64?
    var free_space_on_disk: Int64?
    var use_alt_speed_limits: Bool?
    var alltime_ul: Int64?
    var alltime_dl: Int64?

    func patch() -> ServerStatsPatch {
        var p = ServerStatsPatch()
        p.downloadSpeed = dl_info_speed
        p.uploadSpeed = up_info_speed
        p.freeSpace = free_space_on_disk
        p.altSpeedEnabled = use_alt_speed_limits
        p.allTimeUploaded = alltime_ul
        p.allTimeDownloaded = alltime_dl
        return p
    }
}

struct QBTracker: Decodable {
    var url: String
    var tier: Int?
    var status: Int
    var msg: String?
    var num_seeds: Int?
    var num_leeches: Int?

    func model() -> Tracker {
        // 5.3.0 实测：failure reason（Unregistered torrent）= 5，HTTP 500 / 连不上 = 4
        let s: TrackerStatus = switch status {
        case 0: .disabled
        case 1: .notContacted
        case 2: .working
        case 3: .updating
        case 4: .notWorking
        case 5: .trackerError
        case 6: .unreachable
        default: .unknown
        }
        return Tracker(
            url: url, tier: tier ?? 0, status: s, message: msg ?? "",
            seeds: num_seeds.flatMap { $0 >= 0 ? $0 : nil },
            leeches: num_leeches.flatMap { $0 >= 0 ? $0 : nil }
        )
    }
}

/// torrents/files 的一项。index 字段 webapi 2.8.2 起才有，没有时按数组下标
struct QBFile: Decodable {
    var index: Int?
    var name: String
    var size: Int64?
    var progress: Double?
    var priority: Int?

    func model(at i: Int) -> ContentFile {
        let p: FilePriority = switch priority ?? 1 {
        case 0: .skip
        case 6, 7: .high
        default: .normal
        }
        return ContentFile(index: index ?? i, path: name, size: size ?? 0, progress: progress ?? 0, priority: p)
    }
}

/// sync/torrentPeers 的返回（rid=0，全量）。字典的键是「ip:port」
struct QBPeerList: Decodable {
    struct Item: Decodable {
        var ip: String?
        var port: Int?
        var client: String?
        var progress: Double?
        var dl_speed: Int64?
        var up_speed: Int64?
        var downloaded: Int64?
        var uploaded: Int64?
        var flags: String?
        var flags_desc: String?
        var connection: String?
        var country_code: String?
    }
    var peers: [String: Item]?

    func model() -> [Peer] {
        (peers ?? [:]).compactMap { key, p in
            // 老版本可能没有 ip / port 字段，从键里拆
            let split = key.lastIndex(of: ":").map { (String(key[..<$0]), Int(key[key.index(after: $0)...])) }
            guard let address = p.ip ?? split?.0 else { return nil }
            let flags = p.flags ?? ""
            return Peer(address: address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: p.port ?? split?.1 ?? 0,
                        client: p.client ?? "", progress: min(1, max(0, p.progress ?? 0)),
                        downloadRate: p.dl_speed ?? 0, uploadRate: p.up_speed ?? 0,
                        downloaded: p.downloaded, uploaded: p.uploaded,
                        flags: flags, flagsHelp: p.flags_desc.flatMap { $0.isEmpty ? nil : $0 },
                        connection: p.connection.flatMap { $0.isEmpty ? nil : $0 },
                        encrypted: flags.split(separator: " ").contains("E"),
                        incoming: flags.split(separator: " ").contains("I"),
                        countryCode: p.country_code.flatMap { $0.isEmpty ? nil : $0.uppercased() })
        }
    }
}

struct QBAddResult: Decodable {
    var success_count: Int?
    var failure_count: Int?
}

struct QBSpeedPrefs: Decodable {
    var dl_limit: Int64?
    var up_limit: Int64?
    var alt_dl_limit: Int64?
    var alt_up_limit: Int64?
}
