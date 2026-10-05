import XCTest
@testable import WikiCore

/// 模拟 DeepSeek 服务器：按请求内容返回预设响应，记录请求次数
final class MockDeepSeek: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        var body: [String: Any] = [:]
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536); var acc = Data()
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; acc.append(buf, count: n) }
            data = acc
        }
        if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { body = o }
        let (code, json) = Self.handler?(request, body) ?? (500, [:])
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DeepSeekTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        MockDeepSeek.requests = 0
        MockDeepSeek.handler = nil
    }

    private func translator(budget: Double = 100, key: String = "sk-test") -> (DeepSeekTranslator, UsageMeter) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockDeepSeek.self]
        let meter = UsageMeter(file: tmp.appendingPathComponent("usage.json"))
        let t = DeepSeekTranslator(config: .init(apiKey: key, model: .flash), meter: meter, budgetUSD: { budget }, session: URLSession(configuration: cfg))
        return (t, meter)
    }

    /// 取出请求里编号的原文
    private func inputItems(_ body: [String: Any]) -> [(id: String, text: String)] {
        let msgs = body["messages"] as? [[String: String]] ?? []
        let user = msgs.last?["content"] ?? "{}"
        let obj = (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any]
        return ((obj?["items"] as? [[String: String]]) ?? []).map { (id: $0["id"] ?? "", text: $0["text"] ?? "") }
    }

    private func okReply(_ pairs: [(String, String)], finish: String = "stop") -> (Int, [String: Any]) {
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["translations": pairs.map { ["id": $0.0, "zh": $0.1] }]), as: UTF8.self)
        return (200, ["choices": [["message": ["content": content], "finish_reason": finish]],
                      "usage": ["prompt_tokens": 1000, "completion_tokens": 500, "prompt_tokens_details": ["prompt_cache_hit_tokens": 400, "prompt_cache_miss_tokens": 600]]])
    }

    static let longEN = "The mitochondrion is an organelle found in the cells of most eukaryotes, such as animals, plants and fungi, and it has a double membrane structure."
    static let longZH = "线粒体是存在于大多数真核生物细胞中的细胞器，例如动物、植物和真菌，它具有双层膜结构。"

    // MARK: 保真检查

    func testGuardAcceptsNormalTranslation() {
        XCTAssertTrue(TranslationGuard.accept(source: Self.longEN, translation: Self.longZH))
        XCTAssertTrue(TranslationGuard.accept(source: "Paris", translation: "巴黎"))
    }

    func testGuardRejectsRefusalEmptyAndEcho() {
        XCTAssertFalse(TranslationGuard.accept(source: Self.longEN, translation: "抱歉，我无法翻译这段内容。"))
        XCTAssertFalse(TranslationGuard.accept(source: Self.longEN, translation: ""))
        XCTAssertFalse(TranslationGuard.accept(source: Self.longEN, translation: Self.longEN), "原样返回英文不算翻译")
        XCTAssertFalse(TranslationGuard.accept(source: Self.longEN, translation: "好的。"), "长原文只给一两个字，视为截断")
    }

    func testGuardAllowsSorryWhenSourceHasIt() {
        XCTAssertTrue(TranslationGuard.accept(source: "He said, \"I'm sorry, I did not know about the plan before it was announced in 1998.\"",
                                              translation: "他说：“抱歉，我在1998年宣布该计划之前并不知情。”"))
    }

    func testGuardRequiresNumbersKept() {
        let src = "The war lasted from 1914 to 1918 and killed about 20,000,000 people in 1916 alone across 12 countries."
        XCTAssertTrue(TranslationGuard.accept(source: src, translation: "这场战争从1914年持续到1918年，仅在1916年就造成约20,000,000人死亡，涉及12个国家。"))
        XCTAssertFalse(TranslationGuard.accept(source: src, translation: "这场战争持续了几年，造成了很多人死亡，涉及多个国家，影响极其深远，至今仍被人们反复讨论。"))
    }

    // MARK: 解析

    func testParseVariants() throws {
        XCTAssertEqual(try DeepSeekTranslator.parseTranslations(#"{"translations":[{"id":"1","zh":"甲"},{"id":2,"zh":"乙"}]}"#), ["1": "甲", "2": "乙"])
        XCTAssertEqual(try DeepSeekTranslator.parseTranslations("```json\n{\"translations\":[{\"id\":\"1\",\"zh\":\"甲\"}]}\n```"), ["1": "甲"])
        XCTAssertThrowsError(try DeepSeekTranslator.parseTranslations("这不是 JSON"))
    }

    // MARK: 翻译器

    func testSuccessAndUsageMetering() async throws {
        MockDeepSeek.handler = { [self] _, body in
            let items = inputItems(body)
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(body["model"] as? String, "deepseek-flash")
            return okReply(items.map { ($0.id, Self.longZH) })
        }
        let (t, meter) = translator()
        let r = try await t.translate([(id: "a#0", text: Self.longEN), (id: "b#0", text: Self.longEN)])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r["a#0"], Self.longZH)
        let m = meter.current
        XCTAssertEqual(m.requests, 1)
        XCTAssertEqual(m.hitTokens, 400); XCTAssertEqual(m.missTokens, 600); XCTAssertEqual(m.outTokens, 500)
        XCTAssertGreaterThan(m.costUSD, 0)
        XCTAssertLessThan(m.costUSD, 0.001)
    }

    func testMissingAndRefusedItemsAreDropped() async throws {
        MockDeepSeek.handler = { [self] _, body in
            // 只返回第 1、2 条；第 2 条是拒绝话术；第 3 条缺失
            okReply([("1", Self.longZH), ("2", "抱歉，我无法翻译这段内容。")])
        }
        let (t, _) = translator()
        let r = try await t.translate([(id: "x", text: Self.longEN), (id: "y", text: Self.longEN), (id: "z", text: Self.longEN)])
        XCTAssertEqual(Set(r.keys), ["x"])
    }

    func testInvalidKeyIsFatal() async {
        MockDeepSeek.handler = { _, _ in (401, ["error": ["message": "Authentication Fails"]]) }
        let (t, _) = translator()
        do { _ = try await t.translate([(id: "x", text: Self.longEN)]); XCTFail("应当抛错") } catch {
            XCTAssertEqual(error as? DeepSeekError, .invalidKey)
            XCTAssertTrue((error as? DeepSeekError)?.isFatal == true)
        }
    }

    func testNoKeyAndBudget() async {
        let (noKey, _) = translator(key: "")
        do { _ = try await noKey.translate([(id: "x", text: "Hello world, this is a test.")]); XCTFail() } catch {
            XCTAssertEqual(error as? DeepSeekError, .noKey)
        }
        MockDeepSeek.handler = { [self] _, body in okReply(inputItems(body).map { ($0.id, Self.longZH) }) }
        let (t, meter) = translator(budget: 0.0000001)
        meter.add(model: .flash, hit: 0, miss: 100_000, out: 100_000)   // 先用掉一点
        do { _ = try await t.translate([(id: "x", text: Self.longEN)]); XCTFail() } catch {
            XCTAssertEqual(error as? DeepSeekError, .budgetExceeded)
        }
        XCTAssertEqual(MockDeepSeek.requests, 0, "超预算时不应发请求")
    }

    func testContentRiskIsolatesBadItem() async throws {
        MockDeepSeek.handler = { [self] _, body in
            let items = inputItems(body)
            // 含 "forbidden" 的段落会触发风控：整批含它就整批拒绝；单独发它也拒绝
            if items.contains(where: { $0.text.contains("forbidden") }) {
                return (400, ["error": ["message": "Content Exists Risk"]])
            }
            return okReply(items.map { ($0.id, Self.longZH) })
        }
        let (t, _) = translator()
        let bad = "This forbidden passage describes sensitive events in great detail across many sentences so it is long enough to be checked."
        let r = try await t.translate([(id: "good1", text: Self.longEN), (id: "bad", text: bad), (id: "good2", text: Self.longEN)])
        XCTAssertEqual(Set(r.keys), ["good1", "good2"], "被拒的段落被隔离，其余照常翻译")
    }

    func testRateLimitRetriesThenSucceeds() async throws {
        nonisolated(unsafe) var n = 0
        MockDeepSeek.handler = { [self] _, body in
            n += 1
            if n == 1 { return (429, ["error": ["message": "rate limit"]]) }
            return okReply(inputItems(body).map { ($0.id, Self.longZH) })
        }
        let (t, _) = translator()
        let r = try await t.translate([(id: "x", text: Self.longEN)])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(MockDeepSeek.requests, 2)
    }

    func testTruncatedOutputIsSplit() async throws {
        MockDeepSeek.handler = { [self] _, body in
            let items = inputItems(body)
            if items.count > 1 { return okReply([], finish: "length") }       // 一次装不下：被截断
            return okReply(items.map { ($0.id, Self.longZH) })
        }
        let (t, _) = translator()
        let r = try await t.translate([(id: "a", text: Self.longEN), (id: "b", text: Self.longEN), (id: "c", text: Self.longEN), (id: "d", text: Self.longEN)])
        XCTAssertEqual(r.count, 4)
    }

    func testQueryTranslation() async throws {
        MockDeepSeek.handler = { _, _ in
            (200, ["choices": [["message": ["content": "\"Mitochondrion\""], "finish_reason": "stop"]], "usage": ["prompt_tokens": 60, "completion_tokens": 4]])
        }
        let (t, _) = translator()
        let q = try await t.translateQuery("线粒体")
        XCTAssertEqual(q, "Mitochondrion")
    }

    // MARK: 混合引擎

    func testHybridFallsBackToLocalAndCoolsDown() async throws {
        MockDeepSeek.handler = { _, _ in (401, ["error": ["message": "Authentication Fails"]]) }
        let (cloud, _) = translator()
        let h = HybridTranslator(mode: .cloudFirst, cloud: cloud, local: FakeTranslator(delay: .milliseconds(1)))
        let r1 = try await h.translate([(id: "a", text: Self.longEN)])
        XCTAssertEqual(r1["a"], "〔译〕" + Self.longEN)
        XCTAssertEqual(h.stats.local, 1)
        XCTAssertNotNil(h.stats.cloudError)
        let before = MockDeepSeek.requests
        _ = try await h.translate([(id: "b", text: Self.longEN)])
        XCTAssertEqual(MockDeepSeek.requests, before, "冷却期内不再请求云端")
    }

    func testHybridCloudOnlyDoesNotUseLocal() async {
        MockDeepSeek.handler = { _, _ in (401, ["error": ["message": "Authentication Fails"]]) }
        let (cloud, _) = translator()
        let h = HybridTranslator(mode: .cloudOnly, cloud: cloud, local: FakeTranslator(delay: .milliseconds(1)))
        do { _ = try await h.translate([(id: "a", text: Self.longEN)]); XCTFail("仅云端失败时不应用本机补译") } catch {}
        XCTAssertEqual(h.stats.local, 0)
    }

    func testHybridCloudFirstPartialFallsBackOnlyForMissing() async throws {
        MockDeepSeek.handler = { [self] _, body in
            let items = inputItems(body)
            return okReply(items.prefix(1).map { ($0.id, Self.longZH) })     // 只回第一条
        }
        let (cloud, _) = translator()
        let h = HybridTranslator(mode: .cloudFirst, cloud: cloud, local: FakeTranslator(delay: .milliseconds(1)))
        let r = try await h.translate([(id: "a", text: Self.longEN), (id: "b", text: Self.longEN)])
        XCTAssertEqual(r["a"], Self.longZH)
        XCTAssertEqual(r["b"], "〔译〕" + Self.longEN)
        XCTAssertEqual(h.stats.cloud, 1); XCTAssertEqual(h.stats.local, 1)
    }

    // MARK: 计费

    func testPeakPricing() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let mondayPeak = cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 2))!      // 周一 UTC 02:00
        let sundayNight = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 18))!    // 周日
        XCTAssertTrue(UsageMeter.isPeak(mondayPeak))
        XCTAssertFalse(UsageMeter.isPeak(sundayNight))
        let off = UsageMeter.cost(model: .flash, hit: 0, miss: 1_000_000, out: 1_000_000, at: sundayNight)
        XCTAssertEqual(off, 0.75, accuracy: 1e-9)
        XCTAssertEqual(UsageMeter.cost(model: .flash, hit: 0, miss: 1_000_000, out: 1_000_000, at: mondayPeak), 1.5, accuracy: 1e-9)
        XCTAssertEqual(UsageMeter.cost(model: .pro, hit: 0, miss: 1_000_000, out: 1_000_000, at: sundayNight), 2.64, accuracy: 1e-9)
    }

    // MARK: 参考文献里的英文标题不应被名字回填弄成中英混杂

    func testBackfillSkippedForMostlyEnglishText() async throws {
        // 本机引擎把整条参考文献基本原样返回（只翻了 Retrieved），不该往英文标题里塞“（Xinjiang）”
        final class Echo: RawTranslator, @unchecked Sendable {
            func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
                var o: [String: String] = [:]
                for it in items { o[it.id] = it.text.replacingOccurrences(of: "Retrieved", with: "检索于") }
                return o
            }
        }
        let ref = "Kang, Dake (26 November 2022). \"10 killed in apartment fire in northwest China's Xinjiang\". Associated Press News. Retrieved 27 November 2022."
        let link = UnitLink(text: "Xinjiang", path: "Xinjiang")
        let r = try await TranslationPipeline.translate([PipelineInput(key: "ref", text: ref, links: [link])], with: Echo(),
                                                        glossary: nil, titleZh: { $0 == "Xinjiang" ? "新疆维吾尔自治区" : nil })
        XCTAssertFalse(r.translations["ref"]!.contains("新疆维吾尔自治区"), "英文标题里不应被插入中文译名")
        // 正常的中文译文仍然回填：英文名残留 → 中文（English）
        let prose = "2022年11月24日，Xinjiang 一栋建筑发生火灾，造成十人死亡，当时已经封控了三个月。"
        let r2 = try await TranslationPipeline.translate([PipelineInput(key: "p", text: "A fire broke out in a building in Xinjiang.", links: [link])],
                                                         with: FixedZh(prose), glossary: nil, titleZh: { $0 == "Xinjiang" ? "新疆维吾尔自治区" : nil })
        XCTAssertTrue(r2.translations["p"]!.contains("新疆维吾尔自治区（Xinjiang）"))
    }

    func testLatinBinomialIsNotSplitByGlossaryOrBackfill() {
        // 学名 Danio rerio：属名不能被单拎出来加“鿕属（Danio）”
        let g = Glossary(terms: [("Danio", "鿕属")], selfTerms: [])
        XCTAssertEqual(g.postFix("斑马鱼（Danio rerio）是一种淡水鱼。"), "斑马鱼（Danio rerio）是一种淡水鱼。")
        XCTAssertEqual(g.postFix("斑马鱼（Danio rerio是一种淡水鱼。"), "斑马鱼（Danio rerio是一种淡水鱼。")
        // 单独出现的属名照常加注
        XCTAssertEqual(g.postFix("该类群属于 Danio 及其近缘。"), "该类群属于 鿕属（Danio） 及其近缘。")
        let link = UnitLink(text: "Danio", path: "Danio")
        XCTAssertEqual(TranslationPipeline.backfill("斑马鱼（Danio rerio）是一种淡水鱼。", links: [link], titleZh: { _ in "鿕属" }),
                       "斑马鱼（Danio rerio）是一种淡水鱼。")
        XCTAssertEqual(TranslationPipeline.backfill("该类群属于 Danio 及其近缘。", links: [link], titleZh: { _ in "鿕属" }),
                       "该类群属于 鿕属（Danio） 及其近缘。")
    }

    func testLegacyUnitsArchivedOnceAndEnginesStaySeparate() throws {
        let store = try TranslationStore(url: tmp.appendingPathComponent("ns.sqlite"))
        store.add(["k1": "旧译文（来源不明）"], for: "Mitochondria")
        store.add(["k1": "云端译文"], for: "ds:Mitochondria")
        store.archiveLegacyUnitsOnce()
        XCTAssertTrue(store.translations(for: "Mitochondria").isEmpty, "旧译文被收起，本机缓存从干净状态开始")
        XCTAssertEqual(store.translations(for: "legacy:Mitochondria")["k1"], "旧译文（来源不明）", "只是改名，没有删除")
        XCTAssertEqual(store.translations(for: "ds:Mitochondria")["k1"], "云端译文", "云端那份不受影响")
        // 只做一次：之后新写入本机缓存的内容不会再被收起
        store.add(["k2": "本机译文"], for: "Mitochondria")
        store.archiveLegacyUnitsOnce()
        XCTAssertEqual(store.translations(for: "Mitochondria")["k2"], "本机译文")
        // 两个引擎互不影响，清除也只清当前这一份
        store.clearTranslations(for: "ds:Mitochondria")
        XCTAssertTrue(store.translations(for: "ds:Mitochondria").isEmpty)
        XCTAssertEqual(store.translations(for: "Mitochondria")["k2"], "本机译文")
    }

    func testChineseShare() {
        XCTAssertGreaterThan(TranslationPipeline.chineseShare("线粒体是细胞器"), 0.9)
        XCTAssertLessThan(TranslationPipeline.chineseShare("Associated Press News. 检索于2022"), 0.3)
    }
}

private final class FixedZh: RawTranslator, @unchecked Sendable {
    let zh: String
    init(_ zh: String) { self.zh = zh }
    func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, zh) })
    }
}
