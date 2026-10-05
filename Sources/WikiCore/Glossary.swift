import Foundation

/// 专名术语表：把英文专名（人名、地名、机构名……）在送去翻译之前替换成中文，避免译文里残留 "Xi" 这类拼音。
///
/// 来源：
///   1. 文章内所有站内链接：锚文本 → 目标条目 → 目标标题的中文译名（标题缓存 / 即时翻译）
///   2. 本条目自指：英文全名 → 中文标题；以及正文里高频出现的"简称"（如 Xi、Einstein）
public struct Glossary: Sendable {
    public private(set) var terms: [(en: String, zh: String)] = []
    private var regex: NSRegularExpression?
    /// 译后替换用：与 regex 相同，但跳过拉丁学名（后面紧跟小写种加词，如 Danio rerio）
    private var postRegex: NSRegularExpression?
    private var map: [String: String] = [:]
    /// 本条目自指（全名 / 简称）：翻译前预替换
    private var selfTerms: Set<String> = []
    private var selfRegex: NSRegularExpression?

    public init(terms raw: [(String, String)], selfTerms: [String] = []) {
        var seen = Set<String>()
        var list: [(en: String, zh: String)] = []
        for (en, zh) in raw {
            let e = en.trimmingCharacters(in: .whitespaces)
            let z = Glossary.cleanZh(zh)
            guard e.count >= 2, !z.isEmpty, ScriptDetector.containsCJK(z), !Glossary.containsLatin(z), seen.insert(e).inserted else { continue }
            list.append((e, z))
        }
        list.sort { $0.en.count > $1.en.count }
        terms = list
        for t in list { map[t.en] = t.zh }
        if !list.isEmpty {
            let alts = list.map { NSRegularExpression.escapedPattern(for: $0.en) }.joined(separator: "|")
            regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alts))(?![\\p{L}\\p{N}])")
            // 学名 "Genus species"：属名后面紧跟小写拉丁词，整体应保持原样，不能把属名单拎出来加中文括注
            postRegex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alts))(?![\\p{L}\\p{N}])(?!\\s+\\p{Ll}{3,}(?!\\p{Ll}))")
        }
        self.selfTerms = Set(selfTerms.filter { map[$0] != nil })
        if !self.selfTerms.isEmpty {
            let alts = self.selfTerms.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            // 简称后紧跟另一个大写词（如 "Xi Zhongxun"）说明是别人的名字，不替换
            selfRegex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alts))(?![\\p{L}\\p{N}])(?!\\s+\\p{Lu})")
        }
    }

    /// 翻译前：只替换本条目自指（实测：对所有专名预替换会诱发幻觉，例如 Shanghai 被当成动词）
    public func preApply(_ text: String) -> String {
        guard let selfRegex else { return text }
        return replace(text, with: selfRegex) { en, _ in map[en] ?? en }
    }

    /// 翻译后：译文里残留的英文专名 → 自指用"中文"，其他用"中文（English）"（同一段只括注一次）
    public func postFix(_ translation: String) -> String {
        guard let postRegex, Glossary.containsLatin(translation) else { return translation }
        var annotated = Set<String>()
        return replace(translation, with: postRegex) { en, ctx in
            guard let zh = map[en] else { return en }
            if selfTerms.contains(en) { return zh }
            // 已经是 "（English）" 括注的一部分就不动
            if ctx.hasSuffix("（") || ctx.hasSuffix("(") { return en }
            if annotated.insert(en).inserted { return "\(zh)（\(en)）" }
            return zh
        }
    }

    private func replace(_ text: String, with re: NSRegularExpression, _ f: (String, String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range), out)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// 把原文里的专名替换为中文
    public func apply(_ text: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let en = ns.substring(with: m.range)
            out += map[en] ?? en
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 译文里如果仍残留术语表里的英文专名，替换成"中文"
    public func fixResidue(_ translation: String) -> String {
        guard regex != nil, Glossary.containsLatin(translation) else { return translation }
        return apply(translation)
    }

    // MARK: 构建

    /// 只有"像专名"的锚文本才进术语表：每个实词首字母大写，且不是常见普通词
    public static func looksProper(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard !words.isEmpty, words.count <= 6 else { return false }
        let connectors: Set<String> = ["of", "the", "and", "de", "del", "da", "di", "von", "van", "der", "la", "le", "du", "y", "al", "bin", "ibn", "on", "upon", "in"]
        var capitalized = 0
        for w in words {
            let ws = String(w)
            if connectors.contains(ws) { continue }
            guard let f = ws.unicodeScalars.first else { return false }
            if CharacterSet.uppercaseLetters.contains(f) { capitalized += 1 } else if CharacterSet.decimalDigits.contains(f) { continue } else { return false }
        }
        guard capitalized > 0 else { return false }
        if words.count == 1 && commonWords.contains(s) { return false }
        return true
    }

    static let commonWords: Set<String> = [
        "The", "A", "An", "In", "On", "At", "He", "She", "It", "They", "We", "This", "That", "These", "Those", "His", "Her", "Its", "Their",
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "English", "American", "British", "French", "German",
        "Chinese", "Japanese", "Russian", "Spanish", "Italian", "European", "African", "Asian", "Christian", "Muslim", "Jewish", "Catholic",
        "God", "Earth", "Sun", "Moon", "King", "Queen", "President", "Prime", "Minister", "Emperor", "Pope", "Saint", "St", "Sir", "Lord",
        "North", "South", "East", "West", "New", "Old", "Great", "United", "States", "State", "Kingdom", "Republic", "Empire", "Party",
        "University", "College", "School", "River", "Lake", "Mount", "Island", "City", "County", "Province", "War", "Battle", "Army", "Navy",
        "Church", "Act", "Award", "Prize", "Cup", "League", "Club", "Company", "Group", "Band", "Album", "Film", "Series", "Season",
        "I", "II", "III", "IV", "V", "VI", "Jr", "Sr", "Mr", "Mrs", "Dr", "No", "Yes", "One", "Two", "First", "Second", "Third",
    ]

    /// 本条目的"简称"：标题里在正文中单独高频出现的那个词（例如 Xi Jinping → Xi，Albert Einstein → Einstein）
    public static func shortForm(title: String, texts: [String]) -> String? {
        let base = title.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        let tokens = base.split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens.count <= 4, tokens.allSatisfy({ $0.first?.isUppercase ?? false }) else { return nil }
        let joined = texts.joined(separator: "\n")
        var best: (String, Int)? = nil
        for t in Set(tokens) where t.count >= 2 && !commonWords.contains(t) && t.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) {
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])\(NSRegularExpression.escapedPattern(for: t))(?![\\p{L}])") else { continue }
            let total = re.numberOfMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
            let full = joined.components(separatedBy: base).count - 1
            let standalone = total - full
            if standalone >= 3, standalone > (best?.1 ?? 0) { best = (t, standalone) }
        }
        return best?.0
    }

    /// 简称对应的中文：中文名带"·"且段数与英文词数一致 → 取对应段；否则用中文全名（中文人名习惯写全名）
    public static func shortFormZh(title: String, titleZh: String, short: String) -> String {
        let base = title.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        let tokens = base.split(separator: " ").map(String.init)
        let zh = cleanZh(titleZh)
        let parts = zh.split(whereSeparator: { $0 == "·" || $0 == "•" || $0 == "・" }).map(String.init)
        if parts.count == tokens.count, parts.count > 1, let i = tokens.firstIndex(of: short) { return parts[i] }
        return zh
    }

    /// 锚文本与目标条目标题是否"说的是同一个东西"
    /// （防止 "Fujian" 链到 "Chinese aircraft carrier Fujian" 时被替换成航母）
    public static func anchorMatches(_ anchor: String, title: String) -> Bool {
        let a = anchor.lowercased().replacingOccurrences(of: "_", with: " ")
        let base = title.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression).lowercased()
        if a == base { return true }
        // 缩写：CCP → Chinese Communist Party
        if anchor.count >= 2, anchor.count <= 6, anchor.allSatisfy({ $0.isUppercase || $0.isNumber }) { return true }
        let aw = Set(a.split(separator: " ")), tw = base.split(separator: " ")
        // 锚文本是标题的一部分，且标题最多多一个词（Einstein → Albert Einstein）
        return !aw.isEmpty && aw.isSubset(of: Set(tw)) && tw.count <= aw.count + 1
    }

    /// 汇总构建。targets：原始链接路径 → (规范路径, 英文标题, 中文标题?)
    public static func build(
        articleTitle: String,
        articleTitleZh: String?,
        links: [UnitLink],
        texts: [String],
        target: (String) -> (en: String, zh: String?)?
    ) -> Glossary {
        var raw: [(String, String)] = []
        var selfs: [String] = []
        if let tz = articleTitleZh {
            let base = articleTitle.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            if looksProper(base) {
                raw.append((base, tz))
                selfs.append(base)
                if let s = shortForm(title: articleTitle, texts: texts) {
                    raw.append((s, shortFormZh(title: articleTitle, titleZh: tz, short: s)))
                    selfs.append(s)
                }
            }
        }
        var seen = Set<String>()
        for l in links where looksProper(l.text) && !seen.contains(l.text) {
            guard let t = target(l.path), let zh = t.zh, anchorMatches(l.text, title: t.en) else { continue }
            seen.insert(l.text)
            raw.append((l.text, zh))
        }
        return Glossary(terms: raw, selfTerms: selfs)
    }

    /// 旧接口：只给中文标题（用于测试）
    public static func build(
        articleTitle: String,
        articleTitleZh: String?,
        links: [UnitLink],
        texts: [String],
        titleZh: (String) -> String?
    ) -> Glossary {
        build(articleTitle: articleTitle, articleTitleZh: articleTitleZh, links: links, texts: texts) { p in
            titleZh(p).map { (en: p.replacingOccurrences(of: "_", with: " "), zh: Optional($0)) }
        }
    }

    /// 需要即时翻译标题的链接目标（像专名、且还没有中文标题的）
    public static func missingTargets(links: [UnitLink], have: (String) -> Bool, limit: Int = 60) -> [UnitLink] {
        var seen = Set<String>()
        var out: [UnitLink] = []
        for l in links where looksProper(l.text) && !have(l.path) && seen.insert(l.path).inserted {
            out.append(l)
            if out.count >= limit { break }
        }
        return out
    }

    static func cleanZh(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[（(][^）)]*[）)]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
    }
}

