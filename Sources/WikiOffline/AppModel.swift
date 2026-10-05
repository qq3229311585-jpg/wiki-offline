import AppKit
import Observation
import SwiftUI
import Translation
import WikiCore

struct TOCItem: Identifiable, Hashable {
    var id: String
    var level: Int
    var text: String
    var key: String?
}

/// 一个"看过的界面"快照（浏览历史用）
struct ViewSnapshot: Equatable {
    var destination: Destination
    var path: String?
    var fraction: Double
}

struct CurrentArticle: Equatable {
    var path: String
    var title: String
    var titleZh: String?
    var missing = false
}

enum Destination: Hashable {
    case home, reader, history, favorites
}

enum PackStatus: Equatable {
    case checking, installed, notInstalled, unsupported
    var label: String {
        switch self {
        case .checking: "正在检查翻译语言包…"
        case .installed: "翻译语言包已就绪"
        case .notInstalled: "翻译语言包未下载"
        case .unsupported: "此设备不支持英译中"
        }
    }
}

enum LibraryState: Equatable {
    case locating
    case downloading(bytes: Int64)
    case missing
    case failed(String)
    case ready
}

/// 全局状态
@MainActor
@Observable
final class AppModel {
    // MARK: 资料库
    var library: LibraryState = .locating
    var info: ZimInfo?
    @ObservationIgnored var service: ZimService?
    @ObservationIgnored var store: TranslationStore?
    @ObservationIgnored let styleBox = StyleBox()

    // MARK: 导航
    var destination: Destination = .home
    var current: CurrentArticle?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var toc: [TOCItem] = []
    var activeSection: String?
    /// 当前一级章节序号（0 起，-1 表示还在导语）与一级章节总数
    var sectionIndex = -1
    var sectionTotal = 0
    /// 阅读进度 0…1（滚动位置）
    var readFraction: Double = 0
    var tocTranslations: [String: String] = [:]
    var paletteOpen = false
    /// Aa 排版面板是否打开（菜单与顶栏按钮共用）
    var typePanelOpen = false
    var toast: String?

    // MARK: 偏好（持久化）
    var defaultMode: ReadingMode {
        didSet { UserDefaults.standard.set(defaultMode.rawValue, forKey: "defaultMode") }
    }
    /// 当前文章的临时模式（打开新文章时回到默认）
    var mode: ReadingMode = .translated {
        didSet { applyMode() }
    }
    var fontScale: Double {
        didSet {
            UserDefaults.standard.set(fontScale, forKey: "fontScale")
            syncStyle()
            reader.call("setFontScale", fontScale)
        }
    }
    /// 行距倍率（--lhs）
    var lineHeight: Double {
        didSet {
            UserDefaults.standard.set(lineHeight, forKey: "lineHeight")
            syncStyle()
            reader.call("setLineHeight", lineHeight)
        }
    }
    /// 正文字体（宋体 / 混排 / 黑体）
    var font: ReadingFont {
        didSet {
            UserDefaults.standard.set(font.rawValue, forKey: "font")
            syncStyle()
            reader.call("setFont", font.rawValue)
        }
    }
    /// 版面宽度（窄 / 标准 / 宽 / 满宽）
    var pageWidth: ReadingWidth {
        didSet {
            UserDefaults.standard.set(pageWidth.rawValue, forKey: "pageWidth")
            syncStyle()
            reader.call("setWidth", pageWidth.rawValue)
        }
    }
    /// 对照模式并排
    var bilingualSide: Bool {
        didSet {
            UserDefaults.standard.set(bilingualSide, forKey: "bilingualSide")
            syncStyle()
            reader.call("setBilingualSide", bilingualSide)
        }
    }
    /// 章节导航是否固定显示（默认隐藏）
    var showOutline = false
    var showBookshelf = false
    /// 外观："system" / "light" / "dark"
    var theme: String {
        didSet {
            UserDefaults.standard.set(theme, forKey: "theme")
            applyTheme()
        }
    }

