import SwiftUI
import WikiCore

/// 顶栏的 Aa 按钮：点开排版面板（字号 · 行距 · 字体 · 宽度 · 对照 · 主题）
struct TypeButton: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.typePanelOpen.toggle() } label: {
            Text("Aa")
                .font(Theme.serif(13.5, hover || model.typePanelOpen ? .semibold : .regular))
                .foregroundStyle(hover || model.typePanelOpen ? Theme.ink : Theme.muted)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("排版：字号 · 行距 · 字体 · 版面宽度（⌘⇧A）")
        .popover(isPresented: Binding(get: { model.typePanelOpen }, set: { model.typePanelOpen = $0 }), arrowEdge: .bottom) {
            TypePanel().environment(model)
        }
    }
}

/// 杂志风排版面板：左侧小型大写标签，右侧小块选择器（朱红下划线标记当前项）
struct TypePanel: View {
    @Environment(AppModel.self) private var model

    private let lineHeights: [(String, Double)] = [("紧凑", 0.88), ("标准", 1.0), ("宽松", 1.12), ("疏朗", 1.26)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            row("语言") {
                chips([("中文", ReadingMode.translated), ("English", ReadingMode.original), ("对照", ReadingMode.bilingual)],
                      current: model.mode) { model.mode = $0 }
            }
            row("字号") {
                HStack(spacing: 8) {
                    step("A", 11) { model.zoomOut() }
                    Slider(value: Binding(get: { model.fontScale }, set: { model.fontScale = $0 }),
                           in: 0.75...1.6, step: 0.05)
                        .controlSize(.mini)
                        .frame(width: 108)
                    step("A", 15) { model.zoomIn() }
                    Text("\(Int(model.fontScale * 100))%")
                        .font(Theme.sans(10.5)).monospacedDigit()
                        .foregroundStyle(Theme.muted).frame(width: 32, alignment: .trailing)
                }
            }
            row("行距") { chips(lineHeights, current: closestLineHeight) { model.lineHeight = $0 } }
            row("字体") { chips(ReadingFont.allCases.map { ($0.label, $0) }, current: model.font) { model.font = $0 } }
            row("宽度") { chips(ReadingWidth.allCases.map { ($0.label, $0) }, current: model.pageWidth) { model.pageWidth = $0 } }
            row("对照版式") {
                HStack(spacing: 10) {
                    chips([("上下", false), ("并排", true)], current: model.bilingualSide) { model.bilingualSide = $0 }
                    if model.mode != .bilingual {
                        Text("仅对照模式").font(Theme.sans(10)).foregroundStyle(Theme.faint)
                    }
                }
                .opacity(model.mode == .bilingual ? 1 : 0.4)
                .disabled(model.mode != .bilingual)
            }
            row("主题") {
                chips([("系统", "system"), ("日间", "light"), ("夜间", "dark")], current: model.theme) { model.theme = $0 }
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: 6) {
                Text("菜单「阅读」里也有这些开关").font(Theme.sans(10)).foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
                Button("还原") {
                    model.fontScale = 1
                    model.lineHeight = 1
                    model.font = .song
                    model.pageWidth = .standard
                    model.bilingualSide = false
                }
                .buttonStyle(.plain).font(Theme.sans(10.5)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 316)
        .background(Theme.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("排版").font(Theme.song(15, bold: true)).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Text("Aa").font(Theme.serif(12)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(Theme.sans(10, .semibold)).kerning(1.6)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func chips<T: Equatable>(_ items: [(String, T)], current: T, pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ChipButton(label: item.0, on: item.1 == current) { pick(item.1) }
            }
        }
    }

    private func step(_ t: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(Theme.serif(size)).foregroundStyle(Theme.muted)
                .frame(width: 18, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closestLineHeight: Double {
        lineHeights.map(\.1).min { abs($0 - model.lineHeight) < abs($1 - model.lineHeight) } ?? 1.0
    }
}

/// 文字式小块选择器（与顶栏语言切换同一套语言）
struct ChipButton: View {
    let label: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.song(12, bold: on))
                .foregroundStyle(on ? Theme.ink : Theme.muted)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? Theme.paper2 : .clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(on ? Theme.accent : (hover ? Theme.rule : Color.clear)).frame(height: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
