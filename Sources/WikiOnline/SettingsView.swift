import SwiftUI
import WikiCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ReadingSettings().tabItem { Label("阅读", systemImage: "textformat") }
            TranslationSettings().tabItem { Label("翻译", systemImage: "character.bubble") }
            SourceSettings().tabItem { Label("数据来源", systemImage: "network") }
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
    @State private var keyInput = ""
    var body: some View {
        @Bindable var model = model
        Form {
            Section("云端翻译（DeepSeek）") {
                Picker("翻译方式", selection: $model.cloudMode) {
                    ForEach(CloudMode.allCases) { Text($0.label).tag($0) }
                }
                Text(model.cloudMode.hint).font(.caption).foregroundStyle(.secondary)
                Text("不同引擎的译文各存一份：切换“翻译方式”或模型后，当前文章会换成对应引擎的译文（还没翻过的段落现翻），方便对比。标题栏下方会显示“译文：本机 / DeepSeek”。想用当前引擎重翻整篇，用菜单“阅读 → 重新翻译本篇”。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("API 密钥") {
                    if model.hasCloudKey {
                        HStack(spacing: 10) {
                            Label("已保存在钥匙串", systemImage: "checkmark.seal").foregroundStyle(.green)
                            Button("移除") { model.removeCloudKey() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            SecureField("粘贴 DeepSeek 密钥", text: $keyInput).frame(width: 220)
                            Button("保存") { model.saveCloudKey(keyInput); keyInput = "" }
                                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Picker("模型", selection: $model.cloudModel) {
                    ForEach(DeepSeekModel.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("每月预算") {
                    Stepper(value: $model.cloudBudgetUSD, in: 1...100, step: 1) {
                        Text("$\(Int(model.cloudBudgetUSD))（约 ¥\(Int(model.cloudBudgetUSD * 7.2))）").monospacedDigit()
                    }
                }
                if let u = model.usageSnapshot {
                    LabeledContent("本月已用") {
                        Text("\(u.requests) 次请求 · 约 $\(String(format: "%.3f", u.costUSD))（¥\(String(format: "%.2f", u.costUSD * 7.2))）")
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 10) {
                    Button("测试连接") { model.testCloud() }.disabled(!model.hasCloudKey || model.cloudTesting)
                    if model.cloudTesting { ProgressView().controlSize(.small) }
                    if let r = model.cloudTestResult {
                        Text(r).font(.caption).foregroundStyle(r.hasPrefix("连接成功") ? Color.green : Color.red).textSelection(.enabled)
                    }
                }
                Text("发给 DeepSeek 的是你正在读的文章的英文片段（维基百科是公开内容），不含任何个人信息。费用按 DeepSeek 官方价格估算，美元为准，人民币是约数。部分敏感内容可能被拒绝翻译，此时自动改用本机翻译（“仅云端”模式则保持英文）。保真检查只能挡住拒绝、截断、漏数字这类明显问题，挡不住细微的改写；读敏感话题时建议用“对照”模式核对原文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("本机翻译语言包（英语 → 简体中文）") {
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
                Text("本机翻译完全在本机完成（Apple Translation 框架），不会联网；它是云端翻译不可用时的兜底。语言包首次需要联网下载一次，由系统弹窗确认。")
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

struct SourceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var stats: (count: Int, bytes: Int64) = (0, 0)
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section("数据来源") {
                if let info = model.info {
                    LabeledContent("名称") { Text(info.title) }
                    LabeledContent("条目数") { Text("约 \(info.articleCount.formatted())") }
                }
                Text("文章、搜索和中文译名都直接来自维基百科的网络接口，所以收录全部条目，内容是最新的。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("已缓存的文章（断网也能读）") {
                LabeledContent("篇数") { Text("\(stats.count.formatted()) 篇") }
                LabeledContent("占用") { Text(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)) }
                Button("清除文章缓存…", role: .destructive) { confirmClear = true }
                    .disabled(stats.count == 0)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .confirmationDialog("清除全部已缓存的文章？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { model.service?.clearPageCache(); refresh() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("译文缓存不受影响。清除后，这些文章需要联网才能再次打开。")
        }
    }
    private func refresh() { stats = model.service?.cacheStats() ?? (0, 0) }
}
