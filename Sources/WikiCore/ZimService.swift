import Foundation
@_exported import CZim

/// 一条搜索/建议结果
public struct ArticleRef: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var title: String
    public var snippet: String?
    public var redirectedFrom: String?
    public var id: String { path }

    public init(path: String, title: String, snippet: String? = nil, redirectedFrom: String? = nil) {
        self.path = path
        self.title = title
        self.snippet = snippet
        self.redirectedFrom = redirectedFrom
    }

    init(_ info: ZimEntryInfo) {
        self.init(path: info.path, title: info.title, snippet: info.snippet, redirectedFrom: info.redirectedFrom)
    }
}

/// 读出的条目内容
public struct ZimResource: Sendable {
    public var path: String
    public var title: String
    public var mimeType: String
    public var data: Data
    public var wasRedirect: Bool
    public var isHTML: Bool { mimeType.hasPrefix("text/html") }
}

/// ZIM 元信息
public struct ZimInfo: Sendable, Equatable {
    public var path: String
    public var uuid: String
    public var title: String
    public var description: String
    public var language: String
    public var date: String
    public var creator: String
    public var articleCount: Int
    public var fileSize: UInt64
    public var hasFulltextIndex: Bool
    public var hasTitleIndex: Bool
}

/// 线程安全的 ZIM 访问服务。内容读取可并发；搜索在 C++ 层串行化。
public final class ZimService: @unchecked Sendable {
    public let archive: ZimArchive
    public let info: ZimInfo

    public init(path: String) throws {
        let archive = try ZimArchive(path: path)
        self.archive = archive
        self.info = ZimInfo(
            path: path,
            uuid: archive.uuid,
            title: archive.metadata(forKey: "Title") ?? "",
            description: archive.metadata(forKey: "Description") ?? "",
            language: archive.metadata(forKey: "Language") ?? "",
            date: archive.metadata(forKey: "Date") ?? "",
            creator: archive.metadata(forKey: "Creator") ?? "",
            articleCount: Int(archive.articleCount),
            fileSize: archive.fileSize,
            hasFulltextIndex: archive.hasFulltextIndex,
            hasTitleIndex: archive.hasTitleIndex
        )
    }

    public func mainArticle() -> ArticleRef? { archive.mainEntry().map(ArticleRef.init) }

    public func randomArticle() -> ArticleRef? { archive.randomArticle().map(ArticleRef.init) }

    public func resolve(path: String) -> ArticleRef? { archive.entry(forPath: path).map(ArticleRef.init) }

    /// 解析并要求是 HTML 文章
    public func article(path: String) -> ArticleRef? { archive.article(forPath: path).map(ArticleRef.init) }

    public func content(path: String) -> ZimResource? {
        guard let c = archive.content(forPath: path) else { return nil }
        return ZimResource(path: c.path, title: c.title, mimeType: c.mimeType, data: c.data, wasRedirect: c.wasRedirect)
    }

    public func suggestions(_ query: String, limit: Int = 12) -> [ArticleRef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results = archive.suggestions(forQuery: q, limit: limit).map(ArticleRef.init)
        // 精确标题命中置顶（Xapian 排序偶尔会把精确匹配排在后面）
        if let exact = archive.entry(forTitle: q) ?? archive.entry(forTitle: Self.titleCased(q)) {
            let ref = ArticleRef(exact)
            results.removeAll { $0.path == ref.path }
            results.insert(ref, at: 0)
            if results.count > limit { results.removeLast() }
        }
        return results
    }

    public func fulltext(_ query: String, limit: Int = 30) -> (results: [ArticleRef], total: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, info.hasFulltextIndex else { return ([], 0) }
        var total = 0
        let r = archive.searchFulltext(q, limit: limit, estimatedTotal: &total)
        return (r.map(ArticleRef.init), total)
    }

    /// 确定性"每日推荐"：用日期种子在标题序上取样。取不到就退回随机。
    public func dailyPicks(seed: UInt64, count: Int) -> [ArticleRef] {
        var picks: [ArticleRef] = []
        var seen = Set<String>()
        let n = UInt64(max(archive.articleCount, 1))
        var rng = SplitMix64(seed: seed)
        var attempts = 0
        while picks.count < count && attempts < count * 12 {
            attempts += 1
            let idx = UInt32(rng.next() % n)
            guard let info = archive.article(atTitleIndex: idx) else { continue }
            let ref = ArticleRef(info)
            if seen.insert(ref.path).inserted, Self.isInteresting(ref) { picks.append(ref) }
        }
        while picks.count < count, attempts < count * 24 {
            attempts += 1
            if let r = randomArticle(), seen.insert(r.path).inserted, Self.isInteresting(r) { picks.append(r) }
        }
        return picks
    }

    /// 过滤掉列表页、消歧义页、标识符页、命名空间页等不适合做推荐/漫游的条目
    public static func isInteresting(_ ref: ArticleRef) -> Bool {
        let t = ref.title
        guard !t.isEmpty else { return false }
        // 列表 / 索引 / 大纲 / 年表
        for p in ["List of", "Lists of", "Index of", "Outline of", "Timeline of", "Glossary of", "Bibliography of"] where t.hasPrefix(p) { return false }
        // 消歧义与标识符条目
        if t.contains("(disambiguation)") || t.hasSuffix("(identifier)") || t.hasSuffix("(identifier system)") { return false }
        if identifierTitles.contains(t) { return false }
        // 非条目命名空间
        for p in ["Wikipedia:", "Template:", "Category:", "Portal:", "Help:", "File:", "Draft:", "Talk:", "Module:", "MediaWiki:"] where t.hasPrefix(p) { return false }
        // 年份页与纯数字页
        if t.range(of: #"^\d{4}( in |–| \w)"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// 纯标识符/工具类条目（在热门排名里名次很高，但不适合当"随机漫游"的目的地）
    public static let identifierTitles: Set<String> = [
        "ISBN", "ISSN", "DOI", "OCLC", "S2CID", "PMID", "PMC", "Bibcode", "JSTOR",
        "ArXiv", "PubMed Identifier", "Digital object identifier",
        "International Standard Book Number", "International Standard Serial Number",
        "Online Computer Library Center", "Semantic Scholar",
    ]

    static func titleCased(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}

/// 简单可复现的伪随机数（每日推荐用）
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
