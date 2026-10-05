import Foundation
import NaturalLanguage
import Translation

/// 底层翻译引擎抽象：给一批 (id, 原文)，返回 id → 译文
public protocol RawTranslator: AnyObject, Sendable {
    func translate(_ items: [(id: String, text: String)]) async throws -> [String: String]
}

public enum TranslationLanguages {
    public static let english = Locale.Language(identifier: "en")
    public static let chinese = Locale.Language(identifier: "zh-Hans")

    public static func status() async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: english, to: chinese)
    }

    public static func reverseStatus() async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: chinese, to: english)
    }
}

/// Apple 端侧翻译（Translation framework）。只在语言包已安装时创建；纯本机，不联网。
public final class AppleTranslator: RawTranslator, @unchecked Sendable {
    private let session: TranslationSession

    public init(source: Locale.Language = TranslationLanguages.english, target: Locale.Language = TranslationLanguages.chinese) {
        session = TranslationSession(installedSource: source, target: target)
    }

    public func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }
        let reqs = items.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        let responses = try await session.translations(from: reqs)
        var out: [String: String] = [:]
        for r in responses {
            if let id = r.clientIdentifier { out[id] = r.targetText }
        }
        return out
    }

    /// 单句翻译（中文搜索把查询译成英文）
    public func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}

/// 测试 / 冒烟用的伪翻译器（不写入真实缓存）
public final class FakeTranslator: RawTranslator, @unchecked Sendable {
    public let delay: Duration
    public init(delay: Duration = .milliseconds(30)) { self.delay = delay }
    public func translate(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        try await Task.sleep(for: delay * items.count)
        var out: [String: String] = [:]
        for it in items { out[it.id] = "〔译〕" + it.text }
        return out
    }
}

/// 一个待翻译单元（带链接信息，用于专名回填）
public struct PipelineInput: Sendable {
    public var key: String
    public var text: String
    public var links: [UnitLink]
    public init(key: String, text: String, links: [UnitLink] = []) {
        self.key = key
        self.text = text
        self.links = links
    }
}

/// 质量管线：长段切句 → 批量翻译 → 合并 → 专名回填
public enum TranslationPipeline {
    /// 超过这么多词的单元按句切分后再翻
    public static var longUnitWords = 60

    public static func wordCount(_ s: String) -> Int {
        var n = 0, inWord = false
        for u in s.unicodeScalars {
            let isSpace = u == " " || u == "\n" || u == "\t"
            if !isSpace && !inWord { n += 1 }
            inWord = !isSpace
        }
        return n
    }

    /// 按句切分（NLTokenizer）；短文本原样返回
    public static func pieces(_ text: String) -> [String] {
        guard wordCount(text) > longUnitWords else { return [text] }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        // 过短的碎片并回前一句（例如 "c." "U.S." 之类缩写误切）
        var merged: [String] = []
        for s in out {
            if let last = merged.last, wordCount(s) <= 2 || wordCount(last) <= 2 {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged.isEmpty ? [text] : merged
    }

    /// 把中文片段接起来：两边都是拉丁字母/数字时补空格
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts {
            if let a = out.unicodeScalars.last, let b = p.unicodeScalars.first,
               a.isASCII && (CharacterSet.alphanumerics.contains(a) || a == "." || a == ",") && b.isASCII && CharacterSet.alphanumerics.contains(b) {
                out += " "
            }
            out += p
        }
        return out
    }

    /// 专名回填：译文里原样残留的英文链接文字，如果有已知中文标题，就替换成"中文（English）"
    public static func backfill(_ translation: String, links: [UnitLink], titleZh: (String) -> String?) -> String {
        guard !links.isEmpty else { return translation }
        var out = translation
        var done = Set<String>()
        for l in links where l.text.count >= 3 && !done.contains(l.text) {
            guard out.contains(l.text), let zhRaw = titleZh(l.path) else { continue }
            let zh = zhRaw.replacingOccurrences(of: #"\s*[（(][^）)]*[）)]\s*$"#, with: "", options: .regularExpression)
            guard ScriptDetector.containsCJK(zh), !out.contains(zh) else { continue }
            // 避免替换已经是"（English）"形式的括注
            if out.contains("（\(l.text)）") || out.contains("(\(l.text))") { continue }
            if let r = out.range(of: l.text) {
                out.replaceSubrange(r, with: "\(zh)（\(l.text)）")
                done.insert(l.text)
            }
        }
        return out
    }

    public struct Result: Sendable {
        public var translations: [String: String]
        public var failedKeys: [String]
        public var words: Int
        public var chars: Int
    }

    /// 翻译一组单元。单个片段失败不会拖垮整批：整批失败时逐个重试，仍失败的记入 failedKeys。
    public static func translate(
        _ inputs: [PipelineInput],
        with engine: RawTranslator,
        glossary: Glossary? = nil,
        titleZh: (String) -> String? = { _ in nil }
    ) async throws -> Result {
        var items: [(id: String, text: String)] = []
        var partsOf: [String: Int] = [:]
        for inp in inputs {
            let ps = pieces(inp.text)
            partsOf[inp.key] = ps.count
            // 专名预替换：按句进行（整段替换后送翻偶尔会诱发幻觉）
            for (i, p) in ps.enumerated() { items.append((id: "\(inp.key)#\(i)", text: glossary?.preApply(p) ?? p)) }
        }
        var got: [String: String] = [:]
        do {
            got = try await engine.translate(items)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 逐个重试，隔离出坏输入
            for it in items {
                try Task.checkCancellation()
                if let r = try? await engine.translate([it]) { got.merge(r) { a, _ in a } }
            }
            if got.isEmpty { throw error }
        }
        var out: [String: String] = [:]
        var failed: [String] = []
        var words = 0, chars = 0
        for inp in inputs {
            let n = partsOf[inp.key] ?? 1
            var parts: [String] = []
            for i in 0..<n {
                if let t = got["\(inp.key)#\(i)"] { parts.append(t) } else { parts.removeAll(); break }
            }
            if parts.count == n {
                var t = join(parts)
                if let glossary { t = glossary.postFix(t) }
                // 端侧模型在中英混排输入下偶尔输出繁体字，统一转简体
                t = t.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? t
                out[inp.key] = backfill(t, links: inp.links, titleZh: titleZh)
                words += wordCount(inp.text)
                chars += inp.text.count
            } else {
                failed.append(inp.key)
            }
        }
        return Result(translations: out, failedKeys: failed, words: words, chars: chars)
    }
}
