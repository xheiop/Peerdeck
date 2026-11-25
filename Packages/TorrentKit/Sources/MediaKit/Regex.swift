import Foundation

/// NSRegularExpression 的薄包装：解析规则大多是从 MoviePilot 的 Python 正则移植来的，保持同样的写法方便对照
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, caseSensitive: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    func matches(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 第一个匹配的各个分组（下标 0 是整个匹配）；分组没参与匹配时是 nil
    func firstGroups(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return groups(m, s)
    }

    func allGroups(_ s: String) -> [[String?]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { groups($0, s) }
    }

    /// 第一个有值的分组（不算整个匹配），对应 Python 里 findall 返回元组后取第一个非空项
    func firstCapture(_ s: String) -> String? {
        firstGroups(s)?.dropFirst().compactMap { $0 }.first { !$0.isEmpty }
    }

    func firstMatchRange(_ s: String) -> Range<String.Index>? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).flatMap { Range($0.range, in: s) }
    }

    func replacing(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private func groups(_ m: NSTextCheckingResult, _ s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

extension String {
    /// 含有汉字（含日文汉字）
    var containsCJK: Bool { unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) } }
    var isAllDigits: Bool { !isEmpty && allSatisfy { $0.isASCII && $0.isNumber } }
}

/// 中文数字转整数：一、十二、二十三、一百零五；阿拉伯数字照常解析
func chineseNumber(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let n = Int(t) { return n }
    let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    var total = 0, current = 0
    var seen = false
    for c in t {
        if let d = digits[c] { current = d; seen = true }
        else if c == "十" { total += (current == 0 && !seen ? 1 : current) * 10; current = 0; seen = true }
        else if c == "百" { total += (current == 0 ? 1 : current) * 100; current = 0; seen = true }
        else { return nil }
    }
    return seen ? total + current : nil
}
