import SwiftUI
import WikiCore

/// 首页 = 杂志封面
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Masthead()
                switch model.library {
                case .ready:
                    if model.pack != .installed && !model.fakeTranslation { PackNotice().padding(.top, 26) }
                    if let lead = model.dailyPicks.first {
                        FeatureStory(pick: lead).padding(.top, 34)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    }
                    if model.dailyPicks.count > 1 {
                        PicksGrid(picks: Array(model.dailyPicks.dropFirst())).padding(.top, 46)
                    }
                    if !model.history.isEmpty { RecentStrip().padding(.top, 46) }
                    Colophon().padding(.top, 54)
                case .downloading(let bytes):
                    CoverState(title: "离线包仍在下载中", message: "已下载 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))，完成后会自动打开。")
                case .missing:
                    CoverState(title: "没有找到离线包", message: "请把 Kiwix 的 .zim 文件放到“文稿/维基百科离线”，或手动选择。", action: ("选择 ZIM 文件…", { model.chooseZimFile() }))
                case .failed(let e):
                    CoverState(title: "无法打开离线包", message: e, action: ("选择其他文件…", { model.chooseZimFile() }))
                case .locating:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 56)
            .padding(.top, 30)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Theme.paper)
    }
}

struct Masthead: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("THE OFFLINE ENCYCLOPEDIA").font(Theme.sans(10, .semibold)).kerning(3).foregroundStyle(Theme.accent)
                Spacer()
                Text(issueLine).font(Theme.sans(10.5)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 10)
            Rectangle().fill(Theme.ink).frame(height: 3)
            HStack(alignment: .lastTextBaseline) {
                Text("维基离线")
                    .font(Theme.song(78, bold: true))
                    .foregroundStyle(Theme.ink)
                    .kerning(6)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Wikipedia").font(Theme.serif(30, .bold).italic()).foregroundStyle(Theme.ink)
                    Text("英文维基百科 · 端侧中文翻译").font(Theme.song(13)).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 10)
            }
            .padding(.vertical, 6)
            Rectangle().fill(Theme.ink).frame(height: 1)
            Rectangle().fill(Theme.ink).frame(height: 1).padding(.top, 2)

            // 搜索入口
            Button { withAnimation(.spring(duration: 0.22)) { model.paletteOpen = true } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .light))
                    Text("搜索任何条目——英文或中文都可以").font(Theme.song(17))
                    Spacer()
                    Text("⌘K").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                    Rectangle().fill(Theme.rule).frame(width: 1, height: 18)
                    Button { model.openRandom() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "dice").font(.system(size: 14, weight: .light))
                            Text("随机漫游").font(Theme.song(15, bold: true))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.muted)
                .padding(.vertical, 16)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.service == nil)
        }
    }

    private var issueLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        var s = "\(f.string(from: Date())) · 第 \(day) 期"
        if let n = model.info?.articleCount { s += " · \(n.formatted()) 条" }
        return s
    }
}

/// 今日推荐主卡：巨大首字母 + 分类色块
struct FeatureStory: View {
    @Environment(AppModel.self) private var model
    let pick: DailyPick
    @State private var hover = false

    var body: some View {
        let cat = Theme.category(for: pick.summary)
        Button { model.open(pick.ref) } label: {
            HStack(alignment: .top, spacing: 36) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(cat.color.opacity(0.14))
                    Text(String(pick.ref.title.prefix(1)))
                        .font(.system(size: 260, weight: .bold, design: .serif))
                        .foregroundStyle(cat.color)
                        .offset(x: 18, y: 52)
                        .scaleEffect(hover ? 1.03 : 1, anchor: .bottomLeading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cat.label).font(Theme.song(13, bold: true)).foregroundStyle(Theme.paper)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(cat.color)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: 300, height: 330)
                .clipped()

                VStack(alignment: .leading, spacing: 0) {
                    Text("今日推荐").font(Theme.sans(11, .semibold)).kerning(3).foregroundStyle(Theme.accent)
                    Text(pick.titleZh ?? pick.ref.title)
                        .font(pick.titleZh != nil ? Theme.song(46, bold: true) : Theme.serif(44, .bold))
                        .foregroundStyle(hover ? Theme.accent : Theme.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 14)
                        .contentTransition(.opacity)
                    if pick.titleZh != nil {
                        Text(pick.ref.title).font(Theme.serif(18).italic()).foregroundStyle(Theme.muted).padding(.top, 8)
                    }
                    Rectangle().fill(Theme.accent).frame(width: 46, height: 2).padding(.vertical, 20)
                    Text(pick.summaryZh ?? pick.summary)
                        .font(pick.summaryZh != nil ? Theme.song(16.5) : Theme.serif(16.5))
                        .lineSpacing(pick.summaryZh != nil ? 9 : 6)
                        .foregroundStyle(Theme.ink.opacity(0.88))
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .id(pick.summaryZh ?? "en")
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    Text("开始阅读 →").font(Theme.song(14, bold: true)).foregroundStyle(Theme.accent).padding(.top, 18)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.25)) { hover = h } }
        .animation(.easeOut(duration: 0.5), value: pick.summaryZh)
    }
}

struct PicksGrid: View {
    @Environment(AppModel.self) private var model
    let picks: [DailyPick]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("随机精选").font(Theme.song(26, bold: true)).foregroundStyle(Theme.ink)
                Text("RANDOM READS").font(Theme.sans(10, .semibold)).kerning(2.5).foregroundStyle(Theme.faint)
                Spacer()
                Button { model.loadDailyPicks(shuffle: true) } label: {
                    Text("换一批 ↻").font(Theme.song(13, bold: true)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Theme.ink).frame(height: 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)], alignment: .leading, spacing: 34) {
                ForEach(picks) { p in PickCard(pick: p) }
            }
        }
    }
}

