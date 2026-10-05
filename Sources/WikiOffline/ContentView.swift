import SwiftUI
import Translation
import WebKit
import WikiCore

// MARK: - 主题

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let v = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }
    static let paper = dyn(0xF6F1E7, 0x1B1915)
    static let paper2 = dyn(0xEFE8DB, 0x232019)
    static let ink = dyn(0x1D1A16, 0xEDE7DA)
    static let muted = dyn(0x7B7165, 0xB3AB9C)
    static let faint = dyn(0xA59A8C, 0x8A8274)
    static let rule = dyn(0xDCD3C4, 0x33302A)
    static let accent = dyn(0xC0392B, 0xE0685A)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func song(_ size: CGFloat, bold: Bool = false) -> Font {
        bold ? .custom("Songti SC", size: size).weight(.black) : .custom("Songti SC", size: size)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// 分类（按导语关键词粗分，仅用于卡片配色与标签）
    static func category(for summary: String) -> (label: String, color: Color) {
        let s = summary.lowercased()
        func has(_ ws: [String]) -> Bool { ws.contains { s.contains($0) } }
        if has([" was born", "(born ", " is an american", " was an ", " is a british", "politician", "actor", "singer", "writer", "player", "artist", "scientist"]) { return ("人物", dyn(0xB5523B, 0xD9765F)) }
        if has(["city", "town", "village", "capital", "province", "county", "river", "mountain", "island", "country", "region", "district"]) { return ("地理", dyn(0x3E7A6B, 0x6FB09E)) }
        if has(["war", "battle", "empire", "dynasty", "kingdom", "revolution", "century", "ancient"]) { return ("历史", dyn(0x8A6A2F, 0xC9A35C)) }
        if has(["film", "album", "song", "band", "novel", "television", "series", "game", "music", "book"]) { return ("文艺", dyn(0x6B4C8A, 0xA88BC7)) }
        if has(["species", "genus", "family", "plant", "animal", "bird", "fish", "insect", "disease", "cell", "chemical", "physics", "mathemat"]) { return ("自然科学", dyn(0x2F6690, 0x6EA3CC)) }
        if has(["company", "software", "university", "organization", "party", "team", "club", "brand"]) { return ("机构", dyn(0x5A6470, 0x9AA5B1)) }
        return ("综合", dyn(0x7B7165, 0xA39A8C))
    }
}

// MARK: - 根视图

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tocHover = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                ZStack {
                    DetailView()
                    // 右边缘悬停呼出章节导航
                    if model.destination == .reader && !model.showOutline {
                        HStack {
                            Spacer()
                            Color.clear.frame(width: 14).contentShape(Rectangle())
                                .onHover { if $0 { withAnimation(.spring(duration: 0.3)) { tocHover = true } } }
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            // 右侧浮出的章节导航
            if model.destination == .reader && (model.showOutline || tocHover) {
                GeometryReader { geo in
                    HStack {
                        Spacer()
                        OutlinePanel(maxHeight: max(200, geo.size.height - 128))
                            .padding(.top, 64)
                            .padding(.trailing, 14)
                            .padding(.bottom, 18)
                            .onHover { inside in if !inside && tocHover { withAnimation(.easeOut(duration: 0.2)) { tocHover = false } } }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(edges: .top)
            }

            // 左侧滑出的书架
            if model.showBookshelf {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.08).ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(duration: 0.3)) { model.showBookshelf = false } }
                    BookshelfPanel()
                        .transition(.move(edge: .leading))
                }
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }

            if model.paletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.14).ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.paletteOpen = false } }
                    SearchPalette()
                        .padding(.top, 84)
                        .transition(.asymmetric(insertion: .scale(scale: 0.98).combined(with: .opacity), removal: .opacity))
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.ink.opacity(0.88), in: Capsule())
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if model.destination == .reader {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                        Rectangle().fill(Theme.accent)
                            .frame(width: max(0, g.size.width * min(max(model.readFraction, 0), 1)), height: 2)
                            .animation(.easeOut(duration: 0.18), value: model.readFraction)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.25), value: model.toast)
        .animation(.spring(duration: 0.32), value: model.showBookshelf)
        .animation(.spring(duration: 0.3), value: model.showOutline)
        .tint(Theme.accent)
        .focusEffectDisabled()
        .translationTask(model.downloadRequest) { session in
            do { try await session.prepareTranslation() } catch {}
            await model.refreshPackStatus()
        }
        .background(WindowAccessor())
        .background(
            Button("") {
                if model.paletteOpen { withAnimation(.easeOut(duration: 0.15)) { model.paletteOpen = false } }
                else if model.showBookshelf { withAnimation(.spring(duration: 0.3)) { model.showBookshelf = false } }
                else if model.showOutline { withAnimation(.spring(duration: 0.3)) { model.showOutline = false } }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPackStatus() }
        }
    }
}

