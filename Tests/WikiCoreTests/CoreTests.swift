import XCTest
@testable import WikiCore

/// 推荐/漫游的过滤规则：标识符页、列表页、命名空间页、年份页都不该被推荐
final class InterestingFilterTests: XCTestCase {

    private func ref(_ title: String) -> ArticleRef { ArticleRef(path: title, title: title) }

    func testRejectsIdentifierAndUtilityPages() {
        let bad = ["ISBN", "DOI", "ISSN", "OCLC", "S2CID", "PMID",
                   "Digital object identifier", "International Standard Book Number",
                   "JSTOR (identifier)", "Wayback Machine (identifier)"]
        for t in bad {
            XCTAssertFalse(ZimService.isInteresting(ref(t)), "\(t) 不该被推荐")
        }
    }

    func testRejectsListNamespaceAndYearPages() {
        let bad = ["List of countries", "Lists of albums", "Index of philosophy articles",
                   "Outline of physics", "Timeline of the French Revolution",
                   "Wikipedia:About", "Template:Infobox", "Category:Physics", "Portal:History",
                   "1998", "1900 in music", "Mercury (disambiguation)"]
        for t in bad {
            XCTAssertFalse(ZimService.isInteresting(ref(t)), "\(t) 不该被推荐")
        }
    }

    func testKeepsOrdinaryArticles() {
        let good = ["Albert Einstein", "Oklahoma", "The New York Times", "World War II",
                    "McGirt v. Oklahoma", "Eiffel Tower", "1922 (novel)"]
        for t in good {
            XCTAssertTrue(ZimService.isInteresting(ref(t)), "\(t) 应该被推荐")
        }
    }

    func testRejectsEmptyTitle() {
        XCTAssertFalse(ZimService.isInteresting(ref("")))
    }
}

/// 阅读偏好 → 页面属性的映射（Aa 面板靠这条链路生效）
final class ReaderStyleTests: XCTestCase {

    func testDefaultsOmitOptionalAttributes() {
        let s = ReaderStyle()
        let a = s.htmlAttributes
        XCTAssertTrue(a.contains("data-mode=\"original\""))
        XCTAssertFalse(a.contains("data-width"))
        XCTAssertFalse(a.contains("data-font"))
        XCTAssertFalse(a.contains("data-bi"))
        XCTAssertFalse(a.contains("data-theme"))
        XCTAssertTrue(a.contains("--lhs: 1.000"))
        XCTAssertTrue(a.contains("--fs: 1.000"))
    }

    func testOptionalAttributesAreEmitted() {
        let s = ReaderStyle(mode: .bilingual, fontScale: 1.25, lineHeight: 1.12,
                            font: .hei, width: .wide, bilingualSide: true, theme: "dark")
        let a = s.htmlAttributes
        XCTAssertTrue(a.contains("data-mode=\"bilingual\""))
        XCTAssertTrue(a.contains("data-font=\"hei\""))
        XCTAssertTrue(a.contains("data-width=\"wide\""))
        XCTAssertTrue(a.contains("data-bi=\"side\""))
        XCTAssertTrue(a.contains("data-theme=\"dark\""))
        XCTAssertTrue(a.contains("--fs: 1.250"))
        XCTAssertTrue(a.contains("--lhs: 1.120"))
    }

    func testStandardWidthAndSongFontAreImplicit() {
        let s = ReaderStyle(font: .song, width: .standard)
        XCTAssertFalse(s.htmlAttributes.contains("data-font"))
        XCTAssertFalse(s.htmlAttributes.contains("data-width"))
        XCTAssertTrue(s.htmlAttributesTail.contains("--lhs"))
    }
}

/// 页面模板：属性真的写进 HTML，且内容安全策略在
final class ArticlePageTests: XCTestCase {

