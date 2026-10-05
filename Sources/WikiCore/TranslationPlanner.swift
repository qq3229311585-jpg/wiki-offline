import Foundation

/// 页面里一个待翻译的文本单元（段落、列表项、标题、表格单元格……）
public struct TranslationUnit: Sendable, Hashable, Codable {
    /// 由页面脚本基于原文计算的稳定键（同一原文 → 同一键）
    public var key: String
    public var text: String
    /// 文档顺序
    public var order: Int
    public init(key: String, text: String, order: Int) {
        self.key = key
        self.text = text
        self.order = order
    }
}

/// 翻译调度：先翻可见区域，再顺着往下翻有限的"前瞻"范围，滚动时再扩展。
/// 纯逻辑，不依赖翻译引擎，便于单元测试。
public struct TranslationPlanner: Sendable {
    public private(set) var units: [TranslationUnit] = []
    public private(set) var done: Set<String> = []
    public private(set) var failed: Set<String> = []
    private var inFlight: Set<String> = []

    /// 可见单元的顺序范围
    public var visibleFirst = 0
    public var visibleLast = 15
    /// 可见范围之下额外预翻的单元数
    public var lookahead = 40
    /// 可见范围之上回补的单元数
    public var lookbehind = 10

    public init() {}

    public mutating func load(units: [TranslationUnit], alreadyTranslated: Set<String>) {
        // 同一原文在页面里可能出现多次（同键），只翻一次
        var seen = Set<String>()
        self.units = units.sorted { $0.order < $1.order }.filter { seen.insert($0.key).inserted }
        self.done = alreadyTranslated.intersection(Set(self.units.map(\.key)))
        self.failed = []
        self.inFlight = []
    }

    public mutating func setVisible(first: Int, last: Int) {
        visibleFirst = max(0, min(first, last))
        visibleLast = max(first, last)
    }

    public var total: Int { units.count }
    public var completed: Int { done.count }
    public var isComplete: Bool { done.count + failed.count >= units.count }
    public var hasInFlight: Bool { !inFlight.isEmpty }
    public var progress: Double { units.isEmpty ? 1 : Double(done.count) / Double(units.count) }

    func isPending(_ u: TranslationUnit) -> Bool {
        !done.contains(u.key) && !failed.contains(u.key) && !inFlight.contains(u.key)
    }

    /// 下一批要翻译的单元；返回空表示当前窗口已经翻完（等待滚动或全部完成）
    public mutating func nextBatch(maxUnits: Int = 10, maxChars: Int = 2400) -> [TranslationUnit] {
        let lo = visibleFirst, hi = visibleLast, ahead = lookahead, behind = lookbehind
        let tiers: [(TranslationUnit) -> Bool] = [
            { $0.order >= lo && $0.order <= hi },                  // 可见区
            { $0.order > hi && $0.order <= hi + ahead },           // 下方前瞻
            { $0.order < lo && $0.order >= lo - behind },          // 上方回补
        ]
        var batch: [TranslationUnit] = []
        var chars = 0
        outer: for tier in tiers {
            for u in units where tier(u) && isPending(u) {
                if !batch.isEmpty && (batch.count >= maxUnits || chars + u.text.count > maxChars) { break outer }
                batch.append(u)
                chars += u.text.count
            }
        }
        for u in batch { inFlight.insert(u.key) }
        return batch
    }

    public mutating func markDone(_ keys: some Sequence<String>) {
        for k in keys { done.insert(k); inFlight.remove(k) }
    }

    public mutating func markFailed(_ keys: some Sequence<String>) {
        for k in keys { failed.insert(k); inFlight.remove(k) }
    }

    /// 失败的单元重新排队
    public mutating func retry(_ keys: some Sequence<String>) {
        for k in keys { failed.remove(k); inFlight.remove(k) }
    }

    /// 放回队列（例如翻译会话被取消）
    public mutating func requeue(_ keys: some Sequence<String>) {
        for k in keys { inFlight.remove(k) }
    }
}