    // MARK: 翻译
    var pack: PackStatus = .checking
    var reversePackInstalled = false
    var translating = false
    var translatedCount = 0
    var translatableCount = 0
    var translationNotice: String?
    var downloadRequest: TranslationSession.Configuration?

    // MARK: 历史与收藏
    var history: [HistoryItem] = []
    var favorites: [FavoriteItem] = []
    var dailyPicks: [DailyPick] = []

    @ObservationIgnored let reader = ReaderController()
    @ObservationIgnored private var planner = TranslationPlanner()
    @ObservationIgnored private var translator: AppleTranslator?
    @ObservationIgnored private var reverseTranslator: AppleTranslator?
    @ObservationIgnored private var translateTask: Task<Void, Never>?
    @ObservationIgnored private var pageLinks: [String: [UnitLink]] = [:]
    @ObservationIgnored private var glossary: Glossary?
    @ObservationIgnored private var glossaryReady = true
    @ObservationIgnored private var titleKey: String?
    @ObservationIgnored private var pageToken = 0
    @ObservationIgnored private var restoreFraction: Double?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var historyFile = JSONFile<[HistoryItem]>(AppPaths.supportDirectory.appendingPathComponent("history.json"))
    @ObservationIgnored private var favoritesFile = JSONFile<[FavoriteItem]>(AppPaths.supportDirectory.appendingPathComponent("favorites.json"))
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var lastLinkRefresh = Date.distantPast
    /// 浏览历史：像浏览器一样记录"看过哪个界面"，返回/前进都走这个栈
    @ObservationIgnored private var backStack: [ViewSnapshot] = []
    @ObservationIgnored private var forwardStack: [ViewSnapshot] = []
    @ObservationIgnored private var currentView = ViewSnapshot(destination: .home, path: nil, fraction: 0)
    /// 调试：用伪翻译器联调界面（环境变量 WIKI_FAKE_TRANSLATOR=1），不写入真实缓存
    @ObservationIgnored let fakeTranslation = ProcessInfo.processInfo.environment["WIKI_FAKE_TRANSLATOR"] == "1"

    init() {
        let d = UserDefaults.standard
        defaultMode = ReadingMode(rawValue: d.string(forKey: "defaultMode") ?? "") ?? .translated
        fontScale = d.object(forKey: "fontScale") as? Double ?? 1.0
        lineHeight = d.object(forKey: "lineHeight") as? Double ?? 1.0
        // 旧版只有一个"衬线字体"开关，这里做一次迁移
        if let raw = d.string(forKey: "font"), let f = ReadingFont(rawValue: raw) {
            font = f
        } else {
            font = (d.object(forKey: "serif") as? Bool == false) ? .hei : .song
        }
        pageWidth = ReadingWidth(rawValue: d.string(forKey: "pageWidth") ?? "") ?? .standard
        bilingualSide = d.object(forKey: "bilingualSide") as? Bool ?? false
        theme = d.string(forKey: "theme") ?? "system"
        mode = defaultMode
        history = historyFile.load() ?? []
        favorites = favoritesFile.load() ?? []
        syncStyle()
        applyTheme()
        wireReader()
        Task { await refreshPackStatus() }
        openLibrary()
    }

    // MARK: - 资料库

