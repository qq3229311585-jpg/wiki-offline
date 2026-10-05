import Foundation

/// 维基（mwoffliner 生成的 Kiwix ZIM）文章 HTML 的清洗与信息提取。
///
/// 设计：基于 UTF-8 字节的单遍扫描，按"标签名 / class / id"规则成对删除元素（处理同名嵌套），
/// 删除脚本、样式、外链样式表、注释等。结构性的细节整理（目录、翻译单元）交给页面内的 reader.js。
public enum HTMLCleaner {

    // MARK: 规则

    /// 含有这些 class 之一的元素整体删除
    public static let removedClasses: Set<String> = [
        "mw-editsection", "mw-editsection-bracket", "mw-jump-link",
        "navbox", "vertical-navbox", "navbox-styles", "navbox-inner", "navigation-box",
        "ambox", "ombox", "tmbox", "cmbox", "fmbox", "mbox-small", "mbox-small-left",
        "metadata", "noprint", "catlinks", "printfooter", "mw-empty-elt",
        "sistersitebox", "side-box", "portalbox", "portal-bar", "authority-control",
        "mw-hidden-catlinks", "mw-normal-catlinks", "stub", "asbox",
        "shortdescription", "mwe-math-fallback-image-inline", "mwe-math-fallback-image-display",
        "mw-kartographer-maplink", "kiwix-toolbar", "mw-indicators",
    ]

    /// 这些 id 的元素整体删除
    public static let removedIDs: Set<String> = [
        "toc", "siteSub", "contentSub", "contentSub2", "jump-to-nav", "mw-navigation",
        "catlinks", "mw-head", "mw-panel", "footer", "firstHeading", "titleHeading",
        "mw-fr-revisiontag", "coordinates",
    ]

    /// 这些标签整体删除（连同内容）
    static let removedTags: Set<String> = ["script", "style", "noscript", "template", "h1", "iframe", "object", "embed", "video", "audio", "map", "svg"]
    /// 这些标签只删除标签本身（它们没有内容）
    static let droppedVoidTags: Set<String> = ["link", "meta", "base", "img", "source", "track", "input", "area"]
    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param"]

    // MARK: 提取

    /// `<title>` 内容（已解码实体）
    public static func extractTitle(_ html: String) -> String? {
        guard let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = html[r].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let t = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `<body>` 的内部 HTML；没有 body 标签时返回去掉 `<head>` 的整体
    public static func extractBody(_ html: String) -> String {
        if let open = html.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = html[open.upperBound...]
            if let close = rest.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                return String(rest[..<close.lowerBound])
            }
            return String(rest)
        }
        var s = html
        if let head = s.range(of: #"<head\b[\s\S]*?</head>"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(head)
        }
        s = s.replacingOccurrences(of: #"</?(html|!doctype)[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s
    }

