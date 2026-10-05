import Foundation

/// 热门度排名：站内入链数。
///
/// 全量扫描 100 万篇（解压几十 GB HTML）对一晚上、对笔记本发热都太重，所以采用"贪心抓取采样"：
/// 从 ZIM 首页出发，每一轮读取"当前入链数最高、还没读过"的一批文章，统计它们的出链。
/// 读过几千篇核心文章后，入链数排名就很稳定了（热门文章被大量核心文章引用）。
public enum PopularityRanker {

    public struct Entry: Sendable, Hashable {
        public var path: String
        public var title: String
        public var score: Int
    }

    /// 兜底种子：首页链接太少时使用
    public static let fallbackSeeds = [
        "United_States", "World_War_II", "United_Kingdom", "India", "China", "Germany", "France", "Japan",
        "Russia", "Canada", "Australia", "Europe", "Science", "History", "Physics", "Mathematics", "Biology",
        "Chemistry", "Philosophy", "Music", "Film", "Football", "Earth", "Sun", "Water", "Human", "Language",
        "English_language", "Christianity", "Islam", "Roman_Empire", "World_War_I", "Internet", "Computer",
    ]

    /// 抽取文章里的站内链接，返回解析后的 ZIM 路径（未跟随重定向）
    public static func links(in html: String, from path: String) -> Set<String> {
        var out = Set<String>()
        let b = Array(html.utf8)
        let n = b.count
        var i = 0
        let baseDir = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        while i < n - 3 {
            // 找 "<a "
            if b[i] == UInt8(ascii: "<") && (b[i + 1] == UInt8(ascii: "a") || b[i + 1] == UInt8(ascii: "A")) && (b[i + 2] == 32 || b[i + 2] == 10 || b[i + 2] == 9) {
                guard let tag = HTMLCleaner.parseTag(b, i) else { i += 1; continue }
                if let href = hrefValue(b, tag), let p = resolve(href: href, baseDir: baseDir) {
                    out.insert(p)
                }
                i = tag.end
                continue
            }
            i += 1
        }
        return out
    }