// MARK: - 顶栏（自绘，极简细线图标）

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 72, height: 1)   // 红绿灯
            BarIcon("chevron.left", help: "返回上一个界面 ⌘[") { model.goBack() }
                .disabled(!model.canGoBack)
            BarIcon("chevron.right", help: "前进到下一个界面 ⌘]") { model.goForward() }
                .disabled(!model.canGoForward)
            BarIcon("house", help: "首页 ⇧⌘H") { model.goHome() }

            Spacer(minLength: 12)
            if model.destination == .reader, let c = model.current {
                VStack(spacing: 0) {
                    Text(c.titleZh ?? c.title).font(Theme.song(13, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                    if c.titleZh != nil { Text(c.title).font(Theme.serif(10.5).italic()).foregroundStyle(Theme.muted).lineLimit(1) }
                    if model.translating, model.mode.needsTranslation, model.translatableCount > 0 {
                        Text("正在翻译 \(model.translatedCount) / \(model.translatableCount) 段")
                            .font(Theme.sans(9.5)).foregroundStyle(Theme.faint)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: 320)
                .animation(.easeInOut(duration: 0.35), value: model.translating)
                .transition(.opacity)
            } else {
                Text("维基离线").font(Theme.song(14, bold: true)).foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 12)

            // 书架 / 最近读过（紧挨搜索框左边）
            BarIcon("books.vertical", help: "书架与最近读过 ⌘B") { model.showBookshelf.toggle() }

            // 搜索入口（常显）
            Button { withAnimation(.spring(duration: 0.22)) { model.paletteOpen = true } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .light))
                    Text("搜索").font(Theme.sans(12.5))
                    Spacer(minLength: 10)
                    Text("⌘K").font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
                }
                .foregroundStyle(Theme.muted)
                .frame(width: 168, height: 26)
                .padding(.horizontal, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索（⌘K / ⌘L）")

            BarIcon(model.isFavorite ? "star.fill" : "star", tint: model.isFavorite ? Theme.accent : nil, help: "收藏 ⌘D") { model.toggleFavorite() }
                .disabled(model.current == nil || model.destination != .reader)
            BarIcon("dice", help: "随机漫游 ⌘R") { model.openRandom() }
            BarIcon("list.number", tint: model.showOutline ? Theme.accent : nil, help: "章节导航 ⌘T") { model.showOutline.toggle() }
            TypeButton()
                .padding(.trailing, 10)
        }
        .frame(height: 52)
        .background(Theme.paper.opacity(0.96))
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.rule).frame(height: 1)
                if model.destination == .reader && model.translating && model.mode.needsTranslation {
                    GeometryReader { g in
                        Rectangle().fill(Theme.accent)
                            .frame(width: g.size.width * Double(model.translatedCount) / Double(max(model.translatableCount, 1)), height: 1.5)
                            .animation(.easeOut(duration: 0.4), value: model.translatedCount)
                    }
                    .frame(height: 1.5)
                    .transition(.opacity)
                }
            }
        }
        .gesture(WindowDragGesture())
        .animation(.easeInOut(duration: 0.3), value: model.translating)
    }
}

