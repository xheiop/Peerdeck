import Foundation

/// tracker 报错文案分类。PT 站文案五花八门，这里只做关键词匹配，命中「未注册」类就提示可以删种。
/// 关键词表需要真实站点样本补充（M0 没有中文样本）。
public enum TrackerMessageKind: String, Sendable {
    case unregistered
    case other
}

public enum TrackerMessages {
    public static let unregisteredKeywords = [
        "unregistered", "not registered", "torrent not found", "torrent not exists", "torrent does not exist",
        "infohash not found", "deleted", "trumped", "nuked",
        "未注册", "不存在", "已被删除", "已删除", "被删除",
    ]

    public static func classify(_ message: String) -> TrackerMessageKind {
        let m = message.lowercased()
        return unregisteredKeywords.contains { m.contains($0) } ? .unregistered : .other
    }
}