struct PickCard: View {
    @Environment(AppModel.self) private var model
    let pick: DailyPick
    @State private var hover = false
    var body: some View {
        let cat = Theme.category(for: pick.summary)
        Button { model.open(pick.ref) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(cat.color).frame(height: 3)
                Text(cat.label).font(Theme.song(11, bold: true)).foregroundStyle(cat.color).padding(.top, 10)
                Text(pick.titleZh ?? pick.ref.title)
                    .font(pick.titleZh != nil ? Theme.song(21, bold: true) : Theme.serif(20, .bold))
                    .foregroundStyle(hover ? Theme.accent : Theme.ink)
                    .lineLimit(2)
                    .padding(.top, 6)
                if pick.titleZh != nil {
                    Text(pick.ref.title).font(Theme.serif(12.5).italic()).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 3)
                }
                Text(pick.summaryZh ?? pick.summary)
                    .font(pick.summaryZh != nil ? Theme.song(13.5) : Theme.serif(13.5))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.ink.opacity(0.78))
                    .lineLimit(4)
                    .padding(.top, 10)
                    .id(pick.summaryZh ?? "en")
                    .transition(.opacity.combined(with: .offset(y: 4)))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(.bottom, 6)
            .offset(y: hover ? -3 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hover = h } }
        .animation(.easeOut(duration: 0.5), value: pick.summaryZh)
    }
}

struct RecentStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("继续阅读").font(Theme.song(20, bold: true)).foregroundStyle(Theme.ink)
                Spacer()
                Button("全部历史") { model.showHistory() }.buttonStyle(.plain).font(Theme.song(12.5)).foregroundStyle(Theme.muted)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(alignment: .top, spacing: 26) {
                ForEach(Array(model.history.prefix(4).enumerated()), id: \.element.id) { i, h in
                    Button { model.open(h.path) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%02d", i + 1)).font(Theme.serif(22, .bold)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.titleZh ?? h.title).font(Theme.song(14, bold: true)).foregroundStyle(Theme.ink).lineLimit(2)
                                if h.titleZh != nil { Text(h.title).font(Theme.serif(11).italic()).foregroundStyle(Theme.muted).lineLimit(1) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct Colophon: View {
    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            Text("⌘K 搜索 · ⌘R 随机 · ⌘1 中文 · ⌘2 English · ⌘3 对照 · ⌘T 章节 · ⌘B 书架 · ⌘D 收藏 · ⌘[ ⌘] 前进后退")
            Text("⌘+ ⌘- 字号 · Aa 面板调行距/字体/版面宽度 · ⌥↑ ⌥↓ 上一节/下一节 · esc 关闭浮层")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
            Text("译文模式下按住 ⌥ 点击段落，可临时查看原文。内容来自英文维基百科（CC BY-SA 4.0），完全离线，翻译在本机完成。")
                .font(Theme.sans(10)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PackNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("翻译语言包还没下载").font(Theme.song(16, bold: true)).foregroundStyle(Theme.ink)
                Text("中文阅读使用 macOS 端侧翻译，需要联网下载一次“英语”和“简体中文”语言包；之后完全离线。没有语言包时显示英文原文。")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                HStack(spacing: 16) {
                    Button("下载语言包") { model.requestPackDownload() }.buttonStyle(.plain).font(Theme.song(13, bold: true)).foregroundStyle(Theme.accent)
                    Button("打开系统设置") { model.openSystemTranslationSettings() }.buttonStyle(.plain).font(Theme.song(13)).foregroundStyle(Theme.ink)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CoverState: View {
    let title: String
    let message: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(Theme.song(30, bold: true)).foregroundStyle(Theme.ink)
            Text(message).font(Theme.sans(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.plain).font(Theme.song(15, bold: true)).foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}

// MARK: - 历史 / 收藏

struct LibraryPage: View {
    enum Kind { case history, favorites }
    @Environment(AppModel.self) private var model
    let kind: Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    Text(kind == .history ? "历史记录" : "收藏夹").font(Theme.song(40, bold: true)).foregroundStyle(Theme.ink)
                    Spacer()
                    if kind == .history && !model.history.isEmpty {
                        Button("清空历史") { model.clearHistory() }.buttonStyle(.plain).font(Theme.song(13)).foregroundStyle(Theme.muted)
                    }
                }
                Rectangle().fill(Theme.ink).frame(height: 2).padding(.top, 10).padding(.bottom, 8)
                let rows: [(String, String, String?, Date)] = kind == .history
                    ? model.history.map { ($0.id, $0.path, $0.titleZh, $0.date) }
                    : model.favorites.map { ($0.id, $0.path, $0.titleZh, $0.added) }
                let titles: [String: String] = Dictionary((kind == .history ? model.history.map { ($0.path, $0.title) } : model.favorites.map { ($0.path, $0.title) }), uniquingKeysWith: { a, _ in a })
                if rows.isEmpty {
                    Text(kind == .history ? "读过的文章会出现在这里。" : "阅读时按 ⌘D 收藏文章。").font(Theme.song(15)).foregroundStyle(Theme.muted).padding(.top, 30)
                }
                ForEach(rows, id: \.0) { r in
                    Button { model.open(r.1) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.2 ?? titles[r.1] ?? r.1).font(Theme.song(18, bold: true)).foregroundStyle(Theme.ink)
                                if r.2 != nil { Text(titles[r.1] ?? "").font(Theme.serif(13).italic()).foregroundStyle(Theme.muted) }
                            }
                            Spacer()
                            Text(r.3.formatted(date: .abbreviated, time: .shortened)).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if kind == .favorites { Button("取消收藏") { model.removeFavorite(r.1) } }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}
