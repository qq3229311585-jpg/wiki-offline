import CryptoKit
import Foundation

// 在线版的数据层：从维基百科的网络接口取文章、搜索、随机、今日推荐，以及查中文标题。
// 与 ZimService 刻意保持相近的形状（路径 = 条目标题，空格写成下划线），这样阅读器与翻译缓存可以直接复用。

public struct OnlineInfo: Sendable, Equatable {
    public var title: String
    public var articleCount: Int
    public var date: String
    /// 译文库的键（相当于离线版的 ZIM uuid）
    public var uuid: String
}

public struct OnlineResource: Sendable {
    public var path: String
    public var title: String
    public var data: Data
    public var fromCache: Bool
    public var wasRedirect: Bool
}

public enum OnlineFetchResult: Sendable {
    case ok(OnlineResource)
    case notFound
    case failed(String)
}

public struct OnlinePick: Sendable {
    public var ref: ArticleRef
    public var summary: String
}

/// 中文搜索的一条命中：中文标题 + 对应的英文条目
public struct ZhSearchHit: Sendable {
    public var zhTitle: String
    public var enPath: String
    public var enTitle: String
    public var snippet: String
}

public final class OnlineService: @unchecked Sendable {
    public let info = OnlineInfo(title: "Wikipedia · 英文版（在线）", articleCount: 7_000_000, date: "实时", uuid: "wikipedia-online-en-v1")
    public static let userAgent = "WikiOnlineReader/0.1 (personal reading app for macOS; contact: local user)"

    private let session: URLSession
    private let pagesDir: URL
    // 近期查询的内存缓存（退格、重复输入时瞬时返回）
    private let cacheLock = NSLock()
    private var zhCache: [String: (at: Date, hits: [ZhSearchHit])] = [:]
    private var sugCache: [String: (at: Date, refs: [ArticleRef])] = [:]
    private static let cacheTTL: TimeInterval = 300
    private let host = "en.wikipedia.org"