    func openLibrary() {
        let preferred = UserDefaults.standard.string(forKey: "zimPath")
        switch ZimLocator.locate(preferred: preferred) {
        case .ready(let url):
            do {
                ZimArchive.setClusterCacheMaxSize(160 << 20)
                let s = try ZimService(path: url.path)
                s.archive.setDirentCacheMaxSize(4096)
                service = s
                info = s.info
                store = try? TranslationStore(url: TranslationStore.defaultURL(forArchiveUUID: s.info.uuid))
                reader.scheme.source = ContentSource(service: s, store: fakeTranslation ? nil : store, style: styleBox)
                library = .ready
                pollTimer?.invalidate()
                loadDailyPicks()
                restoreLastArticle()
            } catch {
                library = .failed(error.localizedDescription)
            }
        case .downloading(_, let bytes):
            library = .downloading(bytes: bytes)
            schedulePoll()
        case .missing:
            library = .missing
        }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.openLibrary() }
        }
    }

    func chooseZimFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "zim")!]
        panel.allowsMultipleSelection = false
        panel.message = "选择一个 Kiwix ZIM 离线包"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "zimPath")
            openLibrary()
        }
    }

    // MARK: - 导航

    func open(_ path: String) {
        guard service != nil else { return }
        remember(ViewSnapshot(destination: .reader, path: path, fraction: 0))
        loadArticle(path, fraction: nil)
    }

    /// 实际切到某篇文章
    private func loadArticle(_ path: String, fraction: Double?) {
        destination = .reader
        paletteOpen = false
        restoreFraction = fraction
        reader.load(path: path)
    }

    /// 记录一次"离开当前界面"
    private func remember(_ next: ViewSnapshot) {
        if backStack.last != currentView { backStack.append(currentView) }
        forwardStack.removeAll()
        currentView = next
        syncNavButtons()
    }

    private func syncNavButtons() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    /// 打开历史 / 收藏等页面
    func show(_ d: Destination) {
        guard d != .reader else { return }
        guard destination != d else { return }
        remember(ViewSnapshot(destination: d, path: nil, fraction: readFraction))
        destination = d
        paletteOpen = false
        syncNavButtons()
    }

    func open(_ ref: ArticleRef) { open(ref.path) }

    func openRandom() {
        guard let s = service else { return }
        // 有热门排名时优先在前 2 万篇里随机，跳过标识符页/列表页等不适合阅读的条目
        if let store, store.rankCount > 1000, Bool.random() {
            let n = min(store.rankCount, 20000)
            var offset = Int.random(in: 0..<n)
            for _ in 0..<12 {
                let slice = store.ranked(from: offset, to: min(offset + 40, n))
                if let hit = slice.first(where: { ZimService.isInteresting(ArticleRef(path: $0.path, title: $0.title)) }) {
                    return open(hit.path)
                }
                offset = Int.random(in: 0..<n)
            }
        }
        for _ in 0..<8 {
            if let r = s.randomArticle(), ZimService.isInteresting(r) { return open(r) }
        }
        if let r = s.randomArticle() { open(r) }
    }

    func openMainPage() {
        if let m = service?.mainArticle() { open(m) }
    }

    func goHome() {
        show(.home)
    }

    func showHistory() { show(.history) }
    func showFavorites() { show(.favorites) }

    private func resetReadingProgress() {
        sectionIndex = -1
        sectionTotal = 0
        readFraction = 0
    }

    /// 返回上一个看过的界面（文章 / 首页 / 历史 / 收藏），和浏览器一样
    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(currentView)
        apply(prev)
    }

    /// 前进到下一个界面
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentView)
        apply(next)
    }

    private func apply(_ snap: ViewSnapshot) {
        currentView = snap
        switch snap.destination {
        case .reader:
            // 不在这里判 resolve：万一路径解析不到，也应该留在阅读器里显示"没有这篇文章"，而不是莫名跳回首页
            if let p = snap.path, !p.isEmpty {
                loadArticle(p, fraction: snap.fraction)
            } else {
                destination = .home
                paletteOpen = false
            }
        default:
            destination = snap.destination
            paletteOpen = false
        }
        syncNavButtons()
    }

    func scrollTo(section id: String) {
        reader.call("scrollToSection", id)
    }

    // MARK: - 上一节 / 下一节（按一级章节走）

    var sectionStops: [TOCItem] { toc.filter { $0.level == 2 } }

    /// 当前所处的一级章节下标（-1 表示未定位到，例如停在导语）
    var currentSectionStop: Int {
        let stops = sectionStops
        guard !stops.isEmpty else { return -1 }
        guard let a = activeSection, let i = toc.firstIndex(where: { $0.id == a }) else { return -1 }
        for j in stride(from: i, through: 0, by: -1) where toc[j].level == 2 {
            return stops.firstIndex { $0.id == toc[j].id } ?? -1
        }
        return -1
    }

    var canGoPrevSection: Bool { currentSectionStop > 0 }
    var canGoNextSection: Bool {
        let stops = sectionStops
        guard !stops.isEmpty else { return false }
        let cur = currentSectionStop
        return cur < 0 ? true : cur < stops.count - 1
    }

    func nextSection() { stepSection(1) }
    func prevSection() { stepSection(-1) }

    private func stepSection(_ d: Int) {
        guard destination == .reader else { return }
        let stops = sectionStops
        guard !stops.isEmpty else { return }
        let cur = currentSectionStop
        let target = cur < 0 ? (d > 0 ? 0 : stops.count - 1) : min(max(cur + d, 0), stops.count - 1)
        scrollTo(section: stops[target].id)
    }

    // MARK: - 阅读偏好

    private func syncStyle() {
        styleBox.style = ReaderStyle(mode: mode, fontScale: fontScale, lineHeight: lineHeight,
                                     font: font, width: pageWidth, bilingualSide: bilingualSide, theme: theme)
    }

    private func applyTheme() {
        syncStyle()
        NSApp?.appearance = theme == "light" ? NSAppearance(named: .aqua) : theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        reader.call("setTheme", theme)
    }

    func zoomIn() { fontScale = min(1.6, (fontScale * 100 + 8).rounded() / 100) }
    func zoomOut() { fontScale = max(0.75, (fontScale * 100 - 8).rounded() / 100) }
    func zoomReset() { fontScale = 1.0 }

    private func applyMode() {
        syncStyle()
        reader.call("setMode", mode.rawValue)
        updateNotice()
        if mode.needsTranslation { pumpTranslation() } else { translating = false }
    }

    private func updateNotice() {
        guard mode.needsTranslation, current != nil else { translationNotice = nil; return }
        if fakeTranslation { translationNotice = nil; return }
        switch pack {
        case .installed: if translationNotice?.hasPrefix("翻译语言包") == true { translationNotice = nil }
        case .notInstalled: translationNotice = "翻译语言包未下载，正在显示英文原文"
        case .unsupported: translationNotice = "此设备不支持英译中，正在显示英文原文"
        case .checking: break
        }
    }

    // MARK: - 翻译语言包

    func refreshPackStatus() async {
        let s = await TranslationLanguages.status()
        switch s {
        case .installed: pack = .installed
        case .supported: pack = .notInstalled
        case .unsupported: pack = .unsupported
        @unknown default: pack = .notInstalled
        }
        reversePackInstalled = await TranslationLanguages.reverseStatus() == .installed
        updateNotice()
        if pack == .installed { pumpTranslation() }
    }

    /// 通过系统提供的方式请求下载（.translationTask + prepareTranslation，会弹出系统确认框）
    func requestPackDownload() {
        if downloadRequest == nil {
            downloadRequest = .init(source: TranslationLanguages.english, target: TranslationLanguages.chinese)
        } else {
            downloadRequest?.invalidate()
        }
    }

    func openSystemTranslationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    private func engine() -> RawTranslator? {
        if fakeTranslation { return FakeTranslator(delay: .milliseconds(60)) }
        guard pack == .installed else { return nil }
        if translator == nil { translator = AppleTranslator() }
        return translator
    }

    // MARK: - 页面消息

    private func wireReader() {
        reader.onMessage = { [weak self] type, body in self?.handle(type, body) }
        reader.onNavigationChange = { [weak self] in
            guard let self else { return }
            syncNavButtons()
        }
        reader.onStartLoading = { [weak self] _ in
            guard let self else { return }
            isLoading = true
            translateTask?.cancel()
            translating = false
            if mode != defaultMode { mode = defaultMode }
        }
        reader.onBlockedExternal = { [weak self] url in
            self?.showToast("离线模式：已拦截外部链接 \(url.host ?? url.absoluteString)")
        }
    }

    /// 把"链接目标 → 中文标题"推给页面并重新挂链接（中文模式下也能点）
    private func refreshLinkTitles(force: Bool = false) {
        guard let store, !pageLinks.isEmpty else { return }
        if !force, Date().timeIntervalSince(lastLinkRefresh) < 4 { return }
        lastLinkRefresh = Date()
        let paths = Array(Set(pageLinks.values.flatMap { $0.map(\.path) }))
        guard !paths.isEmpty else { return }
        let map = store.titlesZh(for: paths)
        guard !map.isEmpty else { return }
        reader.call("setLinkTitles", map)
        reader.call("relink")
    }

    /// 把一批标题补成中文：先查标题库，缺的用本机翻译补上并写回标题库（搜索结果用）
    func chineseTitles(_ items: [(path: String, title: String)], limit: Int = 28) async -> [String: String] {
        guard let store else { return [:] }
        var out = store.titlesZh(for: items.map(\.path))
        let need = items.filter { out[$0.path] == nil && !$0.title.isEmpty }.prefix(limit)
        guard !need.isEmpty, let engine = engine() else { return out }
        let reqs = need.map { (id: $0.path, text: $0.title) }
        guard let got = try? await engine.translate(reqs) else { return out }
        var rows: [(path: String, en: String, zh: String)] = []
        for n in need { if let z = got[n.path] { out[n.path] = z; rows.append((path: n.path, en: n.title, zh: z)) } }
        store.setTitles(rows)
        return out
    }

    /// 翻译任意一批文本（搜索结果的英文摘要用），不写回标题库
    func chineseTexts(_ items: [(id: String, text: String)], limit: Int = 10, maxChars: Int = 200) async -> [String: String] {
        let reqs = items.filter { !$0.text.isEmpty }.prefix(limit).map { (id: $0.id, text: String($0.text.prefix(maxChars))) }
        guard !reqs.isEmpty, let engine = engine() else { return [:] }
        return (try? await engine.translate(reqs)) ?? [:]
    }

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == s { withAnimation { toast = nil } }
        }
    }

    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            isLoading = false
            lastLinkRefresh = .distantPast
            pageToken += 1
            let path = body["path"] as? String ?? ""
            let title = body["title"] as? String ?? path
            let missing = body["missing"] as? Bool ?? false
            titleKey = body["titleKey"] as? String
            resetReadingProgress()
            var units: [TranslationUnit] = []
            pageLinks = [:]
            for case let row as [Any] in (body["units"] as? [Any] ?? []) where row.count >= 3 {
                guard let k = row[0] as? String, let t = row[1] as? String, let o = (row[2] as? NSNumber)?.intValue else { continue }
                units.append(TranslationUnit(key: k, text: t, order: o))
                if row.count >= 4, let ls = row[3] as? [[String]] {
                    pageLinks[k] = ls.compactMap { $0.count == 2 ? UnitLink(text: $0[0], path: $0[1]) : nil }
                }
            }
            let total = (body["total"] as? NSNumber)?.intValue ?? units.count
            translatableCount = total
            translatedCount = total - units.count
            planner = TranslationPlanner()
            planner.load(units: units, alreadyTranslated: [])
            let articleLinks: [UnitLink] = (body["links"] as? [[String]] ?? []).compactMap { $0.count == 2 ? UnitLink(text: $0[0], path: $0[1]) : nil }
            glossary = nil
            glossaryReady = false
            prepareGlossary(path: path, title: title, links: articleLinks, texts: units.map(\.text), token: pageToken)
            toc = (body["toc"] as? [[String: Any]] ?? []).compactMap { d in
                guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
                return TOCItem(id: id, level: (d["level"] as? NSNumber)?.intValue ?? 2, text: text, key: d["key"] as? String)
            }
            tocTranslations = [:]
            if let store, !fakeTranslation {
                let cached = store.translations(for: path)
                for item in toc { if let k = item.key, let z = cached[k] { tocTranslations[k] = z } }
            }
            var titleZh: String? = nil
            if let store, !fakeTranslation { titleZh = store.titleZh(for: path) ?? titleKey.flatMap { store.translations(for: path)[$0] } }
            current = CurrentArticle(path: path, title: title, titleZh: titleZh, missing: missing)
            currentView = ViewSnapshot(destination: .reader, path: path, fraction: readFraction)
            if !missing { recordHistory(path: path, title: title, titleZh: titleZh) }
            UserDefaults.standard.set(path, forKey: "lastPath")
            if let f = restoreFraction {
                restoreFraction = nil
                reader.call("scrollToFraction", f)
            }
            updateNotice()
            pumpTranslation()
        case "viewport":
            let first = (body["first"] as? NSNumber)?.intValue ?? 0
            let last = (body["last"] as? NSNumber)?.intValue ?? 15
            planner.setVisible(first: first, last: last)
            pumpTranslation()
        case "section":
            activeSection = body["id"] as? String
            if let i = (body["index"] as? NSNumber)?.intValue { sectionIndex = i }
            if let t = (body["total"] as? NSNumber)?.intValue { sectionTotal = t }
            if let f = (body["fraction"] as? NSNumber)?.doubleValue { readFraction = f }
        case "progress":
            if let f = (body["fraction"] as? NSNumber)?.doubleValue { readFraction = f }
        case "retry":
            if let k = body["key"] as? String { retry(key: k) }
        case "scroll":
            if let f = (body["fraction"] as? NSNumber)?.doubleValue {
                readFraction = f
                UserDefaults.standard.set(f, forKey: "lastFraction")
            }
        default:
            break
        }
    }

    // MARK: - 实时翻译（流式：先可见区，再往下前瞻）

    /// 专名术语表：链接目标的中文名（标题缓存 / 即时翻译）+ 本条目自指（例如 Xi → 习近平）
    private func prepareGlossary(path: String, title: String, links: [UnitLink], texts: [String], token: Int) {
        guard let service, let engine = engine(), !fakeTranslation else { glossaryReady = true; return }
        let store = self.store
        Task {
            let prep = await GlossaryBuilder.prepare(articlePath: path, articleTitle: title, links: links, texts: texts,
                                                     service: service, store: store, engine: engine, maxNew: 50)
            guard self.pageToken == token else { return }
            self.glossary = prep.glossary
            self.glossaryReady = true
            // 已缓存的旧译文也做一次专名残留修正（例如 "Xi" → "习近平"），并回写缓存
            if let store, !prep.glossary.isEmpty {
                var fixed: [String: String] = [:]
                for (k, v) in store.translations(for: path) {
                    let f = prep.glossary.postFix(v)
                    if f != v { fixed[k] = f }
                }
                if !fixed.isEmpty {
                    self.reader.call("applyTranslations", fixed.map { [$0.key, $0.value] }, false)
                    store.add(fixed, for: path)
                }
            }
            self.refreshLinkTitles(force: true)
            if let z = prep.titleZh, let tk = self.titleKey {
                self.reader.call("applyTranslations", [[tk, z]], true)
                self.current?.titleZh = z
                self.planner.markDone([tk])
                self.updateHistoryTitle(path: path, zh: z)
            }
            self.pumpTranslation()
        }
    }

    func retry(key: String) {
        planner.retry([key])
        translationNotice = nil
        pumpTranslation()
    }

    func pumpTranslation() {
        guard glossaryReady else { return }
        guard mode.needsTranslation, current != nil, translateTask == nil || translateTask!.isCancelled else { return }
        guard let engine = engine() else { return }
        let token = pageToken
        guard let path = current?.path else { return }
        translateTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pageToken == token { self.translateTask = nil } }
            while !Task.isCancelled, self.pageToken == token, self.mode.needsTranslation {
                let batch = self.planner.nextBatch(maxUnits: 8, maxChars: 1800)
                if batch.isEmpty { break }
                self.translating = true
                let keys = batch.map(\.key)
                self.reader.call("markPending", keys, true)
                let inputs = batch.map { PipelineInput(key: $0.key, text: $0.text, links: self.pageLinks[$0.key] ?? []) }
                let store = self.fakeTranslation ? nil : self.store
                do {
                    let r = try await TranslationPipeline.translate(inputs, with: engine, glossary: self.glossary) { p in store?.titleZh(for: p) }
                    guard self.pageToken == token else { return }
                    let pairs = r.translations.map { [$0.key, $0.value] }
                    self.reader.call("applyTranslations", pairs, true)
                    if !r.failedKeys.isEmpty { self.reader.call("markFailed", r.failedKeys) }
                    self.planner.markDone(r.translations.keys)
                    self.planner.markFailed(r.failedKeys)
                    self.translatedCount += r.translations.count
                    store?.add(r.translations, for: path)
                    for item in self.toc { if let k = item.key, let z = r.translations[k] { self.tocTranslations[k] = z } }
                    self.refreshLinkTitles()
                    if let tk = self.titleKey, let z = r.translations[tk] {
                        self.current?.titleZh = z
                        if let c = self.current { store?.setTitles([(path: c.path, en: c.title, zh: z)]); self.updateHistoryTitle(path: c.path, zh: z) }
                    }
                } catch is CancellationError {
                    self.planner.requeue(keys)
                    return
                } catch {
                    self.planner.markFailed(keys)
                    self.reader.call("markFailed", keys)
                }
            }
            if self.pageToken == token { self.translating = false; self.reader.js("Reader.clearPending()") }
        }
    }

    /// 让预翻译 worker 知道"用户正在阅读翻译"，它会暂时让位
    private func heartbeat() {
        guard Date().timeIntervalSince(lastHeartbeat) > 3 else { return }
        lastHeartbeat = Date()
        let url = PretranslateControl.readerActiveFile
        AppPaths.ensure(url.deletingLastPathComponent())
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    // MARK: - 中文查询

    func translateQueryToEnglish(_ q: String) async -> String? {
        guard reversePackInstalled else { return nil }
        if reverseTranslator == nil { reverseTranslator = AppleTranslator(source: TranslationLanguages.chinese, target: TranslationLanguages.english) }
        return try? await reverseTranslator?.translate(q)
    }

    // MARK: - 历史 / 收藏

    private func recordHistory(path: String, title: String, titleZh: String?) {
        history = HistoryLogic.record(HistoryItem(path: path, title: title, titleZh: titleZh), into: history)
        historyFile.save(history)
    }

    private func updateHistoryTitle(path: String, zh: String) {
        if let i = history.firstIndex(where: { $0.path == path }) { history[i].titleZh = zh; historyFile.save(history) }
        if let i = favorites.firstIndex(where: { $0.path == path }) { favorites[i].titleZh = zh; favoritesFile.save(favorites) }
    }

    func clearHistory() {
        history = []
        historyFile.save(history)
    }

    var isFavorite: Bool {
        guard let c = current else { return false }
        return favorites.contains { $0.path == c.path }
    }

    func toggleFavorite() {
        guard let c = current, !c.missing else { return }
        if let i = favorites.firstIndex(where: { $0.path == c.path }) {
            favorites.remove(at: i)
            showToast("已取消收藏")
        } else {
            favorites.insert(FavoriteItem(path: c.path, title: c.title, titleZh: c.titleZh), at: 0)
            showToast("已加入收藏")
        }
        favoritesFile.save(favorites)
    }

    func removeFavorite(_ path: String) {
        favorites.removeAll { $0.path == path }
        favoritesFile.save(favorites)
    }

    // MARK: - 启动恢复

    private func restoreLastArticle() {
        guard let p = UserDefaults.standard.string(forKey: "lastPath"), !p.isEmpty, service?.resolve(path: p) != nil else { return }
        let f = UserDefaults.standard.double(forKey: "lastFraction")
        // 启动恢复：直接进文章，不往历史里塞一条"首页"
        currentView = ViewSnapshot(destination: .reader, path: p, fraction: f)
        loadArticle(p, fraction: f)
    }

    // MARK: - 今日推荐

    func loadDailyPicks(shuffle: Bool = false) {
        guard let s = service else { return }
        let store = self.store
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let seed = shuffle ? UInt64.random(in: 1...UInt64.max) : UInt64(day) &* 0x9E3779B97F4A7C15
        Task.detached(priority: .utility) {
            var refs: [ArticleRef] = []
            if let store, store.rankCount > 2000 {
                var rng = SplitMix64(seed: seed)
                let n = min(store.rankCount, 30000)
                var seen = Set<String>()
                while refs.count < 7, seen.count < 50 {
                    let i = Int(rng.next() % UInt64(n))
                    if let r = store.ranked(from: i, to: i + 1).first, seen.insert(r.path).inserted, ZimService.isInteresting(ArticleRef(path: r.path, title: r.title)) {
                        refs.append(ArticleRef(path: r.path, title: r.title))
                    }
                }
            }
            if refs.count < 7 { refs += s.dailyPicks(seed: seed, count: 7 - refs.count) }
            var picks: [DailyPick] = []
            for r in refs {
                let summary = s.content(path: r.path).map { HTMLCleaner.summary(String(decoding: $0.data, as: UTF8.self), maxLength: 260) } ?? ""
                picks.append(DailyPick(ref: r, summary: summary, titleZh: store?.titleZh(for: r.path)))
            }
            let result = picks
            await MainActor.run { self.dailyPicks = result }
            await self.translatePicks()
        }
    }

    /// 封面卡片：标题与摘要现场翻译（带淡入），标题写回标题库
    private func translatePicks() async {
        guard let engine = engine(), !fakeTranslation else { return }
        var items: [(id: String, text: String)] = []
        for p in dailyPicks {
            if p.titleZh == nil { items.append((id: "t:" + p.ref.path, text: p.ref.title)) }
            if !p.summary.isEmpty { items.append((id: "s:" + p.ref.path, text: p.summary)) }
        }
        guard !items.isEmpty, let got = try? await engine.translate(items) else { return }
        var rows: [(path: String, en: String, zh: String)] = []
        withAnimation(.easeOut(duration: 0.5)) {
            for i in dailyPicks.indices {
                let p = dailyPicks[i].ref
                if let t = got["t:" + p.path] { dailyPicks[i].titleZh = t; rows.append((path: p.path, en: p.title, zh: t)) }
                if let s = got["s:" + p.path] { dailyPicks[i].summaryZh = s }
            }
        }
        store?.setTitles(rows)
    }
}

struct DailyPick: Identifiable, Hashable {
    var ref: ArticleRef
    var summary: String
    var titleZh: String?
    var summaryZh: String?
    var id: String { ref.path }
}

/// 与预翻译 worker 之间的控制文件
enum PretranslateControl {
    static var dir: URL { AppPaths.supportDirectory.appendingPathComponent("pretranslate", isDirectory: true) }
    static var readerActiveFile: URL { dir.appendingPathComponent("reader-active") }
    static var pauseFile: URL { dir.appendingPathComponent("pause") }
    static var stopFile: URL { dir.appendingPathComponent("stop") }
    static var statusFile: URL { dir.appendingPathComponent("status.json") }
}
