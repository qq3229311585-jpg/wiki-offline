import Foundation
import Security

// DeepSeek 云端翻译（在线版）：批量请求、保真检查、用量计费，以及"云端优先 + 本机兜底"的混合引擎。
// 密钥只存在钥匙串里，由用户自己在设置页输入。

// MARK: - 钥匙串

public enum KeychainStore {
    public static func get(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 只判断是否存在（不读取内容，不会触发钥匙串授权弹窗）
    public static func exists(service: String, account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// 写入；value 为空则删除
    @discardableResult
    public static func set(_ value: String?, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - 配置

public enum CloudMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case cloudFirst, localOnly, cloudOnly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cloudFirst: "云端优先（推荐）"
        case .localOnly: "仅本机"
        case .cloudOnly: "仅云端"
        }
    }
    public var hint: String {
        switch self {
        case .cloudFirst: "用 DeepSeek 翻译；没网、没密钥、超预算、被拒绝或检查不通过的段落，自动改用本机翻译。"
        case .localOnly: "完全在本机翻译，不联网，不花钱。"
        case .cloudOnly: "只用 DeepSeek。失败或被拒绝的段落保持英文原文，不用本机补译。"
        }
    }
}

public enum DeepSeekModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case flash = "deepseek-flash"
    case pro = "deepseek-v4-pro"
    public var id: String { rawValue }
    public var label: String { self == .flash ? "deepseek-flash（便宜、快，推荐）" : "deepseek-v4-pro（更强、约 4 倍价格）" }

    /// 每百万 token 的美元价格（官方定价页，非高峰价；高峰价为 2 倍）
    var priceHit: Double { self == .flash ? 0.003 : 0.022 }
    var priceMiss: Double { self == .flash ? 0.15 : 0.66 }
    var priceOut: Double { self == .flash ? 0.60 : 1.98 }
}

public enum DeepSeekError: Error, LocalizedError, Sendable, Equatable {
    case noKey
    case invalidKey
    case insufficientBalance
    case budgetExceeded
    case rateLimited
    case contentRisk
    case server(Int, String)
    case network(String)
    case badResponse(String)

    /// 致命：继续请求没有意义，应暂时改用本机翻译
    public var isFatal: Bool {
        switch self {
        case .noKey, .invalidKey, .insufficientBalance, .budgetExceeded: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noKey: "还没有设置 DeepSeek 密钥"
        case .invalidKey: "DeepSeek 密钥无效（401）"
        case .insufficientBalance: "DeepSeek 账户余额不足（402）"
        case .budgetExceeded: "已达到本月预算上限"
        case .rateLimited: "请求太频繁（429）"
        case .contentRisk: "内容被 DeepSeek 拒绝翻译"
        case .server(let c, let m): "DeepSeek 服务返回 \(c)：\(m)"
        case .network(let m): m
        case .badResponse(let m): "DeepSeek 返回的内容无法解析：\(m)"
        }
    }
}

// MARK: - 用量与计费

public final class UsageMeter: @unchecked Sendable {
    public struct Month: Codable, Sendable, Equatable {
        public var key: String
        public var requests: Int
        public var hitTokens: Int
        public var missTokens: Int
        public var outTokens: Int
        public var costUSD: Double
    }

    private let lock = NSLock()
    private let file: URL
    private var month: Month

