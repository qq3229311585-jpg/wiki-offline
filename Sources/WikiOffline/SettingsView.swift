import SwiftUI
import WikiCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ReadingSettings().tabItem { Label("阅读", systemImage: "textformat") }
            TranslationSettings().tabItem { Label("翻译", systemImage: "character.bubble") }
            LibrarySettings().tabItem { Label("离线包", systemImage: "externaldrive") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

struct ReadingSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Picker("内容语言（默认）", selection: $model.defaultMode) {
                Text("中文").tag(ReadingMode.translated)
                Text("English").tag(ReadingMode.original)
                Text("中英对照").tag(ReadingMode.bilingual)
            }
            .pickerStyle(.segmented)
            Text("每篇文章打开时使用这个设置；工具栏里的切换只影响当前这篇。切换是即时的：已翻译的段落直接读缓存，不会重新翻译。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("字号") {
                HStack {
                    Slider(value: $model.fontScale, in: 0.75...1.6, step: 0.05)
                    Text("\(Int(model.fontScale * 100))%").monospacedDigit().frame(width: 44)
                }
            }
            Picker("正文字体", selection: $model.font) {
                ForEach(ReadingFont.allCases) { f in Text("\(f.label)（\(f.hint)）").tag(f) }
            }
            Picker("版面宽度", selection: $model.pageWidth) {
                ForEach(ReadingWidth.allCases) { w in Text(w.label).tag(w) }
            }
            LabeledContent("行距") {
                HStack {
                    Slider(value: $model.lineHeight, in: 0.85...1.3, step: 0.02)
                    Text("\(Int(model.lineHeight * 100))%").monospacedDigit().frame(width: 44)
                }
            }
            Toggle("对照模式并排（左右）", isOn: $model.bilingualSide)
        }
        .formStyle(.grouped)
    }
}

struct TranslationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64 = 0
    var body: some View {
        Form {
            Section("系统翻译语言包（英语 → 简体中文）") {
                LabeledContent("状态") {
                    HStack {
                        Circle().fill(model.pack == .installed ? Color.green : .orange).frame(width: 8, height: 8)
                        Text(model.pack.label)
                    }
                }
                LabeledContent("中文搜索（简体中文 → 英语）") { Text(model.reversePackInstalled ? "可用" : "不可用") }
                HStack {
                    Button("下载语言包…") { model.requestPackDownload() }.disabled(model.pack == .installed)
                    Button("打开系统设置") { model.openSystemTranslationSettings() }
                    Button("重新检查") { Task { await model.refreshPackStatus() } }
                }
                Text("翻译完全在本机完成（Apple Translation 框架，使用已安装的语言包），不会联网。语言包首次需要联网下载一次，由系统弹窗确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("译文缓存") {
                LabeledContent("占用") { Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)) }
                if let store = model.store {
                    let t = store.totals()
                    LabeledContent("已缓存") { Text("\(t.articles) 篇文章的 \(t.units) 段 · \(t.titles) 个标题") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cacheSize = model.store?.fileSize ?? 0 }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            if let info = model.info {
                LabeledContent("文件") { Text(info.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                LabeledContent("名称") { Text(info.title) }
                LabeledContent("条目数") { Text(info.articleCount.formatted()) }
                LabeledContent("日期") { Text(info.date) }
                LabeledContent("大小") { Text(ByteCountFormatter.string(fromByteCount: Int64(info.fileSize), countStyle: .file)) }
                LabeledContent("全文索引") { Text(info.hasFulltextIndex ? "有" : "无") }
            } else {
                Text("尚未打开离线包")
            }
            Button("选择其他 ZIM 文件…") { model.chooseZimFile() }
        }
        .formStyle(.grouped)
    }
}
