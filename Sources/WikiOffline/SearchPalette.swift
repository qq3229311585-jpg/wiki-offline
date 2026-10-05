import SwiftUI
import WikiCore

/// ⌘K 搜索面板
/// · 输入时即时给标题建议（按热门度排序）
/// · 回车把结果摊开：中文标题匹配 + 标题匹配 + 全文相关，由用户自己挑；再回车才打开选中项
/// · 结果里缺中文的标题用本机翻译补上并写回标题库；英文摘要也翻成中文
/// · ⌘↩ 直接看全文搜索
struct SearchPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var rows: [PaletteRow] = []
    @State private var selection = 0
    @State private var fulltextMode = false
    @State private var fulltextTotal = 0
    @State private var busy = false
    @State private var hint: String?
    @State private var task: Task<Void, Never>?
    @State private var fillTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @State private var mouseMoved = false
    /// 已经按回车展开成结果列表（此时回车才是"打开选中项"）
    @State private var resultsShown = false
    /// 每次搜索递增，避免过期的补译文任务写回列表
    @State private var generation = 0

    private let suggestLimit = 20
    private let resultTitleLimit = 60
    private let resultFulltextLimit = 60
    private let snippetTranslateLimit = 8
    private let titleTranslateLimit = 60

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: fulltextMode ? "doc.text.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                TextField(fulltextMode ? "全文搜索英文维基百科…" : "搜索条目（英文或中文）", text: $query)
                    .textFieldStyle(.plain)
                    .font(.custom("Songti SC", size: 22))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.command) { runFulltext(); return .handled }
                        return .ignored
                    }
                if busy { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            if !rows.isEmpty || hint != nil {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if let hint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                if let header = row.header {
                                    Text(header)
                                        .font(Theme.sans(10.5, .semibold))
                                        .kerning(1)
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 12)
                                        .padding(.top, i == 0 ? 6 : 14)
                                        .padding(.bottom, 2)
                                }
                                PaletteRowView(row: row, selected: i == selection)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { activate(i) }
                                    .onContinuousHover { phase in if case .active = phase, mouseMoved { selection = i } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 560)
                    .onChange(of: selection) { _, s in
                        if rows.indices.contains(s) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[s].id, anchor: nil) } }
                    }
                }
            }

            Divider().opacity(0.6)
            HStack(spacing: 14) {
                KeyHint(keys: "↑↓", label: "选择")
                KeyHint(keys: "↩", label: resultsShown || fulltextMode ? "打开选中项" : "列出结果")
                KeyHint(keys: "⌘↩", label: "全文搜索")
                KeyHint(keys: "esc", label: "关闭")
                Spacer()
                Text(trailingInfo).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: 720)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .top) { Rectangle().fill(Theme.accent).frame(height: 3).clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)) }
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.rule))
        .shadow(color: .black.opacity(0.22), radius: 40, y: 18)
        .onAppear {
            focused = true
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { mouseMoved = true }
        }
        .onChange(of: query) { _, _ in
            resultsShown = false
            fulltextMode = false
            refresh()
        }
    }

    private var trailingInfo: String {
        if fulltextMode, fulltextTotal > 0 { return "全文约 \(fulltextTotal.formatted()) 条 · 显示前 \(rows.count)" }
        if resultsShown, fulltextTotal > 0 { return "共 \(rows.count) 条 · 全文约 \(fulltextTotal.formatted()) 条" }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !rows.isEmpty { return "\(rows.count) 条建议" }
        if let n = model.info?.articleCount { return "\(n.formatted()) 个条目 · 离线" }
        return ""
    }

    // MARK: 行为

    /// 回车：第一次回车把结果摊开给用户挑，之后再回车才打开选中项
    private func submit() {
        if resultsShown || fulltextMode { activate(selection); return }
        runResults()
    }

    private func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + d + rows.count) % rows.count
    }

    private func close() {
        task?.cancel()
        fillTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { model.paletteOpen = false }
    }

    private func activate(_ i: Int) {
        guard rows.indices.contains(i) else {
            if !query.isEmpty { runResults() }
            return
        }
        switch rows[i].kind {
        case .article(let ref, _, _): model.open(ref)
        case .recent(let h): model.open(h.path)
        case .fulltext: runFulltext()
        case .searchAll: runResults()
        case .random: model.openRandom()
        case .mainPage: model.openMainPage()
        }
    }

    // MARK: 输入时的建议

    private func refresh() {
        task?.cancel()
        fillTask?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        hint = nil
        fulltextTotal = 0
        if q.isEmpty {
            var r: [PaletteRow] = []
            for (i, h) in model.history.prefix(6).enumerated() {
                r.append(PaletteRow(kind: .recent(h), header: i == 0 ? "最近浏览" : nil))
            }
            r.append(PaletteRow(kind: .random, header: "漫游"))
            r.append(PaletteRow(kind: .mainPage, header: nil))
            rows = r
            selection = 0
            busy = false
            return
        }
        guard let service = model.service else { return }
        let store = model.store
        let cjk = ScriptDetector.containsCJK(q)
        busy = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(cjk ? 200 : 60))
            if Task.isCancelled { return }
            var out: [PaletteRow] = []
            var seen = Set<String>()
            var english: String? = nil
            if cjk {
                let local = await Task.detached(priority: .userInitiated) { store?.searchChineseTitles(q, limit: 10) ?? [] }.value
                if Task.isCancelled { return }
                for (i, t) in local.enumerated() {
                    seen.insert(t.path)
                    out.append(PaletteRow(kind: .article(ArticleRef(path: t.path, title: t.en), zh: t.zh, note: nil),
                                          header: i == 0 ? "中文标题匹配" : nil))
                }
                english = await model.translateQueryToEnglish(q)
                if Task.isCancelled { return }
            }
            let enQuery = english ?? q
            let sugg = await Task.detached(priority: .userInitiated) { service.suggestions(enQuery, limit: suggestLimit) }.value
            if Task.isCancelled { return }
            let ordered = await ranked(sugg, query: enQuery, store: store)
            let zh = await Task.detached(priority: .userInitiated) { store?.titlesZh(for: ordered.map(\.path)) ?? [:] }.value
            if Task.isCancelled { return }
            var first = true
            for s in ordered where seen.insert(s.path).inserted {
                let header = first ? (english != nil ? "标题匹配（已按 “\(english!)” 搜索）" : "标题匹配") : nil
                first = false
                out.append(PaletteRow(kind: .article(s, zh: zh[s.path], note: s.redirectedFrom.map { "由 “\($0)” 重定向" }), header: header))
            }
            out.append(PaletteRow(kind: .searchAll(enQuery), header: nil))
            rows = out
            selection = 0
            busy = false
            self.fillChinese(out, generation: gen, snippets: false)
        }
    }

    // MARK: 回车后的结果列表（条数给足，让用户自己挑）

    private func runResults() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let service = model.service else { return }
        task?.cancel()
        fillTask?.cancel()
        generation += 1
        let gen = generation
        resultsShown = true
        fulltextMode = false
        busy = true
        let store = model.store
        let cjk = ScriptDetector.containsCJK(q)
        task = Task {
            var out: [PaletteRow] = []
            var seen = Set<String>()
            var english: String? = nil
            if cjk {
                let local = await Task.detached(priority: .userInitiated) { store?.searchChineseTitles(q, limit: 14) ?? [] }.value
                if Task.isCancelled { return }
                for (i, t) in local.enumerated() {
                    seen.insert(t.path)
                    out.append(PaletteRow(kind: .article(ArticleRef(path: t.path, title: t.en), zh: t.zh, note: nil),
                                          header: i == 0 ? "中文标题匹配（\(local.count) 条）" : nil))
                }
                english = await model.translateQueryToEnglish(q)
                if Task.isCancelled { return }
            }
            let enQuery = english ?? q

            // 1) 标题匹配
            let sugg = await Task.detached(priority: .userInitiated) { service.suggestions(enQuery, limit: resultTitleLimit) }.value
            if Task.isCancelled { return }
            let ordered = await ranked(sugg, query: enQuery, store: store)
            let zh = await Task.detached(priority: .userInitiated) { store?.titlesZh(for: ordered.map(\.path)) ?? [:] }.value
            if Task.isCancelled { return }
            var first = true
            var picked = 0
            let groupStart = out.count          // 这一组从哪一行开始（不要去动前面"中文标题匹配"那组）
            for s in ordered where seen.insert(s.path).inserted {
                picked += 1
                let header = first ? (english != nil ? "标题匹配（已按 “\(english!)” 搜索）" : "标题匹配") : nil
                first = false
                out.append(PaletteRow(kind: .article(s, zh: zh[s.path], note: s.redirectedFrom.map { "由 “\($0)” 重定向" }), header: header))
            }
            if picked > 0, out.indices.contains(groupStart) {
                out[groupStart].header = (english != nil ? "标题匹配 · 共 \(picked) 条（已按 “\(english!)” 搜索）" : "标题匹配 · 共 \(picked) 条")
            }

            // 2) 全文相关：内容相关的条目也列出来
            if service.info.hasFulltextIndex {
                let r = await Task.detached(priority: .userInitiated) { service.fulltext(enQuery, limit: resultFulltextLimit) }.value
                if Task.isCancelled { return }
                let zh2 = await Task.detached(priority: .userInitiated) { store?.titlesZh(for: r.results.map(\.path)) ?? [:] }.value
                var firstFT = true
                for ref in r.results where seen.insert(ref.path).inserted {
                    out.append(PaletteRow(kind: .article(ref, zh: zh2[ref.path], note: ref.snippet.map { HTMLCleaner.plainText($0) }),
                                          header: firstFT ? "全文相关 · 约 \(r.total.formatted()) 条" : nil))
                    firstFT = false
                }
                fulltextTotal = r.total
                if out.isEmpty { hint = "没有找到 “\(enQuery)”" }
            }

            rows = out
            selection = 0
            busy = false
            self.fillChinese(out, generation: gen, snippets: true)
        }
    }

    /// ⌘↩：只看全文搜索
    private func runFulltext() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let service = model.service else { return }
        task?.cancel()
        fillTask?.cancel()
        generation += 1
        let gen = generation
        fulltextMode = true
        resultsShown = true
        busy = true
        let store = model.store
        task = Task {
            var enQuery = q
            if ScriptDetector.containsCJK(q), let e = await model.translateQueryToEnglish(q) { enQuery = e }
            let r = await Task.detached(priority: .userInitiated) { service.fulltext(enQuery, limit: resultFulltextLimit) }.value
            if Task.isCancelled { return }
            let zh = await Task.detached(priority: .userInitiated) { store?.titlesZh(for: r.results.map(\.path)) ?? [:] }.value
            let out = r.results.enumerated().map { i, ref in
                PaletteRow(kind: .article(ref, zh: zh[ref.path], note: ref.snippet.map { HTMLCleaner.plainText($0) }),
                           header: i == 0 ? "全文搜索 “\(enQuery)” · 约 \(r.total.formatted()) 条" : nil)
            }
            rows = out
            fulltextTotal = r.total
            hint = r.results.isEmpty ? "全文中没有找到 “\(enQuery)”" : nil
            selection = 0
            busy = false
            self.fillChinese(out, generation: gen, snippets: true)
        }
    }

    // MARK: 补中文（标题 + 英文摘要）

    /// 结果里缺中文的：标题翻译后写回标题库，摘要只做一次性翻译；补好后原地更新列表
    private func fillChinese(_ snapshot: [PaletteRow], generation gen: Int, snippets: Bool) {
        var titles: [(path: String, title: String)] = []
        var texts: [(id: String, text: String)] = []
        var seenTitle = Set<String>()
        var seenSnippet = Set<String>()
        for row in snapshot {
            guard case .article(let ref, let zh, let note) = row.kind else { continue }
            if zh == nil, seenTitle.insert(ref.path).inserted { titles.append((path: ref.path, title: ref.title)) }
            if snippets, let note, note.count > 40, !note.hasPrefix("由 “"), seenSnippet.insert(ref.path).inserted {
                texts.append((id: "s:" + ref.path, text: note))
            }
        }
        guard !titles.isEmpty || !texts.isEmpty else { return }
        let titleLimit = titleTranslateLimit
        let captionLimit = snippetTranslateLimit
        fillTask = Task {
            var map: [String: String] = [:]
            if !titles.isEmpty { map.merge(await model.chineseTitles(Array(titles.prefix(titleLimit)))) { a, _ in a } }
            if !texts.isEmpty { map.merge(await model.chineseTexts(Array(texts.prefix(captionLimit)))) { a, _ in a } }
            if Task.isCancelled || map.isEmpty { return }
            await MainActor.run {
                guard gen == self.generation else { return }
                for i in rows.indices {
                    guard case .article(let ref, let zh, let note) = rows[i].kind else { continue }
                    let newZh = zh ?? map[ref.path]
                    var newNote = note
                    if let s = map["s:" + ref.path] { newNote = s }
                    if newZh != zh || newNote != note {
                        rows[i] = PaletteRow(kind: .article(ref, zh: newZh, note: newNote), header: rows[i].header)
                    }
                }
            }
        }
    }

    // MARK: 热门度重排

    /// 建议排序：以 Xapian 的相关度顺序为主。
    /// 只有当最前面的 8 条**都是**查询词的补全（都以查询词开头）时，才按热门度重排这几条
    /// —— 这样 einst 会先出 Einstein（比 Einsteinium 热门），又不会把不相关的条目顶到最前。
    /// 精确标题命中始终钉在最前。
    private func ranked(_ items: [ArticleRef], query: String, store: TranslationStore?) async -> [ArticleRef] {
        guard items.count > 1 else { return items }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var out = items
        if !q.isEmpty, let store {
            let head = Array(items.prefix(8))
            if head.allSatisfy({ $0.title.lowercased().hasPrefix(q) }) {
                let scores = await Task.detached(priority: .userInitiated) { store.rankScores(for: head.map(\.path)) }.value
                if !scores.isEmpty {
                    let sorted = head.sorted { (scores[$0.path] ?? Int.max) < (scores[$1.path] ?? Int.max) }
                    out = sorted + items.dropFirst(head.count)
                }
            }
        }
        if let f = items.first, f.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            out.removeAll { $0.path == f.path }
            out.insert(f, at: 0)
        }
        return out
    }
}

