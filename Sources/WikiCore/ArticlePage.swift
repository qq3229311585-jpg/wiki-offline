import Foundation

/// 阅读模式
public enum ReadingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case original      // 原文
    case translated    // 译文
    case bilingual     // 中英对照
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .original: "原文"
        case .translated: "译文"
        case .bilingual: "对照"
        }
    }
    public var needsTranslation: Bool { self != .original }
}

/// 正文字体：宋体（中文宋体 + 英文 New York，默认）/ 混排（中文黑体 + 英文衬线）/ 黑体（全无衬线）
public enum ReadingFont: String, Codable, CaseIterable, Sendable, Identifiable {
    case song
    case mixed
    case hei
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .song: "宋体"
        case .mixed: "混排"
        case .hei: "黑体"
        }
    }
    public var hint: String {
        switch self {
        case .song: "中文宋体 · 英文 New York"
        case .mixed: "中文黑体 · 英文 New York"
        case .hei: "全部无衬线"
        }
    }
    /// 页面上的 data-font 值（宋体是默认样式，不输出属性）
    public var attr: String? { self == .song ? nil : rawValue }
}

/// 版面宽度：窄 / 标准 / 宽 / 满宽（以 em 计，随字号缩放）
public enum ReadingWidth: String, Codable, CaseIterable, Sendable, Identifiable {
    case narrow, standard, wide, full
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .narrow: "窄"
        case .standard: "标准"
        case .wide: "宽"
        case .full: "满宽"
        }
    }
    public var attr: String? { self == .standard ? nil : rawValue }
}

/// 生成页面时需要的阅读偏好（由 App 侧维护，线程安全地快照给 scheme handler）
public struct ReaderStyle: Sendable, Equatable {
    public var mode: ReadingMode
    public var fontScale: Double
    /// 行距倍率（写进 --lhs）
    public var lineHeight: Double
    public var font: ReadingFont
    public var width: ReadingWidth
    /// 对照模式：中英并排（宽窗），而不是上下成对
    public var bilingualSide: Bool
    /// "light" / "dark" / "system"
    public var theme: String

    public init(mode: ReadingMode = .original,
                fontScale: Double = 1.0,
                lineHeight: Double = 1.0,
                font: ReadingFont = .song,
                width: ReadingWidth = .standard,
                bilingualSide: Bool = false,
                theme: String = "system") {
        self.mode = mode
        self.fontScale = fontScale
        self.lineHeight = lineHeight
        self.font = font
        self.width = width
        self.bilingualSide = bilingualSide
        self.theme = theme
    }

    /// 除 lang / data-mode 之外的排版属性
    public var htmlAttributesTail: String {
        var a = ""
        if let f = font.attr { a += " data-font=\"\(f)\"" }
        if let w = width.attr { a += " data-width=\"\(w)\"" }
        if bilingualSide { a += " data-bi=\"side\"" }
        if theme != "system" { a += " data-theme=\"\(theme)\"" }
        a += " style=\"--fs: \(String(format: "%.3f", fontScale)); --lhs: \(String(format: "%.3f", lineHeight))\""
        return a
    }

    public var htmlAttributes: String {
        "lang=\"en\" data-mode=\"\(mode.rawValue)\"" + htmlAttributesTail
    }
}

/// 把清洗后的正文装进 App 自己的页面模板
public enum ArticlePage {

    /// 严格的内容安全策略：只允许内联样式/脚本与 wiki: / data: 资源，任何外网请求都会被浏览器拒绝
    public static let contentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src wiki: data:; font-src data:; media-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"

    public static func build(
        path: String,
        title: String,
        shortDescription: String?,
        body: String,
        style: ReaderStyle,
        cachedTranslations: [String: String],
        css: String,
        js: String
    ) -> String {
        buildWithCache(path: path, title: title, shortDescription: shortDescription, body: body, style: style,
                       cache: cachedTranslations.isEmpty ? [:] : ["t": cachedTranslations], css: css, js: js)
    }

    /// cache: {"t": {键: 译文}, "l": {路径: 中文标题}}
    public static func buildWithCache(
        path: String,
        title: String,
        shortDescription: String?,
        body: String,
        style: ReaderStyle,
        cache: [String: Any],
        css: String,
        js: String
    ) -> String {
        let cacheJSON = jsonObjectForScript(cache)
        let desc = shortDescription.map { "<p id=\"article-desc\" class=\"article-desc\">\(escape($0))</p>" } ?? ""
        return """
        <!DOCTYPE html>
        <html \(style.htmlAttributes)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="wiki-path" content="\(escape(path))">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main id="reader">
        <header class="article-header">
        <div class="kicker">Wikipedia · 维基离线</div>
        <h1 id="article-title">\(escape(title))</h1>
        \(desc)
        <div id="article-meta"></div>
        </header>
        <div id="wiki-body">
        \(body)
        </div>
        <footer class="article-footer">本文来自英文维基百科，依 CC BY-SA 4.0 授权 · 离线阅读</footer>
        </main>
        <script type="application/json" id="wiki-tr-cache">\(cacheJSON)</script>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    /// 找不到条目时的友好页面
    public static func notFound(path: String, css: String, js: String, style: ReaderStyle) -> String {
        let title = path.replacingOccurrences(of: "_", with: " ")
        return """
        <!DOCTYPE html>
        <html lang="zh-Hans" data-mode="original"\(style.htmlAttributesTail)>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="wiki-path" content="\(escape(path))">
        <meta name="wiki-missing" content="1">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main id="reader" class="missing">
        <div class="missing-card">
        <div class="missing-icon">∅</div>
        <h1 class="missing-title">离线包里没有这篇文章</h1>
        <p class="missing-sub">“\(escape(title))” 不在这份离线维基（热门 100 万篇）中。</p>
        <p class="missing-hint">可以按 ⌘K 搜索相近的条目，或按 ⌘[ 返回上一页。</p>
        </div>
        </main>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    public static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(ch)
            }
        }
        return r
    }

    public static func jsonObjectForScript(_ obj: [String: Any]) -> String {
        guard !obj.isEmpty, JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s.replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// 生成可安全嵌入 <script type="application/json"> 的 JSON
    public static func jsonForScript(_ dict: [String: String]) -> String {
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        // "<" 统一转义为 <：既是合法 JSON，又不可能提前闭合 script 标签
        return s.replacingOccurrences(of: "<", with: "\\u003c")
    }
}
