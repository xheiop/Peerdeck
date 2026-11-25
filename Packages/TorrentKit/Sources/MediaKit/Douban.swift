import Foundation

/// 豆瓣条目：用 IMDb 编号查豆瓣的 id 和 app 跳转地址。
///
/// 接口是豆瓣微信小程序用的 frodo `search/weixin`（2026-11-25 实测，不需要特殊请求头）：
/// - 查到：200，`items[].target` 里有 `id`、`uri`（`douban://douban.com/movie/1294584`）、`title`；`target_type` 是 movie / tv
/// - 剧集的 IMDb 编号查到的是第一季的条目（豆瓣按季分条目）
/// - 查不到：200，`items` 为空
/// - key 不对或没给：400，`{"code": 104 / 131, "msg": "invalid_apikey…"}`
public struct DoubanSubject: Codable, Sendable, Equatable {
    public var id: String
    /// app 里的跳转地址，比如 douban://douban.com/movie/1294584
    public var uri: String?
    public var title: String
    /// movie / tv
    public var type: String

    public init(id: String, uri: String?, title: String, type: String) {
        self.id = id
        self.uri = uri
        self.title = title
        self.type = type
    }

    /// 网页地址：电影和剧集都在 movie.douban.com/subject 下
    public var webURL: URL { URL(string: "https://movie.douban.com/subject/\(id)/")! }
    /// 豆瓣 app 的地址（只接受 douban:// 开头的）
    public var appURL: URL? { uri.flatMap { $0.hasPrefix("douban://") ? URL(string: $0) : nil } }
}

public enum DoubanError: Error, Equatable, CustomStringConvertible {
    case http(Int, String)
    case network(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .http(let code, let msg): msg.isEmpty ? "Douban HTTP \(code)" : "Douban HTTP \(code): \(msg)"
        case .network(let msg): msg
        case .decoding(let msg): "Douban: \(msg)"
        }
    }
}

public struct DoubanClient: Sendable {
    /// 豆瓣微信小程序的公开 apikey（网上流传的公共 key）。被封以后查询会失败，app 退回用 IMDb 编号搜索的链接
    static let apiKey = "0fbd2f8cbf69b0fc2f378ea63e3d12f4"
    static let base = URL(string: "https://frodo.douban.com/api/v2/search/weixin")!

    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// 拼请求。单独拿出来方便测试（不发请求）
    static func request(imdbID: String) -> URLRequest {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: imdbID), URLQueryItem(name: "apikey", value: apiKey)]
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// 用 IMDb 编号查豆瓣条目。查不到返回 nil；请求失败、豆瓣报错时抛错（调用方退回搜索链接）
    public func subject(imdbID: String, kind: MediaKind?) async throws -> DoubanSubject? {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.request(imdbID: imdbID))
        } catch {
            throw DoubanError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { let msg: String? }
            throw DoubanError.http(status, (try? JSONDecoder().decode(Failure.self, from: data))?.msg ?? "")
        }
        return try Self.parse(data, kind: kind)
    }

    struct Reply: Decodable {
        struct Item: Decodable {
            struct Target: Decodable {
                let id: String?
                let uri: String?
                let title: String?
            }
            let layout: String?
            let target_type: String?
            let target_id: String?
            let target: Target?
        }
        let items: [Item]?
    }

    /// 只要影视条目（movie / tv）；有多条时优先和 TMDB 类型一致的
    static func parse(_ data: Data, kind: MediaKind?) throws -> DoubanSubject? {
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) } catch { throw DoubanError.decoding("\(error)") }
        let subjects: [DoubanSubject] = (reply.items ?? []).compactMap { item in
            guard let type = item.target_type, type == "movie" || type == "tv",
                  let id = item.target?.id ?? item.target_id, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            return DoubanSubject(id: id, uri: item.target?.uri, title: item.target?.title ?? "", type: type)
        }
        if let kind, let same = subjects.first(where: { $0.type == kind.rawValue }) { return same }
        return subjects.first
    }
}