    static func hrefValue(_ b: [UInt8], _ tag: HTMLCleaner.Tag) -> String? {
        let attrs = b[tag.attrStart..<tag.attrEnd]
        guard let r = findSub(attrs, "href=") else { return nil }
        var j = r + 5
        guard j < tag.attrEnd else { return nil }
        let q = b[j]
        if q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
            j += 1
            let s = j
            while j < tag.attrEnd && b[j] != q { j += 1 }
            return String(decoding: b[s..<j], as: UTF8.self)
        }
        let s = j
        while j < tag.attrEnd && b[j] != 32 && b[j] != UInt8(ascii: ">") { j += 1 }
        return String(decoding: b[s..<j], as: UTF8.self)
    }

    static func findSub(_ slice: ArraySlice<UInt8>, _ needle: StaticString) -> Int? {
        let len = needle.utf8CodeUnitCount
        let p = needle.utf8Start
        var i = slice.startIndex
        while i + len <= slice.endIndex {
            var ok = true
            for k in 0..<len where HTMLCleaner.lower(slice[i + k]) != p[k] { ok = false; break }
            if ok {
                // 前一个字符必须是空白（避免匹配 data-href=）
                if i == slice.startIndex || slice[i - 1] == 32 || slice[i - 1] == 10 || slice[i - 1] == 9 { return i }
            }
            i += 1
        }
        return nil
    }

    /// 相对链接 → ZIM 路径
    public static func resolve(href rawHref: String, baseDir: [String]) -> String? {
        var href = HTMLCleaner.decodeEntities(rawHref)
        if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("/") || href.contains("://") || href.hasPrefix("mailto:") || href.hasPrefix("javascript:") || href.hasPrefix("data:") { return nil }
        if let h = href.firstIndex(of: "#") { href = String(href[..<h]) }
        if let q = href.firstIndex(of: "?") { href = String(href[..<q]) }
        guard !href.isEmpty else { return nil }
        var comps = baseDir
        for part in href.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case ".", "": continue
            case "..": if !comps.isEmpty { comps.removeLast() }
            default: comps.append(String(part))
            }
        }
        guard !comps.isEmpty else { return nil }
        let joined = comps.joined(separator: "/")
        let decoded = joined.removingPercentEncoding ?? joined
        // 资源路径不是文章
        if decoded.hasPrefix("_") || decoded.hasPrefix("-/") || decoded.hasPrefix("I/") || decoded.hasPrefix("M/") { return nil }
        return decoded
    }

    /// 执行排名。maxArticles：采样读取的文章数；keepTop：保留的排名长度。
    /// shouldStop 返回 true 时尽快结束并返回当前结果。
    public static func rank(
        service: ZimService,
        maxArticles: Int = 4000,
        keepTop: Int = 60000,
        roundSize: Int = 200,
        shouldStop: () -> Bool = { false },
        progress: (_ read: Int, _ discovered: Int) -> Void = { _, _ in }
    ) -> [Entry] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var visited = Set<String>()
        var seq = 0

        func note(_ p: String) {
            counts[p, default: 0] += 1
            if firstSeen[p] == nil { firstSeen[p] = seq; seq += 1 }
        }

        // 种子：首页链接（按出现顺序给一点初始分），不足再加兜底
        var seeds: [String] = []
        if let main = service.mainArticle(), let res = service.content(path: main.path) {
            let html = String(decoding: res.data, as: UTF8.self)
            seeds = orderedLinks(in: html, from: res.path)
            visited.insert(res.path)
        }
        if seeds.count < 30 { seeds += fallbackSeeds }
        for (i, s) in seeds.enumerated() where firstSeen[s] == nil {
            firstSeen[s] = i
            counts[s, default: 0] += 1
        }
        seq = seeds.count

        var read = 0
        while read < maxArticles && !shouldStop() {
            // 本轮：入链最多、未读过的一批
            let batch = counts.lazy.filter { !visited.contains($0.key) }
                .sorted { a, b in a.value != b.value ? a.value > b.value : (firstSeen[a.key] ?? .max) < (firstSeen[b.key] ?? .max) }
                .prefix(roundSize)
                .map(\.key)
            if batch.isEmpty { break }
            for p in batch {
                if shouldStop() { break }
                visited.insert(p)
                guard let res = service.content(path: p), res.isHTML else { continue }
                if res.path != p { visited.insert(res.path) }
                autoreleasepool {
                    let html = HTMLCleaner.clean(HTMLCleaner.extractBody(String(decoding: res.data, as: UTF8.self)), extraRemovedClasses: HTMLCleaner.linkNoiseClasses)
                    for l in links(in: html, from: res.path) where l != res.path { note(l) }
                }
                read += 1
                if read % 50 == 0 { progress(read, counts.count) }
                if read >= maxArticles { break }
            }
        }
        progress(read, counts.count)

        // 合并重定向：解析排名靠前的原始路径到规范路径
        let candidates = counts.sorted { $0.value != $1.value ? $0.value > $1.value : (firstSeen[$0.key] ?? .max) < (firstSeen[$1.key] ?? .max) }
            .prefix(keepTop * 2)
        var merged: [String: (title: String, score: Int, first: Int)] = [:]
        for (p, c) in candidates {
            guard let ref = service.article(path: p), !ref.title.hasSuffix("(identifier)"), !ref.title.hasSuffix("(disambiguation)") else { continue }
            if !ref.path.isEmpty, let existing = merged[ref.path] {
                merged[ref.path] = (existing.title, existing.score + c, min(existing.first, firstSeen[p] ?? .max))
            } else {
                merged[ref.path] = (ref.title, c, firstSeen[p] ?? .max)
            }
        }
        let entries = merged
            .sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.value.first < $1.value.first }
            .prefix(keepTop)
            .map { Entry(path: $0.key, title: $0.value.title, score: $0.value.score) }
        return Array(entries)
    }

    /// 按出现顺序的链接（去重）
    public static func orderedLinks(in html: String, from path: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let b = Array(html.utf8)
        let baseDir = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        var i = 0
        while i < b.count - 3 {
            if b[i] == UInt8(ascii: "<") && (b[i + 1] == UInt8(ascii: "a") || b[i + 1] == UInt8(ascii: "A")) && (b[i + 2] == 32 || b[i + 2] == 10 || b[i + 2] == 9), let tag = HTMLCleaner.parseTag(b, i) {
                if let href = hrefValue(b, tag), let p = resolve(href: href, baseDir: baseDir), seen.insert(p).inserted { out.append(p) }
                i = tag.end
                continue
            }
            i += 1
        }
        return out
    }
}