    public init(file: URL) {
        self.file = file
        let key = Self.monthKey(Date())
        if let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode(Month.self, from: d), m.key == key {
            month = m
        } else {
            month = Month(key: key, requests: 0, hitTokens: 0, missTokens: 0, outTokens: 0, costUSD: 0)
        }
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public var current: Month {
        lock.lock(); defer { lock.unlock() }
        rollIfNeeded(Date())
        return month
    }

    private func rollIfNeeded(_ now: Date) {
        let key = Self.monthKey(now)
        if month.key != key { month = Month(key: key, requests: 0, hitTokens: 0, missTokens: 0, outTokens: 0, costUSD: 0) }
    }

    /// 高峰时段（UTC 周一至周五 01–04、06–10）价格翻倍。中国法定节假日的优惠这里不计，所以估算只会偏高。
    static func isPeak(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.weekday, .hour], from: date)
        guard let wd = c.weekday, let h = c.hour, (2...6).contains(wd) else { return false }
        return (1..<4).contains(h) || (6..<10).contains(h)
    }

    public static func cost(model: DeepSeekModel, hit: Int, miss: Int, out: Int, at date: Date = Date()) -> Double {
        let f = isPeak(date) ? 2.0 : 1.0
        return f * (Double(hit) * model.priceHit + Double(miss) * model.priceMiss + Double(out) * model.priceOut) / 1_000_000
    }

    public func add(model: DeepSeekModel, hit: Int, miss: Int, out: Int, at date: Date = Date()) {
        lock.lock()
        rollIfNeeded(date)
        month.requests += 1
        month.hitTokens += hit
        month.missTokens += miss
        month.outTokens += out
        month.costUSD += Self.cost(model: model, hit: hit, miss: miss, out: out, at: date)
        let snapshot = month
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
    }
}

// MARK: - 保真检查

/// 对 DeepSeek 返回的每一段译文做基本检查。不通过的段落不采用，交给本机翻译兜底。
/// 注意：这只能挡住拒绝、截断、漏数字这类明显问题，挡不住细微的改写和弱化；核对请用"对照"模式。
public enum TranslationGuard {
    static let refusalPhrases = ["无法翻译", "无法提供", "无法回答", "无法完成", "作为AI", "作为一个AI", "作为人工智能", "我不能帮", "我无法帮",
                                 "I cannot", "I can't", "I'm sorry", "as an AI", "抱歉，我", "对不起，我"]
    static let sourceSorry = ["sorry", "apolog", "cannot", "can't", "unable", "regret", "forgive"]

    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF: return true
        default: return false
        }
    }

    public static func accept(source: String, translation: String) -> Bool {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.contains("```") || t.contains("\"id\"") { return false }

        // 拒绝话术（源文里本来就有 sorry 之类词的除外）
        let lowSource = s.lowercased()
        for p in refusalPhrases where t.contains(p) {
            if p.hasPrefix("抱歉") || p.hasPrefix("对不起") || p.hasPrefix("I'm sorry") {
                if sourceSorry.contains(where: { lowSource.contains($0) }) { continue }
            } else if lowSource.contains(p.lowercased()) { continue }
            return false
        }

        // 长度比例：英文字母数 vs 中文字符数
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        let cjk = t.unicodeScalars.filter(isCJK).count
        if letters >= 60 {
            if cjk == 0 { return false }
            if Double(cjk) / Double(letters) < 0.07 { return false }
        } else if letters >= 24, cjk == 0 {
            // 较短的段落至少应出现中文（纯专名/代码除外：大写开头词占多数时放行）
            let words = s.split(separator: " ")
            let capital = words.filter { $0.first?.isUppercase == true || $0.first?.isNumber == true }.count
            if Double(capital) < Double(words.count) * 0.8 { return false }
        }

        // 数字（年份、数量）不能丢
        let digitsRe = try! NSRegularExpression(pattern: #"\d{2,}"#)
        func numbers(_ x: String) -> [String] {
            let plain = x.replacingOccurrences(of: ",", with: "")
            return digitsRe.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap {
                Range($0.range, in: plain).map { String(plain[$0]) }
            }
        }
        let want = numbers(s)
        if want.count >= 2 {
            let have = t.replacingOccurrences(of: ",", with: "")
            let kept = want.filter { have.contains($0) }.count
            if Double(kept) < Double(want.count) * 0.75 { return false }
        }
        return true
    }
}

// MARK: - DeepSeek 翻译器

