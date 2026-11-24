import Foundation

public struct Credentials: Sendable, Hashable, Codable {
    public var username: String
    public var password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// 一个下载器实例的遥控接口。实现方是 actor，内部自己维护同步游标（qB 的 rid 等）。
public protocol TorrentClient: Actor {
    nonisolated var serverID: ServerID { get }
    nonisolated var kind: ClientKind { get }

    /// 登录并探测版本。之后的请求会在会话过期时自动重新登录。
    func connect() async throws -> ServerInfo

    /// 拉一次变化。第一次（或 resetSync 之后）返回全量。
    func fetchChanges() async throws -> SyncDelta

    /// 丢掉同步游标，下次 fetchChanges 返回全量。
    func resetSync()

    func perform(_ action: TorrentAction, on ids: [String]) async throws
    func add(_ source: AddSource, options: AddOptions) async throws
    func trackers(of id: String) async throws -> [Tracker]
    /// 种子的文件列表。磁力链接还没拿到元数据时是空的
    func files(of id: String) async throws -> [ContentFile]
    /// 种子当前连着的对端。每次都是全量（qB 也用 rid=0），只在详情打开时轮询
    func peers(of id: String) async throws -> [Peer]
    /// 下载器不支持的档位（qB 的 .low）抛 .unsupported
    func setFilePriority(_ priority: FilePriority, files indices: [Int], of id: String) async throws
    /// 给种子改名。qB 只改显示的名字；TR 同时改磁盘上的顶层文件或目录（currentName 就是它现在的名字）。
    /// 不支持的下载器（Flood）抛 .unsupported；新名字不合法也抛 .unsupported
    func renameTorrent(_ id: String, currentName: String, to newName: String) async throws
    func setAltSpeed(_ enabled: Bool) async throws
    func speedLimits() async throws -> SpeedLimits
    /// TR 的备用限速不能是「不限」（0 在 TR 里是真的 0），传 0 会抛 .unsupported
    func setSpeedLimits(_ limits: SpeedLimits) async throws

    // 批量操作
    /// 只有 qB 有分类，TR 抛 .unsupported
    func setCategory(_ category: String, on ids: [String]) async throws
    func updateTags(_ changes: [TagChange]) async throws
    /// 字节/秒，0 表示不限
    func setUploadLimit(_ bytesPerSecond: Int64, on ids: [String]) async throws
    /// moveFiles=false 只改记录的路径（TR 支持；qB 总会移动，传 false 会抛 .unsupported）
    func setLocation(_ path: String, moveFiles: Bool, on ids: [String]) async throws
    /// 把一个种子的某个 tracker 地址换成新地址
    func replaceTrackerURL(on id: String, from old: String, to new: String) async throws
}

public enum ClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 用户名或密码错误
    case badCredentials
    /// qB 登录被拒（401）。qB 在 Host 头端口和 WebUI 端口不一致时也返回 401，和密码错误分不开
    case loginRejected
    /// qB 连续登录失败后封了 IP。不要自动重试。
    case ipBanned(String)
    /// 服务端返回了意料之外的内容
    case unexpectedResponse(String)
    case notConnected
    /// 这个下载器不支持这个操作
    case unsupported(String)

    public var description: String {
        switch self {
        case .badCredentials: String(localized: "Wrong username or password")
        case .loginRejected: String(localized: "Login rejected (401): wrong username or password; or qB’s Host header validation failed (with a reverse proxy or Docker port mapping, the Host port differs from the WebUI port); or the reverse proxy forwarded its own Authorization header to qB 5.x")
        case .ipBanned(let m): String(localized: "IP banned by the client: \(m)")
        case .unexpectedResponse(let m): String(localized: "Unexpected server response: \(m)")
        case .notConnected: String(localized: "Not connected yet")
        case .unsupported(let m): String(localized: "Not supported: \(m)")
        }
    }
}
