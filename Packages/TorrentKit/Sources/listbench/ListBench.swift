#if os(macOS)
import AppKit
import SwiftUI
import SyncEngine
import TorrentKit

// SwiftUI 列表压测：N 行，每秒 5% 的行变化，同时程序化「滚动」（每 100ms 跳到随机行）。
// 主线程上挂一个 4ms 的计时器，量两次触发之间的最大间隔，间隔大就是卡顿。
//
//   swift run -c release listbench table 20000
//   swift run -c release listbench list 20000
//   swift run -c release listbench table-resort 20000   每秒按上传速度重排（最坏情况）
//
// 会弹出一个窗口，跑完约 20 秒自动退出，结果打到 stdout。

enum Mode: String {
    case table, list, tableResort = "table-resort"
}

let cliArgs = CommandLine.arguments
let mode = Mode(rawValue: cliArgs.count > 1 ? cliArgs[1] : "table") ?? .table
let rowCount = cliArgs.count > 2 ? Int(cliArgs[2]) ?? 20_000 : 20_000

@MainActor @Observable
final class BenchModel {
    var rows: [Torrent] = []
    var scrollTarget: TorrentRef?

    @ObservationIgnored private var tickTimes: [Double] = []
    @ObservationIgnored private var gaps: [Double] = []
    @ObservationIgnored private var lastBeat = CACurrentMediaTime()
    @ObservationIgnored private var measuring = false

    init() {
        let server = ServerID("bench")
        let hosts = ["pt-a.test", "pt-b.test", "pt-c.test", "pt-d.test"]
        var all: [Torrent] = []
        all.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            var t = Torrent(ref: TorrentRef(server: server, id: String(format: "%040x", i)))
            t.name = "Some.Show.S01E\(i % 100).2160p.WEB-DL.\(i).mkv"
            t.state = i % 3 == 0 ? .seeding : .stalledSeeding
            t.totalSize = Int64(i) * 1_048_576
            t.uploadSpeed = Int64(i % 37) * 1024
            t.ratio = Double(i % 300) / 100
            t.announceURL = "https://\(hosts[i % hosts.count])/announce"
            t.trackerHealth = i % 25 == 0 ? .trackerError : .working
            all.append(t)
        }
        let order = TorrentQuery.run(all, filter: TorrentFilter(), sort: .name)
        let byRef = Dictionary(uniqueKeysWithValues: all.map { ($0.ref, $0) })
        rows = order.map { byRef[$0]! }
    }

    func start() {
        // 心跳：量主线程最大间隔
        let beat = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if self.measuring { self.gaps.append(now - self.lastBeat) }
                self.lastBeat = now
            }
        }
        RunLoop.main.add(beat, forMode: .common)

        // 1Hz 数据更新
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)

        // 模拟滚动
        let scroll = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.scrollTarget = self.rows.randomElement()?.ref
            }
        }
        RunLoop.main.add(scroll, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.measuring = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.report() }
    }

    private func tick() {
        let t0 = CACurrentMediaTime()
        var copy = rows
        let changes = max(rowCount / 20, 1)
        for _ in 0..<changes {
            let i = Int.random(in: 0..<copy.count)
            copy[i].uploadSpeed = Int64.random(in: 0...2_000_000)
            copy[i].uploaded += 1_048_576
        }
        if mode == .tableResort {
            let order = TorrentQuery.run(copy, filter: TorrentFilter(), sort: .uploadSpeed, ascending: false)
            let byRef = Dictionary(uniqueKeysWithValues: copy.map { ($0.ref, $0) })
            copy = order.map { byRef[$0]! }
        }
        rows = copy
        if measuring { tickTimes.append(CACurrentMediaTime() - t0) }
    }

    private func report() {
        measuring = false
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        let over50 = gaps.filter { $0 > 0.05 }.count
        let over100 = gaps.filter { $0 > 0.1 }.count
        let tickAvg = tickTimes.isEmpty ? 0 : tickTimes.reduce(0, +) / Double(tickTimes.count) * 1000
        print(String(
            format: "mode=%@ rows=%d  主线程间隔 p50=%.1fms p99=%.1fms max=%.1fms  >50ms=%d 次 >100ms=%d 次  数据更新本身 avg=%.1fms (%d 次)",
            mode.rawValue, rowCount, pct(0.5), pct(0.99), (sorted.last ?? 0) * 1000, over50, over100, tickAvg, tickTimes.count
        ))
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

struct BenchView: View {
    @State var model = BenchModel()

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch mode {
                case .table, .tableResort:
                    Table(model.rows) {
                        TableColumn("名称") { Text($0.name).lineLimit(1) }
                        TableColumn("状态") { Text($0.state.rawValue) }.width(110)
                        TableColumn("大小") { Text(ByteCountFormatter.string(fromByteCount: $0.totalSize, countStyle: .file)) }.width(80)
                        TableColumn("上传") { Text("\($0.uploadSpeed / 1024) KB/s").monospacedDigit() }.width(90)
                        TableColumn("分享率") { Text(String(format: "%.2f", $0.ratio)).monospacedDigit() }.width(60)
                        TableColumn("站点") { Text($0.trackerHost) }.width(90)
                        TableColumn("Tracker") { Text($0.trackerHealth.rawValue) }.width(100)
                    }
                case .list:
                    List(model.rows) { t in
                        HStack {
                            Text(t.name).lineLimit(1)
                            Spacer()
                            Text("\(t.uploadSpeed / 1024) KB/s").monospacedDigit()
                            Text(t.trackerHealth.rawValue).frame(width: 100, alignment: .trailing)
                        }
                    }
                }
            }
            .onChange(of: model.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target) }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.start() }
    }
}

@main
struct ListBenchApp: App {
    // 注意：不要在 init 里碰 NSApplication.shared（实测会导致 WindowGroup 不开窗口）。
    // 需要用 .app 包启动（swift run 起的裸二进制没有 bundle，窗口同样出不来），见 HANDOFF。
    var body: some Scene {
        WindowGroup("listbench \(mode.rawValue) \(rowCount)") { BenchView() }
    }
}
#else
@main
struct ListBenchApp {
    static func main() { print("listbench 只支持 macOS") }
}
#endif
