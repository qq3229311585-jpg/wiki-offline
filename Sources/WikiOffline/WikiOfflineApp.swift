import SwiftUI
import WikiCore

@main
struct WikiOfflineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("维基离线", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("前往") {
            Button("搜索…") { withAnimation(.spring(duration: 0.22)) { model.paletteOpen = true } }
                .keyboardShortcut("k")
            Button("搜索（地址栏习惯）") { withAnimation(.spring(duration: 0.22)) { model.paletteOpen = true } }
                .keyboardShortcut("l")
            Divider()
            Button("返回") { model.goBack() }.keyboardShortcut("[")
            Button("前进") { model.goForward() }.keyboardShortcut("]")
            Divider()
            Button("首页") { model.goHome() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("随机条目") { model.openRandom() }.keyboardShortcut("r")
            Button("离线包首页") { model.openMainPage() }
            Divider()
            Button("历史记录") { model.showHistory() }.keyboardShortcut("y")
            Button("收藏夹") { model.showFavorites() }.keyboardShortcut("b", modifiers: [.command, .option])
        }

        CommandMenu("阅读") {
            Button(model.isFavorite ? "取消收藏" : "收藏本文") { model.toggleFavorite() }
                .keyboardShortcut("d")
                .disabled(model.current == nil)
            Divider()
            Button("中文") { model.mode = .translated }.keyboardShortcut("1")
            Button("English") { model.mode = .original }.keyboardShortcut("2")
            Button("中英对照") { model.mode = .bilingual }.keyboardShortcut("3")
            Button("把当前语言设为默认") { model.defaultMode = model.mode }
            Divider()
            Button("放大字号") { model.zoomIn() }.keyboardShortcut("+")
            Button("放大字号 ") { model.zoomIn() }.keyboardShortcut("=")
            Button("缩小字号") { model.zoomOut() }.keyboardShortcut("-")
            Button("实际大小") { model.zoomReset() }.keyboardShortcut("0")
            Menu("正文字体") {
                Picker("正文字体", selection: Binding(get: { model.font }, set: { model.font = $0 })) {
                    ForEach(ReadingFont.allCases) { f in Text("\(f.label)（\(f.hint)）").tag(f) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("版面宽度") {
                Picker("版面宽度", selection: Binding(get: { model.pageWidth }, set: { model.pageWidth = $0 })) {
                    ForEach(ReadingWidth.allCases) { w in Text(w.label).tag(w) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("行距") {
                Picker("行距", selection: Binding(get: { model.lineHeight }, set: { model.lineHeight = $0 })) {
                    Text("紧凑").tag(0.88)
                    Text("标准").tag(1.0)
                    Text("宽松").tag(1.12)
                    Text("疏朗").tag(1.26)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Toggle("对照模式并排", isOn: Binding(get: { model.bilingualSide }, set: { model.bilingualSide = $0 }))
            Divider()
            Button("排版面板（Aa）") { model.typePanelOpen.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("上一节") { model.prevSection() }.keyboardShortcut(.upArrow, modifiers: [.option])
                .disabled(!model.canGoPrevSection)
            Button("下一节") { model.nextSection() }.keyboardShortcut(.downArrow, modifiers: [.option])
                .disabled(!model.canGoNextSection)
            Divider()
            Button(model.showOutline ? "隐藏章节导航" : "显示章节导航") { model.showOutline.toggle() }
                .keyboardShortcut("t")
            Button(model.showBookshelf ? "收起书架" : "打开书架") { model.showBookshelf.toggle() }
                .keyboardShortcut("b")
            Picker("外观", selection: Binding(get: { model.theme }, set: { model.theme = $0 })) {
                Text("跟随系统").tag("system")
                Text("日间").tag("light")
                Text("夜间").tag("dark")
            }
            Button("重新载入") { model.reader.reload() }.keyboardShortcut("r", modifiers: [.command, .shift])
        }

    }
}