/// 为一篇文章准备术语表：解析链接目标（跟随重定向）→ 查标题库 → 缺失的专名即时翻译并写回标题库
public enum GlossaryBuilder {
    public static func prepare(
        articlePath: String,
        articleTitle: String,
        links: [UnitLink],
        texts: [String],
        service: ZimService,
        store: TranslationStore?,
        engine: RawTranslator,
        maxNew: Int = 80
    ) async -> (glossary: Glossary, titleZh: String?, newTitles: Int) {
        // 1. 解析链接目标
        var resolved: [String: (path: String, en: String)] = [:]
        var order: [UnitLink] = []
        for l in links where Glossary.looksProper(l.text) {
            if resolved[l.path] == nil, let ref = service.article(path: l.path) {
                resolved[l.path] = (ref.path, ref.title)
            }
            order.append(l)
        }
        // 2. 已有中文标题
        let canon = Array(Set(resolved.values.map(\.path)))
        var zh = store?.titlesZh(for: canon + [articlePath]) ?? [:]
        // 3. 缺失的即时翻译（只翻"锚文本与标题一致"的，按出现顺序）
        var need: [(id: String, text: String)] = []
        var needSet = Set<String>()
        if zh[articlePath] == nil { need.append((id: articlePath, text: articleTitle)); needSet.insert(articlePath) }
        for l in order {
            guard need.count < maxNew, let r = resolved[l.path], zh[r.path] == nil, !needSet.contains(r.path),
                  Glossary.anchorMatches(l.text, title: r.en) else { continue }
            need.append((id: r.path, text: r.en))
            needSet.insert(r.path)
        }
        var newCount = 0
        if !need.isEmpty, let got = try? await engine.translate(need) {
            var rows: [(path: String, en: String, zh: String)] = []
            for n in need { if let z = got[n.id] { zh[n.id] = z; rows.append((path: n.id, en: n.text, zh: z)) } }
            store?.setTitles(rows)
            newCount = rows.count
        }
        let g = Glossary.build(articleTitle: articleTitle, articleTitleZh: zh[articlePath], links: order, texts: texts) { p in
            guard let r = resolved[p] else { return nil }
            return (en: r.en, zh: zh[r.path])
        }
        return (g, zh[articlePath], newCount)
    }
}
