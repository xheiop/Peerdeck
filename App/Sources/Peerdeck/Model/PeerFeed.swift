import Foundation
import TorrentKit

/// 详情里的 Peers：只在展开（mac）或打开（iOS）时轮询，间隔和列表一样（AppModel.pollInterval），每次全量
@MainActor @Observable
final class PeerFeed {
    let ref: TorrentRef
    private(set) var peers: [Peer]?
    /// 还没拿到过列表时的错误；拿到过以后偶尔失败就继续显示上一次的
    private(set) var error: String?

    init(ref: TorrentRef) { self.ref = ref }

    /// 合计速度（我们从这些 peer 下载 / 上传给它们）
    var totals: (down: Int64, up: Int64) {
        (peers ?? []).reduce((0, 0)) { ($0.0 + $1.downloadRate, $0.1 + $1.uploadRate) }
    }

    /// 在 .task 里调用，视图消失时随任务取消
    func run(_ model: AppModel) async {
        while !Task.isCancelled {
            await refresh(model)
            try? await Task.sleep(for: max(.seconds(1), model.pollInterval))
        }
    }

    func refresh(_ model: AppModel) async {
        do {
            peers = try await model.peers(for: ref)
            error = nil
        } catch is CancellationError {
        } catch {
            if peers == nil { self.error = "\(error)" }
        }
    }
}

extension Peer {
    /// 客户端名；有的 peer 还没握手完，下载器给空字符串
    var clientLabel: String { client.isEmpty ? L("Unknown client") : client }

    /// 第二行：完成度和速度（为 0 的速度不显示）
    var statusLine: String {
        var parts = [Fmt.percent(progress)]
        if downloadRate > 0 { parts.append("↓ " + Fmt.speed(downloadRate)) }
        if uploadRate > 0 { parts.append("↑ " + Fmt.speed(uploadRate)) }
        return parts.joined(separator: " · ")
    }
}
