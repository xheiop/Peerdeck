import Foundation
import Observation
import QBittorrentClient
import SyncEngine
import TorrentKit
import TransmissionClient

/// 一台服务器的运行时：选线路、连接、轮询、把变化交给 TorrentStore。
@MainActor @Observable
final class ServerRuntime: Identifiable {
    enum Status: Equatable {
        case stopped
        case connecting
        case online(version: String, endpoint: Endpoint)
        case failed(String)
        /// 所有线路里有自签证书没确认，等用户点信任
        case needsTrust(endpoint: Endpoint, fingerprint: String)

        var isOnline: Bool { if case .online = self { true } else { false } }
    }

    nonisolated let id: String
    private(set) var config: ServerConfig
    /// 初始是「连接中」：加载完配置、还没开始连接的那一瞬间，不要显示成「已停用」（停用的服务器在 start() 里会被设成 .stopped）
    private(set) var status: Status = .connecting { didSet { if status != oldValue { onStatusChange?() } } }
    /// 第一次全量同步完成之前为 false（横幅显示「正在载入」）
    private(set) var loaded = false
    private(set) var stats = ServerStats()
    private(set) var info: ServerInfo?

    @ObservationIgnored private(set) var client: (any TorrentClient)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private weak var store: TorrentStore?
    @ObservationIgnored private let interval: @MainActor () -> Duration
    @ObservationIgnored private var wakeToken = 0
    @ObservationIgnored var onStatusChange: (() -> Void)?

    init(config: ServerConfig, store: TorrentStore?, interval: @escaping @MainActor () -> Duration) {
        self.id = config.id
        self.config = config
        self.store = store
        self.interval = interval
    }

    var serverID: ServerID { config.serverID }

    /// false 时连上就停（Share Extension 用）
    var syncTorrents = true

    func start() {
        stop()
        guard config.enabled else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        client = nil
        loaded = false
        status = .stopped
    }

    func update(_ newConfig: ServerConfig) {
        config = newConfig
        store?.removeServer(serverID)
        start()
    }

    /// 操作完马上刷新一次，不用等下一个周期
    func refreshNow() { wakeToken += 1 }

    /// 可以被 refreshNow 提前唤醒的 sleep（100ms 粒度，够用）
    private func sleep(_ d: Duration) async {
        let deadline = ContinuousClock.now + d
        let token = wakeToken
        while ContinuousClock.now < deadline, wakeToken == token, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func makeClient(_ ep: Endpoint) -> any TorrentClient {
        switch config.kind {
        case .qbittorrent:
            QBittorrentClient(serverID: serverID, endpoint: ep, credentials: config.credentials,
                              apiKey: config.apiKey.isEmpty ? nil : config.apiKey)
        case .transmission:
            TransmissionClient(serverID: serverID, endpoint: ep, credentials: config.credentials)
        }
    }

    private func run() async {
        while !Task.isCancelled {
            status = .connecting
            let outcome = await EndpointSelector.select(config.endpoints, probePath: config.probePath)
            if Task.isCancelled { return }
            guard let ep = outcome.selected else {
                if let (ep, fp) = outcome.untrusted.first {
                    status = .needsTrust(endpoint: ep, fingerprint: fp)
                    return // 等用户确认，确认后会重新 start
                }
                status = .failed(Self.describe(outcome.failures))
                await sleep(.seconds(15))
                continue
            }

            let client = makeClient(ep)
            self.client = client
            let sync = ServerSync(client: client)
            do {
                let info = try await client.connect()
                self.info = info
                status = .online(version: info.version, endpoint: ep)
                Log.info("\(config.name) 在线：\(info.version) via \(ep.kind.rawValue) \(ep.baseURL.absoluteString)")
                // Share Extension：只要能添加种子，不拉种子列表（扩展有内存上限）
                if !syncTorrents {
                    while !Task.isCancelled { await sleep(.seconds(3600)) }
                    return
                }
                while !Task.isCancelled {
                    let t0 = ContinuousClock.now
                    let cs = try await sync.refresh()
                    let changed = await sync.torrents(cs.changed.map(\.id))
                    if Task.isCancelled { return }
                    stats = await sync.stats
                    store?.apply(server: serverID, changeSet: cs, changed: changed)
                    if !loaded { loaded = true }
                    if cs.isFull {
                        Log.info("\(config.name) 全量 \(changed.count) 个种子，\(ContinuousClock.now - t0)")
                    }
                    await sleep(interval())
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.client = nil
                status = .failed(String(describing: error))
                Log.info("\(config.name) 出错：\(error)")
                // 认证类错误不自动重试：qB 连续失败会封 IP
                if let ce = error as? ClientError {
                    switch ce {
                    case .badCredentials, .loginRejected, .ipBanned: return
                    default: break
                    }
                }
                if case TransportError.proxyAuthRequired = error { return }
                await sleep(.seconds(5))
            }
        }
    }

    static func describe(_ failures: [Endpoint: TransportError]) -> String {
        if failures.isEmpty { return L("No routes configured") }
        return failures
            .sorted { $0.key.baseURL.absoluteString < $1.key.baseURL.absoluteString }
            .map { Fmt.labeled($0.key.baseURL.host() ?? $0.key.baseURL.absoluteString, "\($0.value)") }
            .joined(separator: "\n")
    }
}