public final class DeepSeekTranslator: RawTranslator, @unchecked Sendable {
    public struct Config: Sendable {
        public var apiKey: String
        public var model: DeepSeekModel
        public var baseURL: URL
        public init(apiKey: String, model: DeepSeekModel = .flash, baseURL: URL = URL(string: "https://api.deepseek.com")!) {
            self.apiKey = apiKey
            self.model = model
            self.baseURL = baseURL
        }
    }

    public let config: Config
    private let meter: UsageMeter
    private let budgetUSD: @Sendable () -> Double
    private let session: URLSession

    /// 一次请求最多装多少字符 / 多少段
    static let chunkChars = 2600
    static let chunkItems = 14

    /// 系统提示词保持完全不变并放在最前，方便命中缓存价
    static let systemPrompt = """
    You are a professional translator for Wikipedia articles. Translate every item from English into Simplified Chinese.
    Rules:
    - Translate faithfully and completely. Never summarize, omit, soften, embellish, moralize, or add notes, warnings, or commentary. Preserve the meaning of every sentence exactly, including controversial, violent, or politically sensitive statements.
    - Keep numbers, dates, units, and bracketed markers such as [1] unchanged.
    - Use the standard Chinese rendering for well-known people, places, organizations and works. For a less-known proper noun you may write 中文（English） on its first use. If a name is Chinese written in pinyin, restore the Chinese characters when you are certain.
    - Keep the text style: titles stay short, list items stay list-like.
    - Output exactly one JSON object: {"translations":[{"id":"<same id>","zh":"<translation>"}]} with one entry per input id, in the same order, and nothing else.
    """

    public init(config: Config, meter: UsageMeter, budgetUSD: @escaping @Sendable () -> Double, session: URLSession? = nil) {
        self.config = config
        self.meter = meter
        self.budgetUSD = budgetUSD
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 120
            cfg.timeoutIntervalForResource = 240
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: RawTranslator

    public func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }
        guard !config.apiKey.isEmpty else { throw DeepSeekError.noKey }
        try checkBudget()

        // 切块
        var chunks: [[(id: String, text: String)]] = []
        var cur: [(id: String, text: String)] = []
        var chars = 0
        for it in items {
            if !cur.isEmpty && (cur.count >= Self.chunkItems || chars + it.text.count > Self.chunkChars) {
                chunks.append(cur); cur = []; chars = 0
            }
            cur.append(it); chars += it.text.count
        }
        if !cur.isEmpty { chunks.append(cur) }