    /// 文章的简短描述（Wikidata short description），常在 `div.shortdescription` 里
    public static func extractShortDescription(_ html: String) -> String? {
        guard let r = html.range(of: #"<div[^>]*class="[^"]*\bshortdescription\b[^"]*"[^>]*>([\s\S]*?)</div>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let t = plainText(String(html[r]))
        return t.isEmpty || t.count > 200 ? nil : t
    }

    // MARK: 清洗

    /// 统计热门度时额外排除的区域（参考文献、引用模板、提示条）
    public static let linkNoiseClasses: Set<String> = ["references", "reflist", "refbegin", "mw-references-wrap", "citation", "reference", "hatnote", "dablink", "rellink", "sidebar", "infobox-below", "plainlinks"]

    /// 清洗正文 HTML 片段
    public static func clean(_ html: String, extraRemovedClasses: Set<String> = []) -> String {
        let src = Array(html.utf8)
        var out = [UInt8]()
        out.reserveCapacity(src.count)
        var i = 0
        let n = src.count
        while i < n {
            let c = src[i]
            if c != UInt8(ascii: "<") {
                // 拷贝到下一个 '<'
                var j = i + 1
                while j < n && src[j] != UInt8(ascii: "<") { j += 1 }
                out.append(contentsOf: src[i..<j])
                i = j
                continue
            }
            // 注释
            if matches(src, i, "<!--") {
                if let end = find(src, from: i + 4, "-->") { i = end + 3 } else { i = n }
                continue
            }
            guard let tag = parseTag(src, i) else {
                out.append(c)
                i += 1
                continue
            }
            if tag.isClose || tag.name.isEmpty || tag.name.hasPrefix("!") || tag.name.hasPrefix("?") {
                if !tag.name.hasPrefix("!") && !tag.name.hasPrefix("?") && !droppedVoidTags.contains(tag.name) && !removedTags.contains(tag.name) {
                    out.append(contentsOf: src[i..<tag.end])
                }
                i = tag.end
                continue
            }
            if droppedVoidTags.contains(tag.name) {
                i = tag.end
                continue
            }
            if shouldRemove(tag, src, extra: extraRemovedClasses) {
                i = skipElement(src, tag)
                continue
            }
            out.append(contentsOf: src[i..<tag.end])
            i = tag.end
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 完整处理：原始 HTML → 干净的正文片段 + 标题
    public static func process(_ html: String, fallbackTitle: String) -> (title: String, shortDescription: String?, body: String) {
        let title = extractTitle(html) ?? fallbackTitle
        let desc = extractShortDescription(html)
        let body = clean(extractBody(html))
        return (title, desc, body)
    }

    // MARK: 摘要 / 纯文本

    /// 第一段像样的正文（推荐卡片用）
    public static func summary(_ html: String, maxLength: Int = 280) -> String {
        let body = clean(extractBody(html))
        let ns = body as NSString
        guard let re = try? NSRegularExpression(pattern: #"<p\b[^>]*>([\s\S]*?)</p>"#, options: [.caseInsensitive]) else { return "" }
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)).prefix(40) {
            var inner = ns.substring(with: m.range(at: 1))
            inner = inner.replacingOccurrences(of: #"<sup\b[\s\S]*?</sup>"#, with: "", options: [.regularExpression, .caseInsensitive])
            let text = plainText(inner)
            if text.count >= 60 {
                return truncate(text, to: maxLength)
            }
        }
        return ""
    }

    public static func truncate(_ s: String, to maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        var cut = String(s.prefix(maxLength))
        if let sp = cut.lastIndex(where: { $0 == " " || $0 == "," || $0 == ";" }), cut.distance(from: cut.startIndex, to: sp) > maxLength * 2 / 3 {
            cut = String(cut[..<sp])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// 去标签 + 解码实体 + 合并空白
    public static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)\b[\s\S]*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "minus": "−", "times": "×", "deg": "°", "middot": "·", "bull": "•", "copy": "©", "reg": "®",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä",
        "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "laquo": "«", "raquo": "»", "prime": "′", "Prime": "″", "pound": "£", "euro": "€", "yen": "¥",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "plusmn": "±", "sup2": "²", "sup3": "³", "micro": "µ",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "&", let semi = s[idx...].prefix(12).firstIndex(of: ";") {
                let name = s[s.index(after: idx)..<semi]
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else {
                    rep = namedEntities[String(name)]
                }
                if let rep {
                    out += rep
                    idx = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            idx = s.index(after: idx)
        }
        return out
    }

    // MARK: 扫描器内部

    struct Tag {
        var name: String        // 小写
        var isClose: Bool
        var selfClosing: Bool
        var attrStart: Int
        var attrEnd: Int
        var end: Int            // '>' 之后的位置
    }

    static func matches(_ b: [UInt8], _ i: Int, _ s: StaticString) -> Bool {
        let p = s.utf8Start
        let len = s.utf8CodeUnitCount
        guard i + len <= b.count else { return false }
        for k in 0..<len where b[i + k] != p[k] { return false }
        return true
    }

    static func find(_ b: [UInt8], from: Int, _ s: StaticString) -> Int? {
        let len = s.utf8CodeUnitCount
        guard len > 0, b.count >= len else { return nil }
        var i = from
        let first = s.utf8Start[0]
        while i <= b.count - len {
            if b[i] == first && matches(b, i, s) { return i }
            i += 1
        }
        return nil
    }

    static func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }

    static func isNameChar(_ c: UInt8) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 45 || c == 58 || c == 95
    }

    /// 解析位于 i（指向 '<'）的标签。不是标签返回 nil。
    static func parseTag(_ b: [UInt8], _ i: Int) -> Tag? {
        let n = b.count
        var j = i + 1
        guard j < n else { return nil }
        var isClose = false
        if b[j] == UInt8(ascii: "/") { isClose = true; j += 1 }
        guard j < n else { return nil }
        let first = b[j]
        let isBang = first == UInt8(ascii: "!") || first == UInt8(ascii: "?")
        guard isBang || (lower(first) >= 97 && lower(first) <= 122) else { return nil }
        let nameStart = j
        if isBang { j += 1 }
        while j < n && isNameChar(b[j]) { j += 1 }
        let name = String(decoding: b[nameStart..<j].map(lower), as: UTF8.self)
        let attrStart = j
        // 找 '>'，跳过引号内的内容
        var quote: UInt8 = 0
        while j < n {
            let c = b[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: ">") {
                break
            }
            j += 1
        }
        guard j < n else { return nil }
        let selfClosing = j > attrStart && b[j - 1] == UInt8(ascii: "/")
        return Tag(name: name, isClose: isClose, selfClosing: selfClosing, attrStart: attrStart, attrEnd: j, end: j + 1)
    }

    /// 字节级属性解析：返回 class / id / role / href（只关心这几个）
    static func keyAttributes(in b: [UInt8], _ tag: Tag) -> (cls: String?, id: String?, role: String?, href: String?) {
        var cls: String?, id: String?, role: String?, href: String?
        var i = tag.attrStart
        let end = tag.attrEnd
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        while i < end {
            while i < end && (isSpace(b[i]) || b[i] == UInt8(ascii: "/")) { i += 1 }
            let ns = i
            while i < end && !isSpace(b[i]) && b[i] != UInt8(ascii: "=") && b[i] != UInt8(ascii: "/") { i += 1 }
            let nameBytes = b[ns..<i]
            while i < end && isSpace(b[i]) { i += 1 }
            var value: String?
            if i < end && b[i] == UInt8(ascii: "=") {
                i += 1
                while i < end && isSpace(b[i]) { i += 1 }
                if i < end && (b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'")) {
                    let q = b[i]
                    let vs = i + 1
                    i += 1
                    while i < end && b[i] != q { i += 1 }
                    value = String(decoding: b[vs..<min(i, end)], as: UTF8.self)
                    i += 1
                } else {
                    let vs = i
                    while i < end && !isSpace(b[i]) { i += 1 }
                    value = String(decoding: b[vs..<i], as: UTF8.self)
                }
            }
            if nameBytes.isEmpty { if i == ns { i += 1 }; continue }
            switch nameBytes.count {
            case 5 where nameBytes.elementsEqual("class".utf8, by: { lower($0) == $1 }): cls = value
            case 2 where nameBytes.elementsEqual("id".utf8, by: { lower($0) == $1 }): id = value
            case 4 where nameBytes.elementsEqual("role".utf8, by: { lower($0) == $1 }): role = value
            case 4 where nameBytes.elementsEqual("href".utf8, by: { lower($0) == $1 }): href = value
            default: break
            }
        }
        return (cls, id, role, href)
    }

    static func shouldRemove(_ tag: Tag, _ b: [UInt8], extra: Set<String> = []) -> Bool {
        if removedTags.contains(tag.name) { return true }
        // 快速路径：没有属性就不用解析
        if tag.attrEnd - tag.attrStart < 4 { return false }
        let a = keyAttributes(in: b, tag)
        if let cls = a.cls {
            for token in cls.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                let t = String(token)
                if removedClasses.contains(t) || extra.contains(t) { return true }
            }
        }
        if let id = a.id, removedIDs.contains(id) { return true }
        if (tag.name == "div" || tag.name == "span" || tag.name == "nav"), a.role == "navigation" { return true }
        return false
    }

    /// 跳过整个元素（处理同名嵌套），返回元素结束后的位置
    static func skipElement(_ b: [UInt8], _ open: Tag) -> Int {
        if open.selfClosing || voidTags.contains(open.name) { return open.end }
        // 原始文本元素：直接找对应的关闭标签
        if ["script", "style", "noscript", "template", "svg", "iframe"].contains(open.name) {
            var i = open.end
            while i < b.count {
                if b[i] == UInt8(ascii: "<"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "/"), let t = parseTag(b, i), t.isClose, t.name == open.name {
                    return t.end
                }
                i += 1
            }
            return b.count
        }
        var depth = 1
        var i = open.end
        let n = b.count
        while i < n {
            if b[i] != UInt8(ascii: "<") { i += 1; continue }
            if matches(b, i, "<!--") {
                if let end = find(b, from: i + 4, "-->") { i = end + 3 } else { return n }
                continue
            }
            guard let t = parseTag(b, i) else { i += 1; continue }
            if t.name == open.name {
                if t.isClose {
                    depth -= 1
                    if depth == 0 { return t.end }
                } else if !t.selfClosing {
                    depth += 1
                }
            }
            i = t.end
        }
        return n
    }
}
