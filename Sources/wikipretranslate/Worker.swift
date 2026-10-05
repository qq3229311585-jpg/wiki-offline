// wikipretranslate —— 整夜预翻译 worker
//
// 优先级（按热门度排序）：
//   1. 标题 → 中文（支撑中文搜索与中文标题列表），尽可能多
//   2. 热门条目的导语段
//   3. 少量最热门条目全文（时间富余才做）
// 硬约束：截止时间自动停止；温度 fair 降并发、serious 以上暂停；内存压力 warning 降并发、critical 暂停并释放缓存；
//         常驻内存 >3GB 降并发、>4GB 退出由守护脚本重启；用户阅读时让位；只持有"阻止系统空闲休眠"断言。
// 全部进度写 SQLite（WAL，小批量提交），随时可杀、可续。
//
// 用法：wikipretranslate [--zim 路径] [--deadline 07:00] [--concurrency 2] [--minutes N] [--fake]
import Foundation
import IOKit.pwr_mgt
import WikiCore

// MARK: - 参数

struct Options {
    var zim: String?
    var deadline = "07:00"
    var concurrency = 2
    var minutes: Double?
    var fake = false
    var rankArticles = 4000
    var rerank = false
    var logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/维基百科离线/预翻译日志.txt").path

    init(_ args: [String]) {
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--zim": zim = next()
            case "--deadline": deadline = next() ?? deadline
            case "--concurrency": concurrency = Int(next() ?? "") ?? concurrency
            case "--minutes": minutes = Double(next() ?? "")
            case "--fake": fake = true
            case "--rank-articles": rankArticles = Int(next() ?? "") ?? rankArticles
            case "--log": logPath = next() ?? logPath
            case "--rerank": rerank = true
            default: break
            }
            i += 1
        }
        concurrency = max(1, min(4, concurrency))
    }
}

let opts = Options(CommandLine.arguments)
let controlDir = AppPaths.supportDirectory.appendingPathComponent("pretranslate", isDirectory: true)
let statusURL = controlDir.appendingPathComponent(opts.fake ? "status-fake.json" : "status.json")

// MARK: - 日志

let logLock = NSLock()
func log(_ s: String, toFile: Bool = true) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(opts.fake ? "[伪翻译测试] " : "")\(s)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    guard toFile else { return }
    logLock.lock()
    defer { logLock.unlock() }
    let url = URL(fileURLWithPath: opts.logPath)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: "维基离线 · 预翻译日志\n".data(using: .utf8))
    }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    }
}

// MARK: - 系统状态

func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func thermalName(_ t: ProcessInfo.ThermalState) -> String {
    switch t {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

func deadlineDate(_ hhmm: String) -> Date {
    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
    let cal = Calendar.current
    var d = cal.date(bySettingHour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date())!
    if d <= Date().addingTimeInterval(60) { d = cal.date(byAdding: .day, value: 1, to: d)! }
    return d
}

/// 只阻止"系统空闲休眠"，允许熄屏
final class SleepGuard {
    private var id: IOPMAssertionID = 0
    private var held = false
    func hold() {
        guard !held else { return }
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "维基离线预翻译" as CFString, &id)
        held = r == kIOReturnSuccess
    }
    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }
}

// MARK: - 共享状态

actor Stats {
    var titlesDone = 0, leadsDone = 0, fullDone = 0
    var wordsTotal = 0, titlesTotalSession = 0
    var events: [(Date, Int, Int)] = []   // (时间, 词数, 标题数)
    var phase = "启动"
    var current = ""
    var failures = 0

    func add(words: Int, titles: Int) {
        wordsTotal += words
        titlesTotalSession += titles
        events.append((Date(), words, titles))
        let cut = Date().addingTimeInterval(-300)
        events.removeAll { $0.0 < cut }
    }
    func setCounts(titles: Int, leads: Int, full: Int) { titlesDone = titles; leadsDone = leads; fullDone = full }
    func incTitles(_ n: Int) { titlesDone += n }
    func incLead() { leadsDone += 1 }
    func incFull() { fullDone += 1 }
    func set(phase: String) { self.phase = phase }
    func set(current: String) { self.current = current }
    func fail() { failures += 1 }

    /// 近 5 分钟速度
    func rates() -> (wordsPerSec: Double, titlesPerSec: Double) {
        guard let first = events.first else { return (0, 0) }
        let span = max(30, Date().timeIntervalSince(first.0))
        let w = events.reduce(0) { $0 + $1.1 }
        let t = events.reduce(0) { $0 + $1.2 }
        return (Double(w) / span, Double(t) / span)
    }
}