struct BarIcon: View {
    let symbol: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, tint: Color? = nil, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(tint ?? (hover ? Theme.ink : Theme.muted))
                .frame(width: 32, height: 30)
                .background(hover && enabled ? Theme.paper2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 中文 · English · 对照（文字式切换，朱红下划线标记当前项）
struct LanguageSwitch: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 14) {
            item("中文", .translated)
            item("English", .original)
            item("对照", .bilingual)
        }
        .padding(.horizontal, 6)
        .help("本篇临时切换：中文 ⌘1 · English ⌘2 · 对照 ⌘3（默认值在设置里）")
    }

    func item(_ label: String, _ m: ReadingMode) -> some View {
        Button { withAnimation(.spring(duration: 0.28)) { model.mode = m } } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(m == .original ? Theme.serif(12.5, model.mode == m ? .semibold : .regular) : Theme.song(13, bold: model.mode == m))
                    .foregroundStyle(model.mode == m ? Theme.ink : Theme.muted)
                ZStack {
                    if model.mode == m { Rectangle().fill(Theme.accent).frame(height: 1.5).matchedGeometryEffect(id: "u", in: ns) }
                    else { Rectangle().fill(.clear).frame(height: 1.5) }
                }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 详情区

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ReaderWebView(controller: model.reader)
                .opacity(model.destination == .reader ? 1 : 0)
                .allowsHitTesting(model.destination == .reader)
            switch model.destination {
            case .home: HomeView().transition(.opacity)
            case .history: LibraryPage(kind: .history).transition(.opacity)
            case .favorites: LibraryPage(kind: .favorites).transition(.opacity)
            case .reader: EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.destination)
        .overlay(alignment: .top) {
            if model.destination == .reader, let notice = model.translationNotice {
                NoticeBanner(text: notice)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.translationNotice)
    }
}

struct ReaderWebView: NSViewRepresentable {
    let controller: ReaderController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.accent).frame(width: 2, height: 14)
            Text(text).font(Theme.sans(12)).foregroundStyle(Theme.ink)
            if model.pack == .notInstalled {
                Button("下载语言包") { model.requestPackDownload() }
                    .buttonStyle(.plain).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.accent)
            }
            Button { withAnimation { model.translationNotice = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.rule))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
    }
}

// MARK: - 章节导航（浮出）

struct OutlinePanel: View {
    @Environment(AppModel.self) private var model
    /// 由外层按窗口高度算出的上限，避免面板被撑高后居中盖在正文上
    var maxHeight: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("章节").font(Theme.sans(10, .semibold)).kerning(2).foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                if model.sectionTotal > 0 {
                    Text("第 \(max(1, model.sectionIndex + 1)) 节 · 共 \(model.sectionTotal) 节")
                        .font(Theme.sans(10)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if model.toc.isEmpty {
                Text("这篇文章没有章节").font(Theme.sans(12)).foregroundStyle(Theme.muted).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            let numbered = numbering()
                            ForEach(model.toc) { item in
                                OutlineRow(item: item, number: numbered[item.id], active: model.activeSection == item.id,
                                           zh: item.key.flatMap { model.tocTranslations[$0] })
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.scrollTo(section: item.id) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(height: listHeight)
                    .onChange(of: model.activeSection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                Rectangle().fill(Theme.rule).frame(height: 1).padding(.horizontal, 12)
                HStack(spacing: 0) {
                    stepButton("上一节", "⌥↑", enabled: model.canGoPrevSection) { model.prevSection() }
                    Rectangle().fill(Theme.rule).frame(width: 1, height: 20)
                    stepButton("下一节", "⌥↓", enabled: model.canGoNextSection) { model.nextSection() }
                }
                .padding(.vertical, 3)
            }
        }
        .frame(width: 288)
        .frame(height: panelHeight, alignment: .top)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.rule))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }

    /// 按条目数估算列表高度（一级章节高一些），再受窗口可用高度限制
    private var rowsHeight: CGFloat {
        var h: CGFloat = 0
        for t in model.toc { h += t.level == 2 ? 33 : 28 }
        return h + 10
    }
    private var listHeight: CGFloat { max(96, min(rowsHeight, maxHeight - 132)) }
    private var panelHeight: CGFloat { model.toc.isEmpty ? 104 : listHeight + 132 }