struct PaletteRow: Identifiable {
    enum Kind {
        case article(ArticleRef, zh: String?, note: String?)
        case recent(HistoryItem)
        case fulltext(String)
        case searchAll(String)
        case random
        case mainPage
    }
    var kind: Kind
    var header: String?
    var id: String {
        switch kind {
        case .article(let r, _, _): "a:" + r.path
        case .recent(let h): "h:" + h.path
        case .fulltext(let q): "f:" + q
        case .searchAll(let q): "s:" + q
        case .random: "random"
        case .mainPage: "main"
        }
    }
}

struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(selected ? Theme.accent : Theme.faint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let zh {
                        Text(zh)
                            .font(.custom("Songti SC", size: 15.5).weight(.bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .offset(y: 3)))
                    }
                    Text(title)
                        .font(zh == nil ? .system(size: 15, weight: .semibold, design: .serif) : .system(size: 13, design: .serif).italic())
                        .foregroundStyle(zh == nil ? Theme.ink : Theme.muted)
                        .lineLimit(1)
                }
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .light)).foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, note == nil ? 7 : 8)
        .background(selected ? Theme.accent.opacity(0.08) : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.accent).frame(width: 2) } }
    }

    private var icon: String {
        switch row.kind {
        case .article(let r, _, _): r.redirectedFrom != nil ? "arrow.turn.down.right" : "doc.text"
        case .recent: "clock"
        case .fulltext: "text.magnifyingglass"
        case .searchAll: "list.bullet.rectangle"
        case .random: "dice"
        case .mainPage: "house"
        }
    }

    private var title: String {
        switch row.kind {
        case .article(let r, _, _): r.title
        case .recent(let h): h.title
        case .fulltext(let q): "在全文中搜索 “\(q)”"
        case .searchAll: "查看全部结果"
        case .random: "随机条目"
        case .mainPage: "离线包首页"
        }
    }

    private var zh: String? {
        switch row.kind {
        case .article(_, let zh, _): zh
        case .recent(let h): h.titleZh
        default: nil
        }
    }

    private var note: String? {
        switch row.kind {
        case .article(_, _, let n): n
        default: nil
        }
    }
}

struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.rule))
            Text(label).font(.caption)
        }
        .foregroundStyle(Theme.muted)
    }
}
