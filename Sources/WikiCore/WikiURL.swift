import Foundation

/// App 内部 URL 约定：
///   wiki://content/<ZIM 路径>   —— 文章与 ZIM 资源
///   wiki://app/<名字>           —— App 自带资源（目前未使用，CSS/JS 内联）
public enum WikiURL {
    public static let scheme = "wiki"
    public static let contentHost = "content"

    /// 允许原样出现在路径里的字符：RFC 3986 unreserved + 子分隔符的安全子集 + "/"
    static let allowed: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/!$&'()*+,;=:@")
        return s
    }()

    public static func article(_ path: String) -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return URL(string: "\(scheme)://\(contentHost)/\(encoded)")!
    }

    /// 从 URL 取回 ZIM 路径（解码百分号，去掉开头的 "/"，去掉 fragment/query）
    public static func path(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == contentHost else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var p = comps.percentEncodedPath
        // 维基标题里的 "?" 会被编码成 %3F，正常不会出现 query；万一有，把它并回路径
        if let q = comps.percentEncodedQuery, !q.isEmpty { p += "%3F" + q }
        if p.hasPrefix("/") { p.removeFirst() }
        let decoded = p.removingPercentEncoding ?? p
        return decoded.isEmpty ? nil : decoded
    }

    public static func isInternal(_ url: URL) -> Bool { url.scheme == scheme }

    /// 旧式命名空间路径（A/xxx）在新 ZIM 里也能找到：libzim 自带兼容层，这里只做空白规整
    public static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: " ", with: "_")
    }
}

/// 中日韩文字检测（决定是否先把搜索词译成英文）
public enum ScriptDetector {
    public static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            switch v.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
            default: return false
            }
        }
    }
}
