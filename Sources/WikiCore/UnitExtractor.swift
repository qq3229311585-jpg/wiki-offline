import Foundation

// ⚠️ 本文件的分段规则必须与 Resources/reader.js 里的 UNIT_* 常量和 collectUnits() 保持一致：
// 预翻译（无界面，Swift 分段）写入的键，要和阅读时页面脚本算出的键相同，缓存才能命中。

/// 分段规则（与 reader.js 一一对应）
public enum UnitRules {
    /// 可以成为翻译单元的元素
    public static let candidates: Set<String> = ["p", "li", "dd", "dt", "h2", "h3", "h4", "h5", "h6", "td", "th", "caption", "figcaption", "blockquote", "div"]
    /// 遇到这些子元素时，"行内段"结束
    public static let blocks: Set<String> = [
        "p", "div", "ul", "ol", "dl", "table", "blockquote", "pre", "figure", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "details", "summary", "hr", "li", "dd", "dt", "tr", "td", "th", "tbody", "thead", "tfoot",
        "caption", "center", "header", "footer", "nav", "aside", "form", "fieldset", "figcaption", "main", "article", "address",
    ]
    /// 这些标签的整棵子树不翻译
    public static let excludedTags: Set<String> = ["pre", "code", "math", "svg", "style", "script", "kbd", "samp", "textarea"]
    /// 带这些 class 的整棵子树不翻译（参考文献、导航框、公式……）
    public static let excludedClasses: Set<String> = ["navbox", "mwe-math-element", "toc"]
    /// 抽取文字时跳过（不进入译文）的行内元素，例如脚注角标 [1]
    public static let textSkipClasses: Set<String> = ["reference", "mw-ref", "mw-editsection", "mwe-math-element", "sortkey", "mw-cite-backlink"]
    public static let textSkipTags: Set<String> = ["style", "script"]
}

/// 文本规整与哈希（与 reader.js 的 normText / cyrb53 完全一致）
public enum UnitText {
    /// JS 正则 \s 的字符集
    @inline(__always) static func isJSSpace(_ v: UInt32) -> Bool {
        switch v {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// 等价于 JS: s.replace(/\s+/g, ' ').trim()
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            if isJSSpace(u.value) {
                pendingSpace = true
            } else {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(u)
            }
        }
        return String(out)
    }

    /// 至少两个 ASCII 字母才值得翻译
    public static func isTranslatable(_ s: String) -> Bool {
        var n = 0
        for u in s.utf8 where (u >= 65 && u <= 90) || (u >= 97 && u <= 122) {
            n += 1
            if n >= 2 { return true }
        }
        return false
    }

    /// cyrb53（53 位），基于 UTF-16 码元，结果转 36 进制字符串
    public static func key(_ s: String) -> String {
        var h1: UInt32 = 0xdeadbeef
        var h2: UInt32 = 0x41c6ce57
        for ch in s.utf16 {
            let c = UInt32(ch)
            h1 = (h1 ^ c) &* 2654435761
            h2 = (h2 ^ c) &* 1597334677
        }
        h1 = (h1 ^ (h1 >> 16)) &* 2246822507
        h1 ^= (h2 ^ (h2 >> 13)) &* 3266489909
        h2 = (h2 ^ (h2 >> 16)) &* 2246822507
        h2 ^= (h1 ^ (h1 >> 13)) &* 3266489909
        let v = (UInt64(h2 & 2097151) << 32) | UInt64(h1)
        return String(v, radix: 36)
    }
}

/// 极简 HTML 树（只为分段服务）
public final class HNode {
    public enum Kind { case element, text }
    public let kind: Kind
    public let name: String          // 元素名（小写）
    public let classes: [String]
    public let id: String?
    public var href: String?         // 仅 <a>
    public var text: String          // 文本节点内容（已解码实体）
    public var children: [HNode] = []
    weak var parent: HNode?

    init(element name: String, classes: [String], id: String?) {
        kind = .element
        self.name = name
        self.classes = classes
        self.id = id
        text = ""
    }

    init(text: String) {
        kind = .text
        name = "#text"
        classes = []
        id = nil
        self.text = text
    }

    func hasClass(in set: Set<String>) -> Bool { classes.contains { set.contains($0) } }
}

