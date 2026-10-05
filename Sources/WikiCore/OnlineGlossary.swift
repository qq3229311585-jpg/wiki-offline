import Foundation

/// 在线版的专名术语表：链接目标的中文名优先取维基里真人写的译名（语言链接），取不到的再用翻译引擎补。
public enum OnlineGlossaryBuilder {
    public static func prepare(
        articlePath: String,
        articleTitle: String,
        links: [UnitLink],
        texts: [String],
        service: OnlineService,
        store: TranslationStore?,
        engine: RawTranslator?,
        maxNew: Int = 50
    ) async -> (glossary: Glossary, titleZh: String?, newTitles: Int) {
        var resolved: [String: (path: String, en: String)] = [:]
        var order: [UnitLink] = []
        for l in links where Glossary.looksProper(l.text) {
            if resolved[l.path] == nil {
                let p = OnlineService.normalize(l.path)
                resolved[l.path] = (p, OnlineService.displayTitle(p))
            }
            order.append(l)
        }
        let canon = Array(Set(resolved.values.map(\.path)))
        var zh = store?.titlesZh(for: canon + [articlePath]) ?? [:]

        // 需要补的：本条目 + 锚文本与标题一致的链接目标（按出现顺序，最多 maxNew）
        var need: [(path: String, en: String)] = []
        var needSet = Set<String>()
        if zh[articlePath] == nil { need.append((articlePath, articleTitle)); needSet.insert(articlePath) }
        for l in order {
            guard need.count < maxNew, let r = resolved[l.path], zh[r.path] == nil, !needSet.contains(r.path),
                  Glossary.anchorMatches(l.text, title: r.en) else { continue }
            need.append((r.path, r.en))
            needSet.insert(r.path)
        }
        var newCount = 0
        if !need.isEmpty {
            // 1) 维基里的人工译名（一次请求最多 50 个）
            let human = await service.chineseTitles(for: need.map(\.path))
            var rows: [(path: String, en: String, zh: String)] = []
            for n in need { if let z = human[n.path] { zh[n.path] = z; rows.append((path: n.path, en: n.en, zh: z)) } }
            // 2) 没有中文条目的，用翻译引擎补
            let rest = need.filter { zh[$0.path] == nil }
            if !rest.isEmpty, let engine, let got = try? await engine.translate(rest.map { (id: $0.path, text: $0.en) }) {
                for n in rest { if let z = got[n.path] { zh[n.path] = z; rows.append((path: n.path, en: n.en, zh: z)) } }
            }
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