    func testBuiltPageCarriesStyleAndCSP() {
        let style = ReaderStyle(mode: .translated, fontScale: 1.1, lineHeight: 1.26,
                                font: .mixed, width: .full, bilingualSide: false, theme: "light")
        let html = ArticlePage.buildWithCache(path: "Albert_Einstein", title: "Albert Einstein",
                                              shortDescription: nil, body: "<p>Hello</p>",
                                              style: style, cache: ["t": ["k": "你好"]],
                                              css: "/*css*/", js: "/*js*/")
        XCTAssertTrue(html.contains("data-font=\"mixed\""))
        XCTAssertTrue(html.contains("data-width=\"full\""))
        XCTAssertTrue(html.contains("data-theme=\"light\""))
        XCTAssertTrue(html.contains("--lhs: 1.260"))
        XCTAssertFalse(html.contains("data-bi"))          // 未开并排
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("你好"))
        XCTAssertTrue(html.contains("wiki-path"))
    }

    func testNotFoundPageStillCarriesStyle() {
        let style = ReaderStyle(lineHeight: 0.88, font: .hei, width: .narrow)
        let html = ArticlePage.notFound(path: "Foobar", css: "/*css*/", js: "/*js*/", style: style)
        XCTAssertTrue(html.contains("data-font=\"hei\""))
        XCTAssertTrue(html.contains("data-width=\"narrow\""))
        XCTAssertTrue(html.contains("--lhs: 0.880"))
        XCTAssertTrue(html.contains("wiki-missing"))
    }
}

/// 历史记录的去重与限长
final class HistoryLogicTests: XCTestCase {

    private func item(_ p: String) -> HistoryItem { HistoryItem(path: p, title: p.uppercased()) }

    func testRecordMovesExistingToFront() {
        var list = [item("a"), item("b"), item("c")]
        list = HistoryLogic.record(item("b"), into: list)
        XCTAssertEqual(list.map(\.path), ["b", "a", "c"])
    }

    func testRecordHonoursLimit() {
        var list: [HistoryItem] = []
        for i in 0..<5 { list = HistoryLogic.record(item("p\(i)"), into: list, limit: 3) }
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.first?.path, "p4")
    }

    func testRecordKeepsSingleEntryPerPath() {
        var list: [HistoryItem] = []
        for _ in 0..<3 { list = HistoryLogic.record(item("same"), into: list) }
        XCTAssertEqual(list.count, 1)
    }
}

/// 清洗与摘要的纯函数
final class HTMLCleanerTests: XCTestCase {

    func testSummaryPicksFirstSubstantialParagraph() {
        // summary 只认"够长"的第一段（≥60 字符），这是提要卡片的过滤规则
        let lead = "Albert Einstein was a German-born theoretical physicist who developed the theory of relativity, one of the two pillars of modern physics."
        let html = "<p>\(lead)</p><p>Second paragraph that must be ignored.</p>"
        let s = HTMLCleaner.summary(html, maxLength: 280)
        XCTAssertFalse(s.contains("<"))
        XCTAssertTrue(s.contains("Albert Einstein"))
        XCTAssertFalse(s.contains("ignored"))
    }

    func testSummaryReturnsEmptyForShortLead() {
        XCTAssertEqual(HTMLCleaner.summary("<p>Hello world</p>", maxLength: 280), "")
    }

    func testSummaryRespectsMaxLength() {
        let long = "<p>" + String(repeating: "word ", count: 200) + "</p>"
        let s = HTMLCleaner.summary(long, maxLength: 60)
        // truncate 会在截断处补一个省略号，所以允许超出 1 个字符
        XCTAssertLessThanOrEqual(s.count, 61)
        XCTAssertFalse(s.isEmpty)
    }

    func testPlainTextDecodesEntities() {
        let s = HTMLCleaner.plainText("<p>A&nbsp;&amp; B</p>")
        XCTAssertTrue(s.contains("&"))
        XCTAssertFalse(s.contains("&amp;"))
    }
}

/// 每日推荐的伪随机数：同种子可复现
final class SplitMix64Tests: XCTestCase {

    func testSameSeedProducesSameSequence() {
        var a = SplitMix64(seed: 20261005)
        var b = SplitMix64(seed: 20261005)
        for _ in 0..<8 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiffer() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        XCTAssertNotEqual(a.next(), b.next())
    }
}