public enum HTMLTree {
    static let rawTextTags: Set<String> = ["script", "style", "textarea", "title"]
    /// 遇到这些开始标签会隐式关闭一个打开的 <p>（HTML 解析规则的常见子集）
    static let pClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre",
        "section", "summary", "table", "ul", "center",
    ]
    static let scopeBoundaries: Set<String> = ["table", "td", "th", "caption", "html", "#root", "button", "marquee", "object"]

    public static func parse(_ html: String) -> HNode {
        let b = Array(html.utf8)
        let root = HNode(element: "#root", classes: [], id: nil)
        var stack: [HNode] = [root]
        var i = 0
        let n = b.count

        func appendText(_ start: Int, _ end: Int) {
            guard end > start else { return }
            let raw = String(decoding: b[start..<end], as: UTF8.self)
            let node = HNode(text: HTMLCleaner.decodeEntities(raw))
            node.parent = stack.last
            stack.last!.children.append(node)
        }

        func popUntil(_ name: String, boundary: Set<String>) {
            // 在边界之前找到 name 才弹出
            var idx = stack.count - 1
            while idx > 0 {
                let nm = stack[idx].name
                if nm == name {
                    stack.removeSubrange(idx...)
                    return
                }
                if boundary.contains(nm) { return }
                idx -= 1
            }
        }

        while i < n {
            if b[i] != UInt8(ascii: "<") {
                var j = i + 1
                while j < n && b[j] != UInt8(ascii: "<") { j += 1 }
                appendText(i, j)
                i = j
                continue
            }
            if HTMLCleaner.matches(b, i, "<!--") {
                if let end = HTMLCleaner.find(b, from: i + 4, "-->") { i = end + 3 } else { i = n }
                continue
            }
            guard let tag = HTMLCleaner.parseTag(b, i) else {
                appendText(i, i + 1)
                i += 1
                continue
            }
            let name = tag.name
            if name.hasPrefix("!") || name.hasPrefix("?") {
                i = tag.end
                continue
            }
            if tag.isClose {
                if stack.contains(where: { $0.name == name }) {
                    if let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 {
                        stack.removeSubrange(idx...)
                    }
                }
                i = tag.end
                continue
            }
            // 隐式关闭
            if pClosers.contains(name) { popUntil("p", boundary: scopeBoundaries) }
            switch name {
            case "li": popUntil("li", boundary: ["ul", "ol", "#root", "table", "td", "th"])
            case "dd", "dt":
                popUntil("dd", boundary: ["dl", "#root", "table", "td", "th"])
                popUntil("dt", boundary: ["dl", "#root", "table", "td", "th"])
            case "td", "th":
                popUntil("td", boundary: ["tr", "table", "#root"])
                popUntil("th", boundary: ["tr", "table", "#root"])
            case "tr":
                popUntil("td", boundary: ["tr", "table", "#root"])
                popUntil("th", boundary: ["tr", "table", "#root"])
                popUntil("tr", boundary: ["table", "#root", "tbody", "thead", "tfoot"])
            default: break
            }
            let attrs = HTMLCleaner.keyAttributes(in: b, tag)
            let classes = (attrs.cls ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" }).map(String.init)
            let el = HNode(element: name, classes: classes, id: attrs.id)
            if name == "a" { el.href = attrs.href }
            el.parent = stack.last
            stack.last!.children.append(el)
            i = tag.end
            if tag.selfClosing && !HTMLCleaner.voidTags.contains(name) && name != "br" {
                // XHTML 风格自闭合（如 <span/>）：浏览器其实不认，但 Parsoid 输出里几乎不会出现
                stack.append(el)
                continue
            }
            if HTMLCleaner.voidTags.contains(name) { continue }
            if rawTextTags.contains(name) {
                // 原始文本：找到对应的关闭标签
                var j = i
                var closeStart = n, closeEnd = n
                while j < n {
                    if b[j] == UInt8(ascii: "<"), j + 1 < n, b[j + 1] == UInt8(ascii: "/"), let t = HTMLCleaner.parseTag(b, j), t.isClose, t.name == name {
                        closeStart = j
                        closeEnd = t.end
                        break
                    }
                    j += 1
                }
                if closeStart > i {
                    let node = HNode(text: String(decoding: b[i..<closeStart], as: UTF8.self))
                    node.parent = el
                    el.children.append(node)
                }
                i = closeEnd
                continue
            }
            stack.append(el)
        }
        return root
    }
}

