import Foundation
import os
import TorrentKit

/// 拆 SSE。不用 AsyncBytes.lines：它会吞掉空行，而空行正是事件的分隔。
struct SSEParser {
    struct Event: Equatable {
        var name: String
        var data: Data
    }

    private var line: [UInt8] = []
    private var name = ""
    private var data: [UInt8] = []
    private var hasData = false

    mutating func feed(_ byte: UInt8) -> Event? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.last == 0x0D { line.removeLast() }
        if line.isEmpty {
            defer { name = ""; data = []; hasData = false }
            return hasData ? Event(name: name, data: Data(data)) : nil
        }
        // 冒号开头的是注释（心跳）
        guard let colon = line.firstIndex(of: 0x3A), colon > 0 else { return nil }
        var start = colon + 1
        if start < line.count, line[start] == 0x20 { start += 1 }
        let field = line[..<colon]
        if field.elementsEqual("event".utf8) {
            name = String(decoding: line[start...], as: UTF8.self)
        } else if field.elementsEqual("data".utf8) {
            if hasData { data.append(0x0A) }
            data.append(contentsOf: line[start...])
            hasData = true
        }
        return nil
    }
}

/// 种子列表的原始 JSON 镜像：FULL 整体替换，DIFF 是 fast-json-patch 的 add / remove / replace。
struct FloodListMirror {
    struct PatchError: Error, Equatable {
        var path: String
    }

    private(set) var torrents: [String: [String: Any]] = [:]

    mutating func replaceAll(_ data: Data) throws -> [String: FloodTorrent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PatchError(path: "") }
        var fresh = [String: [String: Any]](minimumCapacity: root.count)
        var out = [String: FloodTorrent](minimumCapacity: root.count)
        for (hash, value) in root {
            guard let t = value as? [String: Any] else { continue }
            fresh[hash] = t
            out[hash] = FloodTorrent(hash: hash, json: t)
        }
        torrents = fresh
        return out
    }

    /// 返回变了的和没了的。补丁对不上就抛错，调用方重连拿全量，不带着错的镜像继续
    mutating func apply(_ data: Data) throws -> (changed: [String: FloodTorrent], removed: Set<String>) {
        guard let ops = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw PatchError(path: "") }
        var touched = Set<String>(), removed = Set<String>()
        for op in ops {
            guard let kind = op["op"] as? String, let path = op["path"] as? String, path.hasPrefix("/") else {
                throw PatchError(path: "")
            }
            let keys = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            guard let hash = keys.first, !hash.isEmpty else { throw PatchError(path: path) }
            if keys.count == 1 {
                switch kind {
                case "remove":
                    torrents[hash] = nil
                    touched.remove(hash)
                    removed.insert(hash)
                case "add", "replace":
                    guard let t = op["value"] as? [String: Any] else { throw PatchError(path: path) }
                    torrents[hash] = t
                    touched.insert(hash)
                    removed.remove(hash)
                default: throw PatchError(path: path)
                }
            } else {
                guard let t = torrents[hash], let new = Self.edit(t, keys.dropFirst(), kind, op["value"]) as? [String: Any] else {
                    throw PatchError(path: path)
                }
                torrents[hash] = new
                touched.insert(hash)
            }
        }
        var changed: [String: FloodTorrent] = [:]
        for hash in touched {
            if let t = torrents[hash] { changed[hash] = FloodTorrent(hash: hash, json: t) }
        }
        return (changed, removed)
    }

    private static func edit(_ node: Any, _ keys: ArraySlice<String>, _ op: String, _ value: Any?) -> Any? {
        guard let key = keys.first, ["add", "remove", "replace"].contains(op) else { return nil }
        let last = keys.count == 1
        if op != "remove", value == nil { return nil }
        if var dict = node as? [String: Any] {
            if last {
                dict[key] = op == "remove" ? nil : value
            } else {
                guard let child = dict[key], let new = edit(child, keys.dropFirst(), op, value) else { return nil }
                dict[key] = new
            }
            return dict
        }
        if var array = node as? [Any] {
            guard let i = key == "-" ? array.count : Int(key), i >= 0 else { return nil }
            if last, op == "add" {
                guard i <= array.count, let value else { return nil }
                array.insert(value, at: i)
                return array
            }
            guard i < array.count else { return nil }
            if last {
                if op == "remove" { array.remove(at: i) } else if let value { array[i] = value }
            } else {
                guard let new = edit(array[i], keys.dropFirst(), op, value) else { return nil }
                array[i] = new
            }
            return array
        }
        return nil
    }
}

