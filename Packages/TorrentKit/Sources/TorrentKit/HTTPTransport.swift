import CryptoKit
import Foundation
import os  // OSAllocatedUnfairLock：Synchronization.Mutex 要 iOS 18，最低支持 iOS 17 所以不用它

/// 访问下载器的一条线路。同一台服务器可以配多条（内网 / 组网 / DDNS / 反代）。
public struct Endpoint: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case lan, overlay, ddns, proxy
    }

    /// 基础地址，可以带子路径，例如 https://nas.example.com:8443/qb/
    public var baseURL: URL
    public var kind: Kind
    /// 反代层的 Basic Auth。注意 TR 自己的认证也走 Authorization 头，两者不能同时用。
    public var proxyAuth: Credentials?
    /// 附加请求头，例如 Cloudflare Access 的 CF-Access-Client-Id / CF-Access-Client-Secret
    public var headers: [String: String]
    /// 用户确认过的自签证书叶子证书 SHA256（小写 hex）。系统信任的证书不看这个。
    public var pinnedCertificateSHA256: String?
    public var timeout: TimeInterval
    /// 默认不走系统代理。开着 Clash / Surge 系统代理时，内网和组网地址会被送进代理，
    /// 代理对连不上的地址也会回一个 HTTP 响应，线路探测就会误判成可用（M0 实测）。
    public var useSystemProxy: Bool

    public init(
        baseURL: URL,
        kind: Kind = .lan,
        proxyAuth: Credentials? = nil,
        headers: [String: String] = [:],
        pinnedCertificateSHA256: String? = nil,
        timeout: TimeInterval = 10,
        useSystemProxy: Bool = false
    ) {
        self.baseURL = baseURL
        self.kind = kind
        self.proxyAuth = proxyAuth
        self.headers = headers
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.timeout = timeout
        self.useSystemProxy = useSystemProxy
    }
}


public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 连不上（DNS、拒绝连接、超时、断网）
    case unreachable(String)
    /// 证书不受系统信任，且和已确认的指纹不符。UI 应展示指纹让用户确认。
    case untrustedCertificate(sha256: String)
    /// 被重定向。API 不会重定向，出现这个基本就是反代前面挡了 SSO 登录页。
    case redirected(status: Int, location: String)
    case http(status: Int, body: String)
    /// 反代层要求 Basic Auth（401 + WWW-Authenticate，且不是下载器自己的）
    case proxyAuthRequired(realm: String)

    public var description: String {
        switch self {
        case .unreachable(let m): String(localized: "Can’t connect: \(m)")
        case .untrustedCertificate(let fp): String(localized: "Untrusted certificate, SHA256 fingerprint \(fp)")
        case .redirected(let s, let l): String(localized: "Redirected to \(l) (HTTP \(s)). There may be an SSO login page in front of the proxy, which isn’t supported.")
        case .http(let s, let b): "HTTP \(s): \(b.prefix(200))"
        case .proxyAuthRequired(let r): String(localized: "The reverse proxy requires authentication (realm=\(r)). Check the proxy username and password of the route.")
        }
    }
}

/// 每条线路一个实例：独立的 URLSession，不共享 cookie，不自动跟随重定向。
public final class HTTPTransport: Sendable {
    public struct Stats: Sendable {
        public var requests = 0
        public var bytesReceived = 0
        /// 从发请求到拿到完整响应的累计耗时（秒）
        public var networkSeconds = 0.0
        public init() {}
    }

    public let endpoint: Endpoint
    private let session: URLSession
    private let delegate: TransportDelegate
    private let statsBox = OSAllocatedUnfairLock(initialState: Stats())

    /// 调试和压测用的累计统计
    public var stats: Stats { statsBox.withLock { $0 } }

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        // cookie 自己管：qB 4.x 的 cookie 名固定是 SID，同一主机不同端口的两个实例会互相覆盖
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = endpoint.timeout
        config.waitsForConnectivity = false
        if !endpoint.useSystemProxy { config.connectionProxyDictionary = [:] }
        let delegate = TransportDelegate(pinned: endpoint.pinnedCertificateSHA256)
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// 拼接路径，保留 baseURL 里的子路径。path 不要以 / 开头。
    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var base = endpoint.baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    public func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let auth = endpoint.proxyAuth {
            req.setValue(Self.basicAuth(auth), forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// 从 WWW-Authenticate 里取 realm，没有这个头返回 nil
    public static func authRealm(_ resp: HTTPURLResponse) -> String? {
        guard let h = resp.value(forHTTPHeaderField: "WWW-Authenticate") else { return nil }
        guard let r = h.range(of: "realm=\"") else { return "" }
        return String(h[r.upperBound...].prefix { $0 != "\"" })
    }

    public static func basicAuth(_ c: Credentials) -> String {
        "Basic " + Data("\(c.username):\(c.password)".utf8).base64EncodedString()
    }

    /// 发请求。3xx 抛 .redirected；4xx/5xx 原样返回，由调用方按下载器语义解释。
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        let started = ContinuousClock.now
        do {
            (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - started
            statsBox.withLock {
                $0.requests += 1
                $0.bytesReceived += data.count
                $0.networkSeconds += Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }
        } catch let error as URLError {
            if let fp = delegate.takeRejectedFingerprint() {
                throw TransportError.untrustedCertificate(sha256: fp)
            }
            throw TransportError.unreachable(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.unreachable(String(localized: "Not an HTTP response"))
        }
        if (300..<400).contains(http.statusCode) {
            throw TransportError.redirected(
                status: http.statusCode,
                location: http.value(forHTTPHeaderField: "Location") ?? ""
            )
        }
        return (data, http)
    }

    /// 长连接（Flood 的 SSE）：响应头一到就返回，正文由调用方边收边读。状态码和 send 一样由调用方解释。
    /// 正文可以很久没数据，所以 session 的超时很长；响应头另外限时，否则黑洞地址要等满那个长超时。
    public func stream(_ request: URLRequest, headersWithin limit: TimeInterval) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await withThrowingTaskGroup(of: (URLSession.AsyncBytes, URLResponse).self) { group in
                group.addTask { try await self.session.bytes(for: request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(limit))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        } catch let error as URLError {
            if let fp = delegate.takeRejectedFingerprint() {
                throw TransportError.untrustedCertificate(sha256: fp)
            }
            throw TransportError.unreachable(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.unreachable(String(localized: "Not an HTTP response"))
        }
        if (300..<400).contains(http.statusCode) {
            bytes.task.cancel()
            throw TransportError.redirected(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location") ?? "")
        }
        return (bytes, http)
    }

    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .timedOut: String(localized: "Timed out")
        case .cannotFindHost, .dnsLookupFailed: String(localized: "DNS lookup failed")
        case .cannotConnectToHost: String(localized: "Connection refused")
        case .notConnectedToInternet: String(localized: "No network connection")
        case .networkConnectionLost: String(localized: "Connection lost")
        case .secureConnectionFailed: String(localized: "TLS handshake failed")
        default: e.localizedDescription
        }
    }
}

final class TransportDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let pinned: String?
    private let rejected = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(pinned: String?) {
        self.pinned = pinned?.lowercased()
    }

    func takeRejectedFingerprint() -> String? {
        rejected.withLock { v in
            defer { v = nil }
            return v
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 系统信任的证书（Let's Encrypt、tailscale cert）直接放行，不看指纹，避免续签后失效
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let fp = Self.leafFingerprint(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if fp == pinned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            rejected.withLock { $0 = fp }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // 不跟随重定向，把 3xx 交给调用方
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