    private func stepButton(_ title: String, _ key: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.song(12))
                Text(key).font(Theme.sans(9.5)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.ink : Theme.faint)
        .disabled(!enabled)
    }

    private func numbering() -> [String: String] {
        var n = 0
        var out: [String: String] = [:]
        for t in model.toc where t.level == 2 {
            n += 1
            out[t.id] = String(format: "%02d", n)
        }
        return out
    }
}

struct OutlineRow: View {
    @Environment(AppModel.self) private var model
    let item: TOCItem
    let number: String?
    let active: Bool
    let zh: String?
    @State private var hover = false

    var body: some View {
        let showZh = model.mode != .original && zh != nil
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number ?? "").font(Theme.sans(9.5, .semibold)).foregroundStyle(active ? Theme.accent : Theme.faint).frame(width: 18, alignment: .trailing)
            Text(showZh ? zh! : item.text)
                .font(showZh ? Theme.song(item.level == 2 ? 13 : 12, bold: item.level == 2 && active) : Theme.serif(item.level == 2 ? 12.5 : 11.5, active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.accent : (item.level == 2 ? Theme.ink : Theme.muted))
                .lineLimit(2)
        }
        .padding(.leading, item.level == 2 ? 0 : 14)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Theme.paper2 : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.18), value: active)
    }
}

// MARK: - 书架（滑出）

struct BookshelfPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("书架").font(Theme.song(26, bold: true)).foregroundStyle(Theme.ink).padding(.top, 58)
            Rectangle().fill(Theme.ink).frame(height: 2).padding(.top, 8)
            HStack(spacing: 16) {
                shelfLink("首页") { model.goHome() }
                shelfLink("全部历史") { model.showHistory() }
                shelfLink("收藏夹") { model.showFavorites() }
            }
            .padding(.vertical, 12)
            Rectangle().fill(Theme.rule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.favorites.isEmpty {
                        shelfHeader("收藏")
                        ForEach(model.favorites.prefix(15)) { f in ShelfRow(title: f.title, zh: f.titleZh, mark: "★") { model.open(f.path) } }
                    }
                    shelfHeader("最近读过")
                    if model.history.isEmpty {
                        Text("还没有读过的文章").font(Theme.sans(12)).foregroundStyle(Theme.muted).padding(.vertical, 8)
                    }
                    ForEach(Array(model.history.prefix(30).enumerated()), id: \.element.id) { i, h in
                        ShelfRow(title: h.title, zh: h.titleZh, mark: String(format: "%02d", i + 1)) { model.open(h.path) }
                    }
                }
                .padding(.bottom, 20)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(model.pack == .installed ? Color.green.opacity(0.8) : Theme.accent).frame(width: 6, height: 6)
                Text(model.pack.label).font(Theme.sans(10.5)).foregroundStyle(Theme.muted)
                Spacer()
                if let info = model.info { Text("\(info.articleCount.formatted()) 条").font(Theme.sans(10.5)).foregroundStyle(Theme.faint) }
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 22)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.rule).frame(width: 1) }
        .shadow(color: .black.opacity(0.10), radius: 16, x: 5)
    }

    func shelfLink(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button { a(); withAnimation(.spring(duration: 0.3)) { model.showBookshelf = false } } label: {
            Text(t).font(Theme.song(13)).foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
    }

    func shelfHeader(_ t: String) -> some View {
        Text(t).font(Theme.sans(10, .semibold)).kerning(2).foregroundStyle(Theme.accent).padding(.top, 18).padding(.bottom, 6)
    }
}

struct ShelfRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let zh: String?
    let mark: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button {
            action()
            withAnimation(.spring(duration: 0.3)) { model.showBookshelf = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(mark).font(Theme.sans(9.5, .semibold)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(zh ?? title).font(zh != nil ? Theme.song(14, bold: true) : Theme.serif(14, .semibold)).foregroundStyle(hover ? Theme.accent : Theme.ink).lineLimit(1)
                    if zh != nil { Text(title).font(Theme.serif(11).italic()).foregroundStyle(Theme.muted).lineLimit(1) }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 窗口状态

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.setFrameUsingName("WikiOfflineMainWindow")
            w.setFrameAutosaveName("WikiOfflineMainWindow")
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