/// 一条 /api/activity-stream 连接。后台任务只写快照，FloodClient.fetchChanges 来取走累计的变化。
/// 释放时自动断开：任务不持有这个对象。
final class FloodEventStream: Sendable {
    struct Snapshot: Sendable {
        var hasList = false
        var needsFull = true
        var torrents: [String: FloodTorrent] = [:]
        var changed = Set<String>()
        var removed = Set<String>()
        var summary: FloodSummary?
        var disks: [FloodDisk] = []
        var disconnectedSince: ContinuousClock.Instant?
        var lastEvent = ContinuousClock.now
        var ended = false
        var failure: String?
    }

    struct Changes: Sendable {
        var full: Bool
        var upserts: [String: FloodTorrent]
        var removed: Set<String>
        var summary: FloodSummary?
        var disks: [FloodDisk]
    }

    private let box: OSAllocatedUnfairLock<Snapshot>
    private let task: Task<Void, Never>

    init(bytes: URLSession.AsyncBytes) {
        let box = OSAllocatedUnfairLock(initialState: Snapshot())
        self.box = box
        task = Task.detached(priority: .utility) { await Self.consume(bytes, into: box) }
    }

    deinit { task.cancel() }

    var status: (hasList: Bool, ended: Bool, failure: String?, disconnectedSince: ContinuousClock.Instant?, lastEvent: ContinuousClock.Instant) {
        box.withLock { ($0.hasList, $0.ended, $0.failure, $0.disconnectedSince, $0.lastEvent) }
    }

    func torrent(_ hash: String) -> FloodTorrent? { box.withLock { $0.torrents[hash] } }

    func markFull() { box.withLock { $0.needsFull = true } }

    func take() -> Changes {
        box.withLock { s in
            let full = s.needsFull
            var upserts: [String: FloodTorrent] = [:]
            if full {
                upserts = s.torrents
            } else {
                for hash in s.changed { if let t = s.torrents[hash] { upserts[hash] = t } }
            }
            let out = Changes(full: full, upserts: upserts, removed: full ? [] : s.removed, summary: s.summary, disks: s.disks)
            s.needsFull = false
            s.changed.removeAll(keepingCapacity: true)
            s.removed.removeAll(keepingCapacity: true)
            return out
        }
    }

    private static func consume(_ bytes: URLSession.AsyncBytes, into box: OSAllocatedUnfairLock<Snapshot>) async {
        var parser = SSEParser()
        var mirror = FloodListMirror()
        do {
            for try await byte in bytes {
                if let event = parser.feed(byte) { try handle(event, mirror: &mirror, box: box) }
            }
            box.withLock { $0.ended = true }
        } catch {
            let reason = error is URLError ? error.localizedDescription : "\(error)"
            box.withLock { $0.ended = true; $0.failure = reason }
        }
    }

    static func handle(_ event: SSEParser.Event, mirror: inout FloodListMirror, box: OSAllocatedUnfairLock<Snapshot>) throws {
        let now = ContinuousClock.now
        box.withLock { $0.lastEvent = now }
        switch event.name {
        case "TORRENT_LIST_FULL_UPDATE":
            let all = try mirror.replaceAll(event.data)
            box.withLock { s in
                s.torrents = all
                s.hasList = true
                s.needsFull = true
                s.changed.removeAll()
                s.removed.removeAll()
            }
        case "TORRENT_LIST_DIFF_CHANGE":
            let (changed, removed) = try mirror.apply(event.data)
            box.withLock { s in
                for (hash, t) in changed {
                    s.torrents[hash] = t
                    s.changed.insert(hash)
                    s.removed.remove(hash)
                }
                for hash in removed {
                    s.torrents[hash] = nil
                    s.changed.remove(hash)
                    s.removed.insert(hash)
                }
            }
        case "TRANSFER_SUMMARY_FULL_UPDATE":
            if let v = try? JSONDecoder().decode(FloodSummary.self, from: event.data) { box.withLock { $0.summary = v } }
        case "DISK_USAGE_CHANGE":
            if let v = try? JSONDecoder().decode([FloodDisk].self, from: event.data) { box.withLock { $0.disks = v } }
        case "CLIENT_CONNECTIVITY_STATUS_CHANGE":
            guard let v = try? JSONDecoder().decode(FloodConnectivity.self, from: event.data) else { return }
            box.withLock { $0.disconnectedSince = v.isConnected ? nil : ($0.disconnectedSince ?? now) }
        default:
            break // 速度历史、分类统计、通知数：用不上
        }
    }
}