        var out: [String: String] = [:]
        var lastError: Error?
        try await withThrowingTaskGroup(of: (Int, Result<[String: String], Error>).self) { group in
            for (i, c) in chunks.enumerated() {
                group.addTask { [self] in
                    do { return (i, .success(try await translateChunk(c))) } catch { return (i, .failure(error)) }
                }
            }
            for try await (_, r) in group {
                switch r {
                case .success(let m): out.merge(m) { a, _ in a }
                case .failure(let e):
                    if let d = e as? DeepSeekError, d.isFatal { throw d }
                    if e is CancellationError { throw e }
                    lastError = e
                }
            }
        }
        if out.isEmpty, let lastError { throw lastError }
        return out
    }

    /// 把中文搜索词译成英文（维基标题 / 关键词）。失败时抛错，由调用方退回本机。
    public func translateQuery(_ q: String) async throws -> String {
        guard !config.apiKey.isEmpty else { throw DeepSeekError.noKey }
        try checkBudget()
        let sys = "Translate the user's Chinese search query into the English term most likely to be the title of the matching English Wikipedia article. Output only the English text, with no quotes or explanation."
        let r = try await post(system: sys, user: q, json: false, maxTokens: 60)
        let t = r.content.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'. \n\t"))
        guard !t.isEmpty, t.count < 120 else { throw DeepSeekError.badResponse("空结果") }
        return t
    }

    /// 提前建立到 DeepSeek 的连接（第一次翻译少等一次握手）。不发送任何内容，也不计费。
    public func prewarm() async {
        var req = URLRequest(url: config.baseURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        _ = try? await session.data(for: req)
    }

    /// 设置页的"测试连接"
    public func ping() async throws -> String {
        try await translateQuery("你好")
    }

    // MARK: 内部

    private func checkBudget() throws {
        let b = budgetUSD()
        if b > 0, meter.current.costUSD >= b { throw DeepSeekError.budgetExceeded }
    }

    private func translateChunk(_ items: [(id: String, text: String)], depth: Int = 0) async throws -> [String: String] {
        let numbered = items.enumerated().map { (n: String($0.offset + 1), id: $0.element.id, text: $0.element.text) }
        let payload: [[String: String]] = numbered.map { ["id": $0.n, "text": $0.text] }
        let user = String(decoding: (try? JSONSerialization.data(withJSONObject: ["items": payload], options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)

        let result: Reply
        do {
            result = try await withRetry { try await self.post(system: Self.systemPrompt, user: user, json: true, maxTokens: 8192) }
        } catch DeepSeekError.contentRisk {
            // 整批被拒：逐段隔离，只丢掉真正被拒的那几段
            guard items.count > 1 else { return [:] }
            var merged: [String: String] = [:]
            for it in items {
                try Task.checkCancellation()
                if let m = try? await translateChunk([it], depth: depth + 1) { merged.merge(m) { a, _ in a } }
            }
            return merged
        }

        // 输出被截断：对半拆开再试
        if result.finishReason == "length" || result.finishReason == "insufficient_system_resource" {
            guard items.count > 1, depth < 3 else { return [:] }
            let mid = items.count / 2
            var merged = try await translateChunk(Array(items[..<mid]), depth: depth + 1)
            merged.merge(try await translateChunk(Array(items[mid...]), depth: depth + 1)) { a, _ in a }
            return merged
        }

        let parsed = try Self.parseTranslations(result.content)
        var out: [String: String] = [:]
        for n in numbered {
            guard let zh = parsed[n.n] else { continue }
            if TranslationGuard.accept(source: n.text, translation: zh) { out[n.id] = zh }
        }
        return out
    }

    static func parseTranslations(_ content: String) throws -> [String: String] {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw DeepSeekError.badResponse("不是 JSON")
        }
        var rows: [[String: Any]] = []
        if let d = obj as? [String: Any] {
            if let a = d["translations"] as? [[String: Any]] { rows = a }
            else if let a = d["items"] as? [[String: Any]] { rows = a }
        } else if let a = obj as? [[String: Any]] {
            rows = a
        }
        var out: [String: String] = [:]
        for r in rows {
            let id: String? = (r["id"] as? String) ?? (r["id"] as? NSNumber).map { "\($0)" }
            if let id, let zh = (r["zh"] as? String) ?? (r["translation"] as? String) { out[id] = zh }
        }
        guard !out.isEmpty else { throw DeepSeekError.badResponse("没有 translations 字段") }
        return out
    }

    /// 对"限流 / 临时故障"重试两次（指数退避）；致命错误与内容拒绝直接抛出
    private func withRetry<T>(_ op: () async throws -> T) async throws -> T {
        var delay: UInt64 = 1_200_000_000
        var attempt = 0
        while true {
            do { return try await op() } catch let e as DeepSeekError {
                let transient: Bool
                switch e {
                case .rateLimited, .network: transient = true
                case .server(let c, _): transient = c >= 500
                default: transient = false
                }
                attempt += 1
                guard transient, attempt <= 2 else { throw e }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
    }

    struct Reply {
        var content: String
        var finishReason: String?
    }

    private func post(system: String, user: String, json: Bool, maxTokens: Int, includeThinking: Bool = true) async throws -> Reply {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": config.model.rawValue,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if includeThinking { body["thinking"] = ["type": "disabled"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw DeepSeekError.network("无效的响应") }
            data = d; http = h
        } catch let e as DeepSeekError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeepSeekError.network(OnlineService.describe(error))
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errMsg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)

        switch http.statusCode {
        case 200..<300: break
        case 401: throw DeepSeekError.invalidKey
        case 402: throw DeepSeekError.insufficientBalance
        case 429: throw DeepSeekError.rateLimited
        case 400:
            let low = errMsg.lowercased()
            if low.contains("risk") || low.contains("sensitive") { throw DeepSeekError.contentRisk }
            // 个别情况下 thinking 字段不被接受：去掉后重试一次
            if includeThinking, low.contains("thinking") {
                return try await post(system: system, user: user, json: json, maxTokens: maxTokens, includeThinking: false)
            }
            throw DeepSeekError.server(400, errMsg)
        default:
            throw DeepSeekError.server(http.statusCode, errMsg)
        }

        guard let choice = (obj?["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw DeepSeekError.badResponse("缺少 choices")
        }
        if let u = obj?["usage"] as? [String: Any] {
            let prompt = (u["prompt_tokens"] as? Int) ?? 0
            let details = u["prompt_tokens_details"] as? [String: Any]
            let hit = (details?["prompt_cache_hit_tokens"] as? Int) ?? (u["prompt_cache_hit_tokens"] as? Int) ?? 0
            let miss = (details?["prompt_cache_miss_tokens"] as? Int) ?? max(prompt - hit, 0)
            meter.add(model: config.model, hit: hit, miss: miss, out: (u["completion_tokens"] as? Int) ?? 0)
        }
        let finish = choice["finish_reason"] as? String
        if finish == "content_filter" { throw DeepSeekError.contentRisk }
        return Reply(content: (message["content"] as? String) ?? "", finishReason: finish)
    }
}

// MARK: - 混合引擎：云端优先，本机兜底

public final class HybridTranslator: RawTranslator, @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var cloud = 0
        public var local = 0
        public var unresolved = 0
        public var cloudError: String?
        public init() {}
    }

    public let mode: CloudMode
    private let cloud: DeepSeekTranslator?
    private let local: RawTranslator?
    private let lock = NSLock()
    private var cooldownUntil = Date.distantPast
    private var _stats = Stats()
    /// 统计变化时回调（可能在后台线程）
    public var onChange: (@Sendable (Stats) -> Void)?

    public init(mode: CloudMode, cloud: DeepSeekTranslator?, local: RawTranslator?) {
        self.mode = mode
        self.cloud = cloud
        self.local = local
    }

    public var usesCloud: Bool { cloud != nil && mode != .localOnly }

    public func resetStats() {
        lock.lock(); _stats = Stats(); lock.unlock()
        onChange?(Stats())
    }
    public var stats: Stats { lock.lock(); defer { lock.unlock() }; return _stats }

    private func update(_ f: (inout Stats) -> Void) {
        lock.lock(); f(&_stats); let s = _stats; lock.unlock()
        onChange?(s)
    }

    private var cooling: Bool { lock.lock(); defer { lock.unlock() }; return Date() < cooldownUntil }

    public func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }
        var out: [String: String] = [:]

        if mode != .localOnly, let cloud, !cooling {
            do {
                out = try await cloud.translate(items)
                update { $0.cloud += out.count; $0.cloudError = nil }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lock.lock()
                cooldownUntil = Date().addingTimeInterval((error as? DeepSeekError)?.isFatal == true ? 120 : 20)
                lock.unlock()
                update { $0.cloudError = msg }
            }
        }

        let rest = items.filter { out[$0.id] == nil }
        if !rest.isEmpty, mode != .cloudOnly, let local {
            if let got = try? await local.translate(rest) {
                out.merge(got) { a, _ in a }
                update { $0.local += got.count }
            }
        }
        let missing = items.filter { out[$0.id] == nil }.count
        if missing > 0 { update { $0.unresolved += missing } }
        if out.isEmpty { throw DeepSeekError.network(stats.cloudError ?? "没有可用的翻译引擎") }
        return out
    }
}