    public init(supportDirectory: URL) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Encoding": "gzip, deflate"]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        pagesDir = supportDirectory.appendingPathComponent("pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
    }

    /// 提前和维基的英文站、中文站建立连接（经代理时握手要 1 秒多），第一次搜索就不用再等
    public func prewarm() async {
        for h in ["en.wikipedia.org", "zh.wikipedia.org"] {
            if let u = URL(string: "https://\(h)/w/rest.php/v1/search/title?q=a&limit=1") { _ = try? await data(u) }
        }
    }

    // MARK: 路径

    public static func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
    }

    public static func displayTitle(_ path: String) -> String { path.replacingOccurrences(of: "_", with: " ") }

    static func titleComponent(_ key: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    // MARK: HTTP

    func data(_ url: URL, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        let (d, r) = try await session.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (d, http)
    }

    func json(_ url: URL) async throws -> [String: Any] {
        let (d, http) = try await data(url, accept: "application/json")
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]) }
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    func api(_ params: [String: String], host h: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = h ?? host
        c.path = "/w/api.php"
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "formatversion", value: "2")]
        c.queryItems = items.sorted { $0.name < $1.name }
        return c.url!
    }

    // MARK: 文章

    /// 取文章 HTML（先查磁盘缓存；断网时已看过的文章仍可读）
    public func content(path: String) async -> OnlineFetchResult {
        let key = Self.normalize(path)
        guard !key.isEmpty else { return .notFound }
        if let hit = readCache(key) { return .ok(hit) }
        guard let url = URL(string: "https://\(host)/w/rest.php/v1/page/\(Self.titleComponent(key))/html") else { return .notFound }
        do {
            let (d, http) = try await data(url, accept: "text/html")
            if http.statusCode == 404 { return .notFound }
            guard (200..<300).contains(http.statusCode) else { return .failed("HTTP \(http.statusCode)") }
            let raw = String(decoding: d, as: UTF8.self)
            let canonical = Self.canonicalKey(from: http.url) ?? key
            let title = HTMLCleaner.extractTitle(raw) ?? Self.displayTitle(canonical)
            let html = OnlineHTMLAdapter.adapt(raw)
            let res = OnlineResource(path: canonical, title: title, data: Data(html.utf8), fromCache: false, wasRedirect: canonical != key)
            writeCache(res, key: canonical)
            if canonical != key { writeAlias(key, to: canonical) }
            return .ok(res)
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// 返回的最终地址里取出规范标题：…/page/<标题>/html
    static func canonicalKey(from url: URL?) -> String? {
        guard let p = url?.path, let r = p.range(of: "/page/") else { return nil }
        var t = String(p[r.upperBound...])
        if t.hasSuffix("/html") { t.removeLast(5) }
        t = normalize(t)
        return t.isEmpty ? nil : t
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "当前没有网络连接"
            case .timedOut: return "连接维基百科超时"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接到维基百科"
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: 磁盘缓存

    private func cacheURL(_ key: String, ext: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
        return pagesDir.appendingPathComponent("\(h).\(ext)")
    }

    private func writeCache(_ r: OnlineResource, key: String) {
        var out = Data("\(r.path)\t\(r.title)\n".utf8)
        out.append(r.data)
        try? out.write(to: cacheURL(key, ext: "page"), options: .atomic)
    }

    private func writeAlias(_ key: String, to canonical: String) {
        try? Data(canonical.utf8).write(to: cacheURL(key, ext: "alias"), options: .atomic)
    }

    private func readCache(_ key: String, depth: Int = 0) -> OnlineResource? {
        if let d = try? Data(contentsOf: cacheURL(key, ext: "page")),
           let nl = d.firstIndex(of: 0x0A),
           let head = String(data: d[..<nl], encoding: .utf8) {
            let parts = head.components(separatedBy: "\t")
            guard parts.count >= 2 else { return nil }
            return OnlineResource(path: parts[0], title: parts[1], data: d[d.index(after: nl)...], fromCache: true, wasRedirect: parts[0] != key)
        }
        if depth == 0, let a = try? Data(contentsOf: cacheURL(key, ext: "alias")), let canon = String(data: a, encoding: .utf8) {
            return readCache(canon, depth: 1)
        }
        return nil
    }

    /// 已缓存的条目数与占用（设置页展示）
    public func cacheStats() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var n = 0
        var total: Int64 = 0
        for f in files where f.pathExtension == "page" {
            n += 1
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (n, total)
    }

    /// 清除已缓存的文章页面（只清文章，不动译文库）
    public func clearPageCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["page", "alias"].contains(f.pathExtension) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: 搜索

    /// 标题联想（维基自己的标题搜索，含重定向）
    public func suggestions(_ query: String, limit: Int = 12) async -> [ArticleRef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let ck = "\(limit)|\(q.lowercased())"
        cacheLock.lock()
        if let hit = sugCache[ck], Date().timeIntervalSince(hit.at) < Self.cacheTTL { cacheLock.unlock(); return hit.refs }
        cacheLock.unlock()
        var c = URLComponents(string: "https://\(host)/w/rest.php/v1/search/title")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(min(limit, 50)))]
        guard let url = c.url, let obj = try? await json(url), let pages = obj["pages"] as? [[String: Any]] else { return [] }
        let refs: [ArticleRef] = pages.compactMap { p in
            guard let key = p["key"] as? String, let title = p["title"] as? String else { return nil }
            let desc = p["description"] as? String
            let matched = p["matched_title"] as? String
            return ArticleRef(path: Self.normalize(key), title: title, snippet: desc, redirectedFrom: matched)
        }
        if !refs.isEmpty { cacheLock.lock(); sugCache[ck] = (Date(), refs); cacheLock.unlock() }
        return refs
    }

    /// 全文搜索（CirrusSearch），带总命中数
    public func fulltext(_ query: String, limit: Int = 30) async -> (results: [ArticleRef], total: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], 0) }
        let url = api(["action": "query", "list": "search", "srsearch": q, "srlimit": String(min(limit, 50)),
                       "srnamespace": "0", "srinfo": "totalhits", "srprop": "snippet"])
        guard let obj = try? await json(url), let qr = obj["query"] as? [String: Any] else { return ([], 0) }
        let total = ((qr["searchinfo"] as? [String: Any])?["totalhits"] as? Int) ?? 0
        let rows = (qr["search"] as? [[String: Any]]) ?? []
        let refs = rows.compactMap { r -> ArticleRef? in
            guard let t = r["title"] as? String else { return nil }
            return ArticleRef(path: Self.normalize(t), title: t, snippet: r["snippet"] as? String)
        }
        return (refs, total)
    }

    /// 中文搜索：直接搜中文维基，并取出每条对应的英文条目（语言链接）。
    /// 中文标题是真人写的，消歧义页（如“苹果”）也会出现在结果里。
    public func zhSearch(_ query: String, limit: Int = 20) async -> [ZhSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let ck = "\(limit)|\(q)"
        cacheLock.lock()
        if let hit = zhCache[ck], Date().timeIntervalSince(hit.at) < Self.cacheTTL { cacheLock.unlock(); return hit.hits }
        cacheLock.unlock()
        // 一次请求拿到：中文标题 + 英文对应条目 + 一句话简介。不要 extracts（服务器端生成摘要很慢）。
        let url = api(["action": "query", "generator": "search", "gsrsearch": q, "gsrlimit": String(min(limit, 30)),
                       "gsrnamespace": "0", "prop": "langlinks|description", "lllang": "en", "lllimit": "max",
                       "uselang": "zh-cn"], host: "zh.wikipedia.org")
        guard let obj = try? await json(url), let qr = obj["query"] as? [String: Any], let pages = qr["pages"] as? [[String: Any]] else { return [] }
        let sorted = pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        var out: [ZhSearchHit] = []
        for p in sorted {
            guard let zh = p["title"] as? String,
                  let ll = (p["langlinks"] as? [[String: Any]])?.first(where: { ($0["lang"] as? String) == "en" }),
                  let en = ll["title"] as? String else { continue }
            let zhSimple = zh.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? zh
            let desc = ((p["description"] as? String) ?? "").applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? ""
            out.append(ZhSearchHit(zhTitle: zhSimple, enPath: Self.normalize(en), enTitle: en, snippet: desc))
        }
        if !out.isEmpty { cacheLock.lock(); zhCache[ck] = (Date(), out); cacheLock.unlock() }
        return out
    }

    // MARK: 中文标题（人工译名）

    /// 批量查英文条目对应的中文维基标题（每次最多 50 个）。返回 路径 → 中文标题。
    public func chineseTitles(for paths: [String]) async -> [String: String] {
        var result: [String: String] = [:]
        let unique = Array(Set(paths.map(Self.normalize)))
        var index = 0
        while index < unique.count {
            let chunk = Array(unique[index..<min(index + 50, unique.count)])
            index += 50
            let titles = chunk.map { Self.displayTitle($0) }.joined(separator: "|")
            let url = api(["action": "query", "prop": "langlinks", "lllang": "zh", "lllimit": "max",
                           "titles": titles, "redirects": "1"])
            guard let obj = try? await json(url), let qr = obj["query"] as? [String: Any] else { continue }
            // 规范化 / 重定向后的标题 → 原始输入
            var back: [String: String] = [:]
            for p in chunk { back[Self.displayTitle(p)] = p }
            for list in ["normalized", "redirects"] {
                for e in (qr[list] as? [[String: Any]]) ?? [] {
                    if let f = e["from"] as? String, let t = e["to"] as? String, let orig = back[f] { back[t] = orig }
                }
            }
            for page in (qr["pages"] as? [[String: Any]]) ?? [] {
                guard let t = page["title"] as? String, let orig = back[t],
                      let zh = (page["langlinks"] as? [[String: Any]])?.first(where: { ($0["lang"] as? String) == "zh" })?["title"] as? String else { continue }
                result[orig] = zh.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? zh
            }
        }
        return result
    }

    // MARK: 随机、推荐

    public func randomArticles(count: Int = 12) async -> [ArticleRef] {
        let url = api(["action": "query", "list": "random", "rnnamespace": "0", "rnlimit": String(min(count, 50))])
        guard let obj = try? await json(url), let rows = (obj["query"] as? [String: Any])?["random"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in (r["title"] as? String).map { ArticleRef(path: Self.normalize($0), title: $0) } }
    }

    public func randomArticle() async -> ArticleRef? {
        let all = await randomArticles(count: 12)
        return all.first(where: ZimService.isInteresting) ?? all.first
    }

    public func mainArticle() -> ArticleRef { ArticleRef(path: "Main_Page", title: "Main Page") }

    /// 今日推荐：当日特色条目 + 最多人阅读的条目（带摘要，不用再下载整篇）
    public func dailyPicks(count: Int = 7, shuffle: Bool = false) async -> [OnlinePick] {
        var picks: [OnlinePick] = []
        var seen = Set<String>()
        for dayOffset in [0, -1] {
            guard let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            guard let url = URL(string: String(format: "https://%@/api/rest_v1/feed/featured/%04d/%02d/%02d", host, c.year!, c.month!, c.day!)),
                  let obj = try? await json(url) else { continue }
            func pick(_ a: [String: Any]) -> OnlinePick? {
                let titles = a["titles"] as? [String: Any]
                let canonical = (titles?["canonical"] as? String) ?? (a["title"] as? String) ?? ""
                let display = (a["normalizedtitle"] as? String) ?? canonical.replacingOccurrences(of: "_", with: " ")
                guard !canonical.isEmpty else { return nil }
                let ref = ArticleRef(path: Self.normalize(canonical), title: display)
                guard ZimService.isInteresting(ref), !["Main_Page", "Special:Search"].contains(ref.path) else { return nil }
                let ex = (a["extract"] as? String) ?? (a["description"] as? String) ?? ""
                return OnlinePick(ref: ref, summary: HTMLCleaner.truncate(ex, to: 260))
            }
            if let tfa = obj["tfa"] as? [String: Any], let p = pick(tfa), seen.insert(p.ref.path).inserted { picks.append(p) }
            var most = ((obj["mostread"] as? [String: Any])?["articles"] as? [[String: Any]]) ?? []
            if shuffle { most.shuffle() } else { most = Array(most.prefix(40)) }
            for a in most where picks.count < count {
                if let p = pick(a), !p.summary.isEmpty, seen.insert(p.ref.path).inserted { picks.append(p) }
            }
            if picks.count >= count { break }
        }
        return picks
    }
}