/// 动态并发闸门
actor Gate {
    var limit: Int
    var active = 0
    init(limit: Int) { self.limit = limit }
    func setLimit(_ n: Int) { limit = n }
    func enter() async -> Bool {
        while active >= limit {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        active += 1
        return true
    }
    func leave() { active -= 1 }
}

enum Job: Sendable {
    case titles([(path: String, title: String)])
    case lead(path: String, title: String)
    case full(path: String, title: String)
}

actor JobQueue {
    private var jobs: [Job]
    private var i = 0
    init(_ jobs: [Job]) { self.jobs = jobs }
    func next() -> Job? {
        guard i < jobs.count else { return nil }
        defer { i += 1 }
        return jobs[i]
    }
    var remaining: Int { jobs.count - i }
}

// MARK: - 主流程

@main
struct Pretranslate {
    static let stats = Stats()
    static let gate = Gate(limit: opts.concurrency)
    static var stopReason: String?
    static let sleepGuard = SleepGuard()
    static var memoryWarningUntil = Date.distantPast
    static var memoryCriticalUntil = Date.distantPast
    static var effectiveLimit = opts.concurrency
    static var pausedReason: String?

    static func main() async {
        AppPaths.ensure(controlDir)
        let started = Date()
        let deadline = deadlineDate(opts.deadline)
        let runUntil = opts.minutes.map { started.addingTimeInterval($0 * 60) } ?? deadline
        let endAt = min(deadline, runUntil)

        // ZIM
        let zimPath: String
        if let z = opts.zim { zimPath = z } else {
            guard case .ready(let u) = ZimLocator.locate(preferred: UserDefaults(suiteName: "local.wikioffline.reader")?.string(forKey: "zimPath")) else {
                log("找不到可用的 ZIM（或仍在下载），退出")
                exit(2)
            }
            zimPath = u.path
        }
        if ZimLocator.isDownloading(URL(fileURLWithPath: zimPath)) { log("ZIM 仍在下载，退出"); exit(2) }
        ZimArchive.setClusterCacheMaxSize(64 << 20)
        guard let service = try? ZimService(path: zimPath) else { log("无法打开 ZIM：\(zimPath)"); exit(2) }
        service.archive.setDirentCacheMaxSize(2048)

        // 译文库
        let dbURL = opts.fake ? controlDir.appendingPathComponent("fake-test.sqlite") : TranslationStore.defaultURL(forArchiveUUID: service.info.uuid)
        guard let store = try? TranslationStore(url: dbURL) else { log("无法打开译文数据库"); exit(2) }

        // 翻译引擎
        let status = await TranslationLanguages.status()
        if !opts.fake && status != .installed {
            log("翻译语言包状态为 \(status)，不是 installed，退出（不会联网下载）")
            exit(3)
        }

        log("启动：pid \(getpid())，并发 \(opts.concurrency)，截止 \(DateFormatter.localizedString(from: endAt, dateStyle: .none, timeStyle: .short))，数据库 \(dbURL.lastPathComponent)")
        sleepGuard.hold()
        defer { sleepGuard.release() }

        // 停止 / 暂停信号
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigSrc = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { stopReason = "收到信号 \(sig)" }
            s.resume()
            return s
        }
        _ = sigSrc

        // 内存压力
        let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        mem.setEventHandler {
            let e = mem.data
            if e.contains(.critical) {
                memoryCriticalUntil = Date().addingTimeInterval(120)
                ZimArchive.setClusterCacheMaxSize(0)
                ZimArchive.setClusterCacheMaxSize(64 << 20)
                log("系统内存压力 critical：暂停 2 分钟并释放缓存")
            } else if e.contains(.warning) {
                memoryWarningUntil = Date().addingTimeInterval(300)
                log("系统内存压力 warning：并发降为 1")
            }
        }
        mem.resume()

        // 监控循环：每 2 秒评估一次并发上限，每 5 秒写状态，每 10 分钟写日志
        let monitor = Task {
            var lastLog = Date()
            var lastStatus = Date.distantPast
            while !Task.isCancelled {
                let now = Date()
                if now >= endAt { stopReason = now >= deadline ? "到达截止时间 \(opts.deadline)" : "到达运行时长上限" }
                if FileManager.default.fileExists(atPath: controlDir.appendingPathComponent("stop").path) { stopReason = "用户停止" }
                let thermal = ProcessInfo.processInfo.thermalState
                let rss = residentMB()
                var limit = opts.concurrency
                var paused: String? = nil
                if thermal == .serious || thermal == .critical { paused = "温度 \(thermalName(thermal))，暂停降温" }
                else if thermal == .fair { limit = 1 }
                else if thermal != .nominal { limit = min(limit, 2) }
                if limit > 2 && thermal != .nominal { limit = 2 }
                if now < memoryCriticalUntil { paused = "内存压力 critical" }
                if now < memoryWarningUntil { limit = 1 }
                if rss > 3072 { limit = 1 }
                if rss > 4096 {
                    log("常驻内存 \(Int(rss)) MB 超过 4GB，退出由守护脚本重启")
                    exit(75)
                }
                if FileManager.default.fileExists(atPath: controlDir.appendingPathComponent("pause").path) { paused = "用户暂停" }
                if let m = try? FileManager.default.attributesOfItem(atPath: controlDir.appendingPathComponent("reader-active").path)[.modificationDate] as? Date,
                   now.timeIntervalSince(m) < 8 { paused = paused ?? "让位给正在阅读的翻译" }
                if paused != pausedReason {
                    if let p = paused { log("暂停：\(p)") } else if pausedReason != nil { log("恢复运行") }
                    pausedReason = paused
                }
                effectiveLimit = paused == nil ? limit : 0
                await gate.setLimit(effectiveLimit)

                if now.timeIntervalSince(lastStatus) >= 5 {
                    lastStatus = now
                    await writeStatus(store: store, thermal: thermal, rss: rss, endAt: endAt, started: started)
                }
                if now.timeIntervalSince(lastLog) >= 600 {
                    lastLog = now
                    await logLine(thermal: thermal, rss: rss)
                }
                if stopReason != nil { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // 1) 热门度排名（只需一次，存进数据库）
        if store.rankCount < 1000 || opts.rerank {
            await stats.set(phase: "统计热门度")
            log("开始统计热门度（采样 \(opts.rankArticles) 篇核心文章的站内入链）…")
            let t0 = Date()
            let ranked = await Task.detached(priority: .utility) {
                PopularityRanker.rank(service: service, maxArticles: opts.rankArticles, keepTop: 200_000, shouldStop: { stopReason != nil }) { read, disc in
                    if read % 500 == 0 { log("  热门度：已读 \(read) 篇，发现 \(disc) 个条目", toFile: false) }
                }
            }.value
            if stopReason == nil || ranked.count > 1000 {
                store.saveRanking(ranked.map { (path: $0.path, title: $0.title, score: $0.score) })
                log("热门度排名完成：\(ranked.count) 个条目，用时 \(Int(Date().timeIntervalSince(t0))) 秒；前 10：\(ranked.prefix(10).map(\.title).joined(separator: ", "))")
            }
        } else {
            log("沿用已有热门度排名：\(store.rankCount) 个条目")
        }
        let rankTotal = store.rankCount
        let initial = store.coverage(titleTop: rankTotal, leadTop: rankTotal, fullTop: rankTotal)
        await stats.setCounts(titles: initial.titles, leads: initial.leads, full: initial.full)

        // 2) 分阶段：标题优先，再导语，最后少量全文；每一阶段都是"热门度前 N 名"
        let phases: [(name: String, kind: Int, upTo: Int)] = [
            ("标题 前 2 万", 0, 20_000),
            ("标题 前 8 万", 0, 80_000),
            ("导语 前 500", 1, 500),
            ("标题 全部排名", 0, rankTotal),
            ("导语 前 2000", 1, 2_000),
            ("导语 前 1 万", 1, 10_000),
            ("全文 前 200", 2, 200),
            ("导语 前 3 万", 1, 30_000),
            ("全文 前 1000", 2, 1_000),
        ]
        for ph in phases where stopReason == nil {
            let jobs = buildJobs(store: store, kind: ph.kind, upTo: min(ph.upTo, rankTotal))
            if jobs.isEmpty { continue }
            await stats.set(phase: ph.name)
            log("阶段开始：\(ph.name)（待处理 \(jobs.count) 批/篇）")
            let queue = JobQueue(jobs)
            await Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        let engine = makeEngine()
                        while stopReason == nil {
                            guard await gate.enter() else { return }
                            guard let job = await queue.next() else { await gate.leave(); return }
                            await run(job, engine: engine, service: service, store: store)
                            await gate.leave()
                        }
                    }
                }
            }
            }.value
            if stopReason == nil { log("阶段完成：\(ph.name)") }
        }

        monitor.cancel()
        let thermal = ProcessInfo.processInfo.thermalState
        await writeStatus(store: store, thermal: thermal, rss: residentMB(), endAt: endAt, started: started, finished: stopReason ?? "全部阶段完成")
        await logLine(thermal: thermal, rss: residentMB())
        log("结束：\(stopReason ?? "全部阶段完成")")
        exit(0)
    }

    /// 导语 / 全文层只翻"值得读"的条目：排除标识符与引用工具页、列表、年份日期、消歧义等
    static let identifierNames: Set<String> = ["ISBN", "ISSN", "Digital object identifier", "Wayback Machine", "PubMed", "PubMed Central",
        "Bibcode", "ArXiv", "OCLC", "JSTOR", "Semantic Scholar", "Library of Congress Control Number", "Virtual International Authority File",
        "Hdl (identifier)", "Doi (identifier)", "CiteSeerX", "Internet Archive", "Google Books", "WorldCat", "Integrated Authority File"]
    static func worthReading(_ t: String) -> Bool {
        if t.hasSuffix("(identifier)") || t.contains("(disambiguation)") || identifierNames.contains(t) { return false }
        if t.hasPrefix("Wikipedia:") || t.hasPrefix("Help:") || t.hasPrefix("Template:") || t.hasPrefix("Portal:") { return false }
        if t.hasPrefix("List of") || t.hasPrefix("Lists of") || t.hasPrefix("Index of") || t.hasPrefix("Timeline of") { return false }
        if t.range(of: #"^(\d{1,4}( BC| AD| BCE| CE)?|\d{1,4}s( BC)?|\d{1,2}(st|nd|rd|th) century( BC)?|(January|February|March|April|May|June|July|August|September|October|November|December)( \d{1,2})?|\d{4} in .+)$"#, options: .regularExpression) != nil { return false }
        return true
    }

    nonisolated static func makeEngine() -> RawTranslator { opts.fake ? FakeTranslator(delay: .milliseconds(15)) : AppleTranslator() }

    static func buildJobs(store: TranslationStore, kind: Int, upTo: Int) -> [Job] {
        let ranked = store.ranked(from: 0, to: upTo)
        switch kind {
        case 0:
            let have = store.titlesZh(for: ranked.map(\.path))
            let todo = ranked.filter { have[$0.path] == nil }.map { (path: $0.path, title: $0.title) }
            return stride(from: 0, to: todo.count, by: 40).map { .titles(Array(todo[$0..<min($0 + 40, todo.count)])) }
        case 1:
            return ranked.filter { worthReading($0.title) && store.jobLevel(for: $0.path) < 1 }.map { .lead(path: $0.path, title: $0.title) }
        default:
            return ranked.filter { worthReading($0.title) && store.jobLevel(for: $0.path) < 2 }.map { .full(path: $0.path, title: $0.title) }
        }
    }

    static func run(_ job: Job, engine: RawTranslator, service: ZimService, store: TranslationStore) async {
        switch job {
        case .titles(let items):
            await stats.set(current: items.first?.title ?? "")
            do {
                let r = try await engine.translate(items.map { (id: $0.path, text: $0.title) })
                let rows = items.compactMap { it in r[it.path].map { (path: it.path, en: it.title, zh: $0) } }
                store.setTitles(rows)
                await stats.incTitles(rows.count)
                await stats.add(words: items.reduce(0) { $0 + TranslationPipeline.wordCount($1.title) }, titles: rows.count)
            } catch {
                await stats.fail()
                log("标题批次失败：\(error.localizedDescription)", toFile: false)
                try? await Task.sleep(for: .seconds(3))
            }
        case .lead(let path, let title), .full(let path, let title):
            let isLead: Bool = { if case .lead = job { return true } else { return false } }()
            await stats.set(current: title)
            guard let res = service.content(path: path), res.isHTML else {
                store.setJob(path: path, level: isLead ? 1 : 2, units: 0, chars: 0)
                return
            }
            var units: [ExtractedUnit] = autoreleasepool {
                UnitExtractor.extract(rawHTML: String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title, path: res.path).units
            }
            if isLead { units = units.filter(\.inLead) }
            // 导语段控制体量：最多约 4000 字符（标题、简介、信息框标签、导语段落）
            if isLead {
                var acc = 0
                units = units.prefix { u in acc += u.text.count; return acc <= 4000 || u.order < 2 }
            }
            if isLead, units.reduce(0, { $0 + TranslationPipeline.wordCount($1.text) }) < 30 {
                store.setJob(path: res.path, level: 1, units: 0, chars: 0)   // 过短的小条目：跳过
                return
            }
            let have = store.translations(for: res.path)
            let todo = units.filter { have[$0.key] == nil }
            // 专名术语表（链接目标中文名 + 本条目自指）
            let allUnits = autoreleasepool { UnitExtractor.extract(rawHTML: String(decoding: res.data, as: UTF8.self), fallbackTitle: res.title, path: res.path).units }
            let prep = todo.isEmpty ? nil : await GlossaryBuilder.prepare(
                articlePath: res.path, articleTitle: title, links: allUnits.flatMap(\.links), texts: allUnits.map(\.text),
                service: service, store: store, engine: engine, maxNew: isLead ? 40 : 120)
            let glossary = prep?.glossary
            var i = 0
            var ok = true
            var unitsDone = 0, charsDone = 0
            while i < todo.count && stopReason == nil {
                // 小批次：≤8 段或 ≤1500 字符
                var batch: [ExtractedUnit] = []
                var chars = 0
                while i < todo.count, batch.isEmpty || (batch.count < 8 && chars + todo[i].text.count <= 1500) {
                    batch.append(todo[i]); chars += todo[i].text.count; i += 1
                }
                do {
                    let inputs = batch.map { PipelineInput(key: $0.key, text: $0.text, links: $0.links) }
                    let r = try await TranslationPipeline.translate(inputs, with: engine, glossary: glossary) { store.titleZh(for: $0) }
                    store.add(r.translations, for: res.path)
                    if let t = units.first(where: { $0.order == 0 }), let zh = r.translations[t.key], store.titleZh(for: res.path) == nil {
                        store.setTitles([(path: res.path, en: title, zh: zh)])
                    }
                    unitsDone += r.translations.count
                    charsDone += r.chars
                    await stats.add(words: r.words, titles: 0)
                    if !r.failedKeys.isEmpty { await stats.fail() }
                } catch {
                    ok = false
                    await stats.fail()
                    log("《\(title)》翻译失败：\(error.localizedDescription)", toFile: false)
                    try? await Task.sleep(for: .seconds(3))
                    break
                }
                // 让出：若被暂停/降并发，批次之间也检查一下
                if effectiveLimit == 0 { break }
            }
            if ok && i >= todo.count {
                store.setJob(path: res.path, level: isLead ? 1 : 2, units: unitsDone, chars: charsDone)
                if isLead { await stats.incLead() } else { await stats.incFull() }
            }
        }
    }

    static func writeStatus(store: TranslationStore, thermal: ProcessInfo.ThermalState, rss: Double, endAt: Date, started: Date, finished: String? = nil) async {
        let r = await stats.rates()
        let s = await (stats.titlesDone, stats.leadsDone, stats.fullDone, stats.phase, stats.current, stats.wordsTotal, stats.failures)
        let dict: [String: Any] = [
            "pid": Int(getpid()),
            "updated": Date().timeIntervalSince1970,
            "started": started.timeIntervalSince1970,
            "deadline": endAt.timeIntervalSince1970,
            "running": finished == nil,
            "finished": finished ?? NSNull(),
            "paused": pausedReason ?? NSNull(),
            "phase": s.3,
            "current": s.4,
            "titlesDone": s.0,
            "leadsDone": s.1,
            "fullDone": s.2,
            "rankTotal": store.rankCount,
            "wordsPerSec": r.wordsPerSec,
            "titlesPerSec": r.titlesPerSec,
            "wordsSession": s.5,
            "failures": s.6,
            "thermal": thermalName(thermal),
            "rssMB": rss,
            "concurrency": effectiveLimit,
            "fake": opts.fake,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: statusURL, options: .atomic)
        }
    }

    static func logLine(thermal: ProcessInfo.ThermalState, rss: Double) async {
        let r = await stats.rates()
        let s = await (stats.titlesDone, stats.leadsDone, stats.fullDone, stats.phase, stats.failures)
        log(String(format: "进度｜阶段：%@｜标题 %d｜导语 %d 篇｜全文 %d 篇｜速度 %.0f 词/秒、%.1f 标题/秒｜温度 %@｜内存 %.0f MB｜并发 %d｜失败 %d｜%@",
                   s.3, s.0, s.1, s.2, r.wordsPerSec, r.titlesPerSec, thermalName(thermal), rss, effectiveLimit, s.4,
                   pausedReason.map { "暂停中：\($0)" } ?? "运行中"))
    }
}
