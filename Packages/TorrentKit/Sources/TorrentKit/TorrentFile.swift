import CryptoKit
import Foundation

/// .torrent 文件的本地解析结果（只读需要的字段）。
public struct TorrentFile: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var size: Int64
    }

    public var name: String
    public var totalSize: Int64
    public var files: [Entry]
    /// announce 加 announce-list，去重后按出现顺序
    public var trackers: [String]
    public var isPrivate: Bool
    /// v1 infohash（info 字典原始字节的 SHA1，小写 hex）
    public var infoHashV1: String

    public enum ParseError: Error, Equatable { case invalid(String) }

    public static func parse(_ data: Data) throws -> TorrentFile {
        var p = Parser(bytes: [UInt8](data))
        guard case .dict(let top) = try p.value() else { throw ParseError.invalid(String(localized: "Top level isn’t a dictionary")) }
        guard case .dict(let info)? = top["info"], let range = p.infoRange else { throw ParseError.invalid(String(localized: "Missing info dictionary")) }
        let hash = Insecure.SHA1.hash(data: Data(p.bytes[range])).map { String(format: "%02x", $0) }.joined()
        let name = info["name.utf-8"]?.string ?? info["name"]?.string ?? ""
        var files: [Entry] = []
        if case .list(let list)? = info["files"] {
            for f in list {
                guard case .dict(let fd) = f else { continue }
                let parts = (fd["path.utf-8"] ?? fd["path"])?.list?.compactMap(\.string) ?? []
                files.append(Entry(path: parts.joined(separator: "/"), size: fd["length"]?.int ?? 0))
            }
        } else {
            files.append(Entry(path: name, size: info["length"]?.int ?? 0))
        }
        var trackers: [String] = []
        if let a = top["announce"]?.string { trackers.append(a) }
        for tier in top["announce-list"]?.list ?? [] {
            for u in tier.list ?? [] { if let s = u.string, !trackers.contains(s) { trackers.append(s) } }
        }
        return TorrentFile(
            name: name, totalSize: files.reduce(0) { $0 + $1.size }, files: files,
            trackers: trackers, isPrivate: info["private"]?.int == 1, infoHashV1: hash
        )
    }

    indirect enum Value {
        case int(Int64), bytes([UInt8]), list([Value]), dict([String: Value])
        var string: String? { if case .bytes(let b) = self { String(bytes: b, encoding: .utf8) } else { nil } }
        var int: Int64? { if case .int(let i) = self { i } else { nil } }
        var list: [Value]? { if case .list(let l) = self { l } else { nil } }
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var depth = 0
        var infoRange: Range<Int>?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func value() throws -> Value {
            guard i < bytes.count else { throw ParseError.invalid(String(localized: "Incomplete data")) }
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw ParseError.invalid(String(localized: "Nested too deeply")) }
            switch bytes[i] {
            case UInt8(ascii: "i"):
                i += 1
                let n = try number(until: UInt8(ascii: "e"))
                return .int(n)
            case UInt8(ascii: "l"):
                i += 1
                var out: [Value] = []
                while i < bytes.count, bytes[i] != UInt8(ascii: "e") { out.append(try value()) }
                i += 1
                return .list(out)
            case UInt8(ascii: "d"):
                i += 1
                var out: [String: Value] = [:]
                while i < bytes.count, bytes[i] != UInt8(ascii: "e") {
                    guard case .bytes(let kb) = try value() else { throw ParseError.invalid(String(localized: "Dictionary key isn’t a string")) }
                    let key = String(decoding: kb, as: UTF8.self)
                    let start = i
                    let v = try value()
                    if key == "info", depth == 1 { infoRange = start..<i }
                    out[key] = v
                }
                i += 1
                return .dict(out)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let len = Int(try number(until: UInt8(ascii: ":")))
                guard len >= 0, i + len <= bytes.count else { throw ParseError.invalid(String(localized: "String length out of range")) }
                defer { i += len }
                return .bytes(Array(bytes[i..<(i + len)]))
            default:
                throw ParseError.invalid(String(localized: "Unrecognized byte \(bytes[i])"))
            }
        }

        mutating func number(until end: UInt8) throws -> Int64 {
            let start = i
            while i < bytes.count, bytes[i] != end { i += 1 }
            guard i < bytes.count, let n = Int64(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw ParseError.invalid(String(localized: "Malformed number")) }
            i += 1
            return n
        }
    }
}
