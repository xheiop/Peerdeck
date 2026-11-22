import Foundation

public enum EndpointSelector {
    public struct Outcome: Sendable {
        public var selected: Endpoint?
        /// 失败的线路和原因。没轮到或被取消的线路不在里面。
        public var failures: [Endpoint: TransportError]

        /// 失败原因里是否有「证书不受信任」，有的话 UI 应该让用户确认指纹
        public var untrusted: [(Endpoint, String)] {
            failures.compactMap { ep, e in
                if case .untrustedCertificate(let fp) = e { return (ep, fp) }
                return nil
            }
        }
    }

    /// 按优先级（数组顺序）并发探测，返回第一条可用的线路。
    /// 「可用」= 拿到了 5xx 以外的 HTTP 响应（401/403/409 也算，说明下载器在那儿）；
    /// 连不上、证书不信任、被重定向、5xx 都算不可用。
    /// 优先级更高的线路全部失败之后才会选低优先级的，所以内网能通就不会走外网。
    public static func select(_ endpoints: [Endpoint], probePath: String) async -> Outcome {
        guard !endpoints.isEmpty else { return Outcome(selected: nil, failures: [:]) }
        return await withTaskGroup(of: (Int, TransportError?).self) { group in
            for (i, ep) in endpoints.enumerated() {
                group.addTask {
                    let t = HTTPTransport(endpoint: ep)
                    do {
                        let (_, resp) = try await t.send(t.request(probePath))
                        // 502/503/504 多半是中间的代理或反代回的，下载器本身不在
                        if resp.statusCode >= 500 { return (i, .http(status: resp.statusCode, body: "")) }
                        return (i, nil)
                    } catch let e as TransportError {
                        return (i, e)
                    } catch {
                        return (i, .unreachable(String(describing: error)))
                    }
                }
            }
            var results = [TransportError??](repeating: nil, count: endpoints.count)
            var failures: [Endpoint: TransportError] = [:]
            for await (i, failure) in group {
                results[i] = .some(failure)
                if let failure { failures[endpoints[i]] = failure }
                // 找第一个还没结论或成功的位置
                if let first = results.firstIndex(where: { $0 == nil || $0! == nil }), let r = results[first], r == nil {
                    group.cancelAll()
                    return Outcome(selected: endpoints[first], failures: failures)
                }
            }
            return Outcome(selected: nil, failures: failures)
        }
    }
}
