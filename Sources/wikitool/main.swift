// wikitool —— 可重复的命令行验证工具（不依赖界面）
//
//   wikitool info <zim>
//   wikitool suggest <zim> <query>
//   wikitool search <zim> <query>            全文搜索
//   wikitool article <zim> <path>            清洗 + 分段摘要
//   wikitool units <zim> <path>              打印全部翻译单元
//   wikitool page <zim> <path> <resources>   输出最终页面 HTML
//   wikitool bench-read <zim> <n>            随机读 n 篇，统计读取/清洗/分段耗时
//   wikitool rank <zim> <maxArticles>        热门度排名，打印前 40
//   wikitool bench-translate <zim> <n> [concurrency]   端侧翻译测速（需已安装语言包）
//   wikitool lang-status                     翻译语言包状态
import Foundation
import Translation
import WikiCore

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

func open(_ path: String) -> ZimService {
    if ZimLocator.isDownloading(URL(fileURLWithPath: path)) { fail("ZIM 仍在下载中（存在 .aria2 控制文件），拒绝打开：\(path)") }
    do { return try ZimService(path: path) } catch { fail("打开失败：\(error.localizedDescription)") }
}

func ms(_ t0: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(t0) * 1000) }

@main
struct WikiTool {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fail("用法见源码头部注释") }
        let cmd = args[1]
        switch cmd {
        case "online":
            // wikitool online <suggest|search|zhsearch|article|zh|picks|random> [参数…]   —— 在线版数据层验证（需要网络）
            let svc = OnlineService(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("wikitool-online", isDirectory: true))
            let sub = args.count > 2 ? args[2] : ""
            let q = args.count > 3 ? args[3...].joined(separator: " ") : ""
            let t0 = Date()
            switch sub {
            case "suggest":
                let r = await svc.suggestions(q, limit: 8)
                print("--- \(r.count) 条, \(ms(t0))")
                for x in r { print("  \(x.title)  [\(x.path)]  \(x.snippet ?? "")\(x.redirectedFrom.map { "  ← \($0)" } ?? "")") }
            case "search":
                let r = await svc.fulltext(q, limit: 8)
                print("--- \(r.results.count) / 约 \(r.total) 条, \(ms(t0))")
                for x in r.results { print("  \(x.title)  \(HTMLCleaner.plainText(x.snippet ?? "").prefix(90))") }
            case "zhsearch":
                let r = await svc.zhSearch(q, limit: 12)
                print("--- 中文维基命中 \(r.count) 条(含英文对应条目), \(ms(t0))")
                for x in r { print("  \(x.zhTitle)  →  \(x.enTitle)   \(x.snippet.prefix(50))") }
            case "zh":
                let r = await svc.chineseTitles(for: q.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
                print("--- \(r.count) 个中文标题, \(ms(t0))")
                for (k, v) in r.sorted(by: { $0.key < $1.key }) { print("  \(k)  →  \(v)") }
            case "picks":
                let r = await svc.dailyPicks(count: 7)
                print("--- \(r.count) 条推荐, \(ms(t0))")
                for x in r { print("  \(x.ref.title)  [\(x.ref.path)]  \(x.summary.prefix(70))") }
            case "random":
                for _ in 0..<3 { if let r = await svc.randomArticle() { print("  \(r.title)") } }
            case "article":
                for round in 1...2 {
                    let t = Date()
                    switch await svc.content(path: q) {
                    case .ok(let res):
                        let html = String(decoding: res.data, as: UTF8.self)
                        let p = HTMLCleaner.process(html, fallbackTitle: res.title)
                        let units = UnitExtractor.extract(title: p.title, shortDescription: p.shortDescription, bodyHTML: p.body)
                        let words = units.reduce(0) { $0 + $1.text.split(separator: " ").count }
                        let links = PopularityRanker.links(in: p.body, from: res.path)
                        print("第\(round)次 \(ms(t))  来源: \(res.fromCache ? "磁盘缓存" : "网络")  路径: \(res.path)  重定向: \(res.wasRedirect)")
                        print("   标题: \(p.title)  描述: \(p.shortDescription ?? "-")")
                        print("   原始 \(res.data.count) B → 清洗后 \(p.body.utf8.count) B; 翻译单元 \(units.count) 个, \(words) 词; 站内链接 \(links.count) 个")
                        if round == 1 { for u in units.prefix(4) { print("   [\(u.key)] \(u.text.prefix(100))") } }
                    case .notFound: print("第\(round)次: 找不到条目")
                    case .failed(let m): print("第\(round)次: 失败 \(m)")
                    }
                }
            case "bench":
                // 预热后连续查询，模拟真实使用时的耗时
                let t0 = Date(); await svc.prewarm(); print("预热(两个站点握手): \(ms(t0))")
                for w in ["白纸运动", "百度运动", "线粒体", "苹果", "白纸运动"] {
                    let t = Date(); let r = await svc.zhSearch(w, limit: 8)
                    print("  中文搜索 \(w): \(ms(t))  \(r.count) 条  \(r.first.map { "\($0.zhTitle)→\($0.enTitle) | \($0.snippet.prefix(14))" } ?? "")")
                }
                for w in ["einst", "mitochon", "paper"] {
                    let t = Date(); let r = await svc.suggestions(w, limit: 10); print("  英文联想 \(w): \(ms(t))  \(r.count) 条")
                }
            case "page":
                // wikitool online page <标题> <资源目录> <输出.html>   —— 生成最终页面（浏览器里检查排版用）
                let parts = args.dropFirst(3).map { String($0) }
                guard parts.count >= 3 else { fail("用法: online page <标题> <资源目录> <输出.html>") }
                guard case .ok(let res) = await svc.content(path: parts[0]) else { fail("取不到文章") }
                let dir = URL(fileURLWithPath: parts[1])
                let css = (try? String(contentsOf: dir.appendingPathComponent("reader.css"), encoding: .utf8)) ?? ""
                let js = (try? String(contentsOf: dir.appendingPathComponent("reader.js"), encoding: .utf8)) ?? ""
                let p = HTMLCleaner.process(String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title)
                // 可选：WIKI_DB=<译文库> WIKI_NS=<命名空间前缀，如 ds: / legacy:> WIKI_MODE=<original|translated|bilingual>，让测试页带上真实译文
                let env = ProcessInfo.processInfo.environment
                var cache: [String: Any] = [:]
                if let dbPath = env["WIKI_DB"], let store = try? TranslationStore(url: URL(fileURLWithPath: dbPath)) {
                    let t = store.translations(for: (env["WIKI_NS"] ?? "") + res.path)
                    if !t.isEmpty { cache["t"] = t }
                    let titles = store.titlesZh(for: Array(PopularityRanker.links(in: p.body, from: res.path).prefix(800)))
                    if !titles.isEmpty { cache["l"] = titles }
                    print("译文 \(t.count) 段, 链接中文名 \(titles.count) 个")
                }
                let mode = ReadingMode(rawValue: env["WIKI_MODE"] ?? "original") ?? .original
                var html = ArticlePage.buildWithCache(path: res.path, title: p.title, shortDescription: p.shortDescription, body: p.body,
                                                      style: ReaderStyle(mode: mode), cache: cache, css: css, js: js,
                                                      kicker: "Wikipedia · 维基在线", footer: "测试页")
                // 浏览器里没有 WKWebView 的消息通道，补一个空实现；并放开内容安全策略里的脚本限制不变
                html = html.replacingOccurrences(of: "<head>", with: "<head><script>window.webkit={messageHandlers:{reader:{postMessage:function(m){(window.__msgs=window.__msgs||[]).push(m)}}}};</script>")
                try? html.write(toFile: parts[2], atomically: true, encoding: .utf8)
                print("已写出 \(parts[2])  \(html.utf8.count) B")
            default: print("子命令: suggest | search | zhsearch | zh | picks | random | article | page")
            }

        case "lang-status":
            let a = LanguageAvailability()
            let s1 = await a.status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
            let s2 = await a.status(from: .init(identifier: "zh-Hans"), to: .init(identifier: "en"))
            print("en → zh-Hans: \(s1)\nzh-Hans → en: \(s2)")

        case "info":
            let t0 = Date()
            let z = open(args[2])
            let i = z.info
            print("opened in \(ms(t0))")
            print("title: \(i.title)\ndesc: \(i.description)\nlang: \(i.language)\ndate: \(i.date)\narticles: \(i.articleCount)\nsize: \(i.fileSize)\nfulltext: \(i.hasFulltextIndex)\ntitleIndex: \(i.hasTitleIndex)\nuuid: \(i.uuid)\nnewNamespace: \(z.archive.hasNewNamespaceScheme)")
            print("main: \(z.mainArticle().map { "\($0.path) | \($0.title)" } ?? "-")")
            print("metadata keys: \(z.archive.metadataKeys().joined(separator: ", "))")
            for _ in 0..<3 { print("random: \(z.randomArticle()?.title ?? "-")") }

        case "suggest":
            let z = open(args[2])
            let q = args[3...].joined(separator: " ")
            for _ in 0..<2 {   // 第二次是热缓存
                let t0 = Date()
                let r = z.suggestions(q, limit: 10)
                print("--- \(r.count) results in \(ms(t0))")
                for x in r { print("  \(x.title)  [\(x.path)]\(x.redirectedFrom.map { "  ← \($0)" } ?? "")") }
            }

        case "search":
            let z = open(args[2])
            let q = args[3...].joined(separator: " ")
            let t0 = Date()
            let r = z.fulltext(q, limit: 10)
            print("--- \(r.results.count) / ~\(r.total) results in \(ms(t0))")
            for x in r.results { print("  \(x.title)  [\(x.path)]  \(HTMLCleaner.plainText(x.snippet ?? "").prefix(100))") }

        case "article", "units":
            let z = open(args[2])
            let path = args[3]
            let t0 = Date()
            guard let res = z.content(path: path) else { fail("找不到：\(path)") }
            let tRead = ms(t0)
            let html = String(decoding: res.data, as: UTF8.self)
            let t1 = Date()
            let p = HTMLCleaner.process(html, fallbackTitle: res.title)
            let tClean = ms(t1)
            let t2 = Date()
            let units = UnitExtractor.extract(title: p.title, shortDescription: p.shortDescription, bodyHTML: p.body)
            let tUnits = ms(t2)
            print("path: \(res.path) (redirect: \(res.wasRedirect))  mime: \(res.mimeType)")
            print("title: \(p.title)  desc: \(p.shortDescription ?? "-")")
            print("raw \(res.data.count) B → clean \(p.body.utf8.count) B; read \(tRead), clean \(tClean), units \(tUnits)")
            let chars = units.reduce(0) { $0 + $1.text.count }
            let words = units.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let lead = units.filter(\.inLead)
            print("units: \(units.count), chars: \(chars), words: \(words); lead units: \(lead.count), lead words: \(lead.reduce(0) { $0 + $1.text.split(separator: " ").count })")
            let show = cmd == "units" ? units : Array(units.prefix(12))
            for u in show { print("  [\(u.key)] <\(u.tag)>\(u.inLead ? "*" : " ") \(u.text.prefix(cmd == "units" ? 400 : 110))") }
            print("summary: \(HTMLCleaner.summary(html, maxLength: 200))")

        case "page":
            let z = open(args[2])
            guard let res = z.content(path: args[3]) else { fail("找不到") }
            let dir = URL(fileURLWithPath: args[4])
            let css = (try? String(contentsOf: dir.appendingPathComponent("reader.css"), encoding: .utf8)) ?? ""
            let js = (try? String(contentsOf: dir.appendingPathComponent("reader.js"), encoding: .utf8)) ?? ""
            let p = HTMLCleaner.process(String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title)
            print(ArticlePage.build(path: res.path, title: p.title, shortDescription: p.shortDescription, body: p.body, style: ReaderStyle(), cachedTranslations: [:], css: css, js: js))

        case "illustration":
            // wikitool illustration <zim> <outFile> [maxSize]
            let z = open(args[2])
            let out = URL(fileURLWithPath: args[3])
            let maxSize = Int(args.count > 4 ? args[4] : "1024") ?? 1024
            var best: (Int, Data)?
            for s in [1024, 512, 256, 192, 128, 96, 64, 48] where s <= maxSize {
                if let d = z.archive.illustrationPNG(withSize: UInt32(s)), !d.isEmpty { best = (s, d); break }
            }
            guard let b = best else { fail("这个 ZIM 没有插图（Illustration_*）") }
            try? b.1.write(to: out)
            print("插图 \(b.0)×\(b.0) → \(out.path)（\(b.1.count) 字节）")

        case "searchcheck":
            // 复刻搜索面板的完整链路：中文标题库 → 反向翻译 → 标题建议（按热门度）→ 全文相关
            let z = open(args[2])
            let q = args[3...].joined(separator: " ")
            let store = try? TranslationStore(url: TranslationStore.defaultURL(forArchiveUUID: z.info.uuid))
            var enQuery = q
            if ScriptDetector.containsCJK(q) {
                let local = store?.searchChineseTitles(q, limit: 14) ?? []
                print("中文标题匹配：\(local.count) 条")
                for t in local.prefix(5) { print("   \(t.zh)  ←  \(t.en)") }
                let tr = AppleTranslator(source: TranslationLanguages.chinese, target: TranslationLanguages.english)
                if let e = try? await tr.translate(q) { enQuery = e }
                print("查询译成英文：\(q) → \(enQuery)")
            }
            var sorted = z.suggestions(enQuery, limit: 60)
            let scores = store?.rankScores(for: sorted.map(\.path)) ?? [:]
            let head = Array(sorted.prefix(8))
            if !head.isEmpty, head.allSatisfy({ $0.title.lowercased().hasPrefix(enQuery.lowercased()) }), !scores.isEmpty {
                sorted = head.sorted { (scores[$0.path] ?? Int.max) < (scores[$1.path] ?? Int.max) } + sorted.dropFirst(head.count)
            }
            let titles = store?.titlesZh(for: sorted.map(\.path)) ?? [:]
            print("标题建议：\(sorted.count) 条（请求 60），其中已有中文标题 \(titles.count) 条")
            for (i, s) in sorted.prefix(12).enumerated() {
                print("  \(i + 1). \(titles[s.path] ?? "（无中文）")  /  \(s.title)   热门名次 \(scores[s.path].map(String.init) ?? "-")")
            }
            let ft = z.fulltext(enQuery, limit: 60)
            let ftTitles = store?.titlesZh(for: ft.results.map(\.path)) ?? [:]
            print("全文相关：显示 \(ft.results.count) 条，库内总数约 \(ft.total)，其中已有中文标题 \(ftTitles.count) 条")
            for (i, s) in ft.results.prefix(8).enumerated() { print("  \(i + 1). \(ftTitles[s.path] ?? "（无中文）")  /  \(s.title)") }

        case "linkcheck":
            // 统计：已缓存译文里，有多少链接目标的中文标题真的能在译文里匹配上
            let z = open(args[2])
            guard let res = z.content(path: args[3]) else { fail("找不到：\(args[3])") }
            let x = UnitExtractor.extract(rawHTML: String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title, path: res.path)
            guard let store = try? TranslationStore(url: TranslationStore.defaultURL(forArchiveUUID: z.info.uuid)) else { fail("打不开译文库") }
            let cached = store.translations(for: res.path)
            let allLinks = x.units.flatMap(\.links)
            let paths = Array(Set(allLinks.map(\.path)))
            let titles = store.titlesZh(for: paths)
            var canon: [String: String] = [:]
            for p in paths { if let r = z.article(path: p) { canon[p] = r.path } }
            let canonTitles = store.titlesZh(for: Array(Set(canon.values)))
            print("units \(x.units.count)，含链接的 unit \(x.units.filter { !$0.links.isEmpty }.count)，链接 \(allLinks.count)，不同目标 \(paths.count)")
            print("标题库命中：原始路径 \(titles.count)，规范路径 \(canonTitles.count)")
            var hitZh = 0, hitEn = 0, miss = 0, checked = 0
            for u in x.units where !u.links.isEmpty {
                guard let zh = cached[u.key] else { continue }
                checked += 1
                for l in u.links {
                    let t = titles[l.path] ?? canon[l.path].flatMap { canonTitles[$0] }
                    if let t, zh.contains(t) { hitZh += 1 }
                    else if l.text.count >= 3, zh.contains(l.text) { hitEn += 1 }
                    else { miss += 1 }
                }
            }
            print("已缓存译文的段落 \(checked) 个：中文标题命中 \(hitZh)，英文原名命中 \(hitEn)，都不命中 \(miss)")
            var shown = 0
            for u in x.units where !u.links.isEmpty && cached[u.key] != nil {
                let zh = cached[u.key]!
                print("\nEN: \(u.text.prefix(80))")
                print("ZH: \(zh.prefix(80))")
                for l in u.links.prefix(6) {
                    let t = titles[l.path] ?? canon[l.path].flatMap { canonTitles[$0] }
                    let mark = (t.map { zh.contains($0) } ?? false) ? "✓中文" : (zh.contains(l.text) ? "✓英文" : "✗")
                    print("   \(mark) 「\(l.text)」 → \(t ?? "-")  [\(l.path)]")
                }
                shown += 1
                if shown >= 6 { break }
            }

        case "bench-read":
            let z = open(args[2])
            let n = Int(args[3]) ?? 200
            var tRead = 0.0, tClean = 0.0, tUnits = 0.0, bytes = 0, units = 0, words = 0, leadWords = 0
            for _ in 0..<n {
                guard let r = z.randomArticle() else { continue }
                var t = Date()
                guard let res = z.content(path: r.path) else { continue }
                tRead += Date().timeIntervalSince(t)
                bytes += res.data.count
                t = Date()
                let p = HTMLCleaner.process(String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title)
                tClean += Date().timeIntervalSince(t)
                t = Date()
                let u = UnitExtractor.extract(title: p.title, shortDescription: p.shortDescription, bodyHTML: p.body)
                tUnits += Date().timeIntervalSince(t)
                units += u.count
                words += u.reduce(0) { $0 + $1.text.split(separator: " ").count }
                leadWords += u.filter(\.inLead).reduce(0) { $0 + $1.text.split(separator: " ").count }
            }
            let f = { (x: Double) in String(format: "%.2f ms", x * 1000 / Double(n)) }
            print("n=\(n) avg raw \(bytes / max(n, 1)) B; read \(f(tRead)), clean \(f(tClean)), units \(f(tUnits)); avg units \(units / max(n, 1)), avg words \(words / max(n, 1)), avg lead words \(leadWords / max(n, 1))")

        case "rank":
            let z = open(args[2])
            let maxN = Int(args.count > 3 ? args[3] : "1000") ?? 1000
            let t0 = Date()
            let r = PopularityRanker.rank(service: z, maxArticles: maxN, keepTop: 60000) { read, disc in
                if read % 500 == 0 { print("  read \(read), discovered \(disc), \(ms(t0))") }
            }
            print("ranked \(r.count) in \(ms(t0))")
            for (i, e) in r.prefix(40).enumerated() { print(String(format: "%3d %6d  %@", i + 1, e.score, e.title)) }

        case "bench-translate":
            await benchTranslate(args)

        case "nametest":
            // 专名处理实测：同一段落，直接翻 vs 术语表预替换后再翻
            let z = open(args[2])
            let n = Int(args.count > 4 ? args[4] : "6") ?? 6
            guard let res = z.content(path: args[3]) else { fail("找不到") }
            let x = UnitExtractor.extract(rawHTML: String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title, path: res.path)
            let engine = AppleTranslator()
            let links = x.units.flatMap(\.links)
            let need = Glossary.missingTargets(links: links, have: { _ in false }, limit: 200)
            var targets: [String: String] = [:]
            for l in need { if let ref = z.article(path: l.path) { targets[l.path] = ref.title } }
            let t0 = Date()
            let titleMap = (try? await engine.translate(targets.map { (id: $0.key, text: $0.value) } + [(id: "__self__", text: x.title)])) ?? [:]
            print("translated \(titleMap.count) titles in \(ms(t0))")
            let g = Glossary.build(articleTitle: x.title, articleTitleZh: titleMap["__self__"], links: links, texts: x.units.map(\.text)) { p in targets[p].map { (en: $0, zh: titleMap[p]) } }
            print("glossary \(g.terms.count) terms; self: \(x.title) → \(titleMap["__self__"] ?? "-"); short: \(Glossary.shortForm(title: x.title, texts: x.units.map(\.text)) ?? "-")")
            print("sample terms: " + g.terms.prefix(12).map { "\($0.en)→\($0.zh)" }.joined(separator: ", "))
            var shown = 0
            for u in x.units where u.tag == "p" && u.text.count > 80 {
                let sub = g.apply(u.text)  // 只用于挑选含专名的段落
                guard sub != u.text else { continue }
                let inp = [PipelineInput(key: "k", text: u.text, links: u.links)]
                let plain = (try? await TranslationPipeline.translate(inp, with: engine))?.translations["k"] ?? "-"
                let pre = (try? await TranslationPipeline.translate(inp, with: engine, glossary: g))?.translations["k"] ?? "-"
                print("\n— EN:  \(u.text.prefix(300))\n  直译: \(plain.prefix(240))\n  术语表: \(pre.prefix(240))")
                shown += 1
                if shown >= n { break }
            }

        default:
            fail("未知命令 \(cmd)")
        }
    }

    /// 端侧翻译测速：取 n 篇随机文章的导语段，分别测串行与并发
    static func benchTranslate(_ args: [String]) async {
        let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans")
        let status = await LanguageAvailability().status(from: en, to: zh)
        guard status == .installed else { fail("语言包状态：\(status)，未安装，无法测速") }
        let z = open(args[2])
        let n = Int(args.count > 3 ? args[3] : "20") ?? 20
        let conc = Int(args.count > 4 ? args[4] : "1") ?? 1
        var batches: [[ExtractedUnit]] = []
        for _ in 0..<n {
            guard let r = z.randomArticle(), let res = z.content(path: r.path) else { continue }
            let x = UnitExtractor.extract(rawHTML: String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title)
            batches.append(Array(x.units.filter(\.inLead).prefix(20)))
        }
        let totalWords = batches.flatMap { $0 }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let totalChars = batches.flatMap { $0 }.reduce(0) { $0 + $1.text.count }
        print("articles \(batches.count), units \(batches.flatMap { $0 }.count), words \(totalWords), chars \(totalChars), concurrency \(conc)")
        let t0 = Date()
        var failures = 0
        await withTaskGroup(of: Int.self) { group in
            var it = batches.makeIterator()
            func addNext() -> Bool {
                guard let b = it.next() else { return false }
                group.addTask {
                    let session = TranslationSession(installedSource: en, target: zh)
                    do {
                        let reqs = b.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.key) }
                        _ = try await session.translations(from: reqs)
                        return 0
                    } catch {
                        print("  error: \(error)")
                        return 1
                    }
                }
                return true
            }
            for _ in 0..<conc { _ = addNext() }
            for await r in group {
                failures += r
                _ = addNext()
            }
        }
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "elapsed %.1f s → %.0f words/s, %.0f chars/s; failures %d", dt, Double(totalWords) / dt, Double(totalChars) / dt, failures))
        // 抽样展示
        if let first = batches.first?.prefix(2) {
            let session = TranslationSession(installedSource: en, target: zh)
            for u in first {
                if let r = try? await session.translate(u.text) { print("  EN: \(u.text.prefix(120))\n  ZH: \(r.targetText.prefix(120))") }
            }
        }
    }
}