// MARK: - HTML 适配

/// 把维基网络接口返回的 Parsoid HTML 整理成与离线包同类的形状：站内链接统一成 ./标题，去掉命名空间链接与庞大的内部数据属性。
public enum OnlineHTMLAdapter {
    static let namespaces = ["File", "Image", "Category", "Special", "Help", "Wikipedia", "WP", "Template", "Portal", "Talk",
                             "Draft", "Module", "MediaWiki", "User", "User_talk", "Wikipedia_talk", "Template_talk",
                             "Category_talk", "Help_talk", "Portal_talk", "Media", "Topic", "TimedText", "Book"]

    nonisolated(unsafe) static let dataMW = try! NSRegularExpression(pattern: #"\sdata-(?:mw|parsoid|mw-i18n)=(?:'[^']*'|"[^"]*")"#)
    nonisolated(unsafe) static let absLinks = try! NSRegularExpression(pattern: #"href="(?:https?:)?//en\.wikipedia\.org/wiki/"#)
    nonisolated(unsafe) static let nsLinks: NSRegularExpression = {
        let ns = namespaces.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"<a\b[^>]*\bhref="\./(?:"# + ns + #")(?::|%3A)[^"]*"[^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive])
    }()

    nonisolated(unsafe) static let sectionTags = try! NSRegularExpression(pattern: #"</?section\b[^>]*>"#, options: [.caseInsensitive])

    public static func adapt(_ html: String) -> String {
        var s = html
        func rep(_ re: NSRegularExpression, _ template: String) {
            s = re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        rep(dataMW, "")
        rep(absLinks, #"href="./"#)
        rep(nsLinks, "$1")
        // 网络接口的 Parsoid HTML 把每个章节包进 <section>；离线包里是平铺的（章节标题与段落同级）。
        // 阅读器的开篇两栏与目录逻辑按平铺结构 + .mw-parser-output 容器编写，这里压平并补上容器。
        rep(sectionTags, "")
        if let open = s.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let close = s.range(of: "</body>", options: [.caseInsensitive, .backwards]), open.upperBound <= close.lowerBound {
            s.replaceSubrange(close.lowerBound..<close.lowerBound, with: "</div>")
            s.replaceSubrange(open.upperBound..<open.upperBound, with: "<div class=\"mw-parser-output\">")
        }
        return s
    }
}