/// 段落里的一个站内链接（用于专名回填）
public struct UnitLink: Sendable, Hashable, Codable {
    public var text: String
    public var path: String
    public init(text: String, path: String) {
        self.text = text
        self.path = path
    }
}

/// 抽取出的翻译单元
public struct ExtractedUnit: Sendable, Hashable {
    public var key: String
    public var text: String
    public var order: Int
    public var tag: String
    /// 是否属于导语（第一个 h2 之前）
    public var inLead: Bool
    /// 段落内的站内链接
    public var links: [UnitLink] = []
}

public enum UnitExtractor {

    /// 与 reader.js collectUnits() 等价：先标题、简介，再正文
    public static func extract(title: String, shortDescription: String?, bodyHTML: String, articlePath: String = "") -> [ExtractedUnit] {
        let baseDir = articlePath.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        var units: [ExtractedUnit] = []
        var seen = Set<String>()
        var order = 0
        func add(_ raw: String, tag: String, lead: Bool) {
            let t = UnitText.normalize(raw)
            guard UnitText.isTranslatable(t) else { return }
            let k = UnitText.key(t)
            // 页面里可以重复出现同一段原文；顺序编号仍递增（与 JS 一致），但列表里只留第一次
            if seen.insert(k).inserted {
                units.append(ExtractedUnit(key: k, text: t, order: order, tag: tag, inLead: lead))
            }
            order += 1
        }
        add(title, tag: "h1", lead: true)
        if let d = shortDescription { add(d, tag: "p", lead: true) }

        let root = HTMLTree.parse(bodyHTML)
        var inLead = true
        func visit(_ node: HNode) {
            guard node.kind == .element else { return }
            if UnitRules.excludedTags.contains(node.name) || node.hasClass(in: UnitRules.excludedClasses) { return }
            var startChild = 0
            if UnitRules.candidates.contains(node.name) {
                // 行内段：直到第一个块级子元素
                var end = 0
                while end < node.children.count {
                    let c = node.children[end]
                    if c.kind == .element && UnitRules.blocks.contains(c.name) { break }
                    end += 1
                }
                var buf = ""
                for c in node.children[0..<end] { collectText(c, into: &buf) }
                let t = UnitText.normalize(buf)
                if UnitText.isTranslatable(t) {
                    if node.name == "h2" { inLead = false }
                    let k = UnitText.key(t)
                    if seen.insert(k).inserted {
                        var links: [UnitLink] = []
                        for c in node.children[0..<end] { collectLinks(c, baseDir: baseDir, into: &links) }
                        units.append(ExtractedUnit(key: k, text: t, order: order, tag: node.name, inLead: inLead, links: links))
                    }
                    order += 1
                    startChild = end   // 行内段里的东西不再作为候选
                }
            }
            for c in node.children[startChild...] where c.kind == .element { visit(c) }
        }
        for c in root.children { visit(c) }
        return units
    }

    static func collectText(_ node: HNode, into buf: inout String) {
        switch node.kind {
        case .text:
            buf += node.text
        case .element:
            if UnitRules.textSkipTags.contains(node.name) || node.hasClass(in: UnitRules.textSkipClasses) { return }
            if node.name == "br" { buf += " "; return }
            for c in node.children { collectText(c, into: &buf) }
        }
    }

    static func collectLinks(_ node: HNode, baseDir: [String], into links: inout [UnitLink]) {
        guard node.kind == .element else { return }
        if UnitRules.textSkipTags.contains(node.name) || node.hasClass(in: UnitRules.textSkipClasses) { return }
        if node.name == "a", let href = node.href, let p = PopularityRanker.resolve(href: href, baseDir: baseDir) {
            var buf = ""
            collectText(node, into: &buf)
            let t = UnitText.normalize(buf)
            if !t.isEmpty { links.append(UnitLink(text: t, path: p)) }
            return
        }
        for c in node.children { collectLinks(c, baseDir: baseDir, into: &links) }
    }

    /// 给定原始 HTML（来自 ZIM），完整走一遍：清洗 → 分段
    public static func extract(rawHTML: String, fallbackTitle: String, path: String = "") -> (title: String, units: [ExtractedUnit]) {
        let p = HTMLCleaner.process(rawHTML, fallbackTitle: fallbackTitle)
        return (p.title, extract(title: p.title, shortDescription: p.shortDescription, bodyHTML: p.body, articlePath: path))
    }
}
