import Foundation
import SQLite3

/// 译文持久化（SQLite，WAL）。原文始终来自 ZIM，这里只存译文，ZIM 不做任何修改。
///
/// 表：
///   unit(path, key, zh)        按文章分块的段落译文（阅读实时翻译与预翻译共用）
///   title(path, en, zh)        标题译文（中文搜索、中文标题列表）
///   rank(ord, path, title, score)  热门度排名（站内入链数）
///   job(path, level, units, chars, updated)  预翻译进度：level 1=导语完成 2=全文完成
///   meta(k, v)                 杂项（排名是否已建、累计统计等）
///
/// 所有方法线程安全（内部串行队列），可在任意线程调用。
public final class TranslationStore: @unchecked Sendable {
    public let url: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "wiki.translation-store")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        AppPaths.ensure(url.deletingLastPathComponent())
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "TranslationStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "无法打开译文数据库"])
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS unit(path TEXT NOT NULL, key TEXT NOT NULL, zh TEXT NOT NULL, PRIMARY KEY(path, key)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS title(path TEXT PRIMARY KEY, en TEXT NOT NULL, zh TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS rank(ord INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL, score INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS job(path TEXT PRIMARY KEY, level INTEGER NOT NULL, units INTEGER NOT NULL DEFAULT 0, chars INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL DEFAULT 0) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// 某个 ZIM 对应的数据库位置
    public static func defaultURL(forArchiveUUID uuid: String) -> URL {
        AppPaths.supportDirectory.appendingPathComponent("Translations/\(uuid).sqlite")
    }

    // MARK: 段落译文

    public func translations(for path: String) -> [String: String] {
        queue.sync {
            var out: [String: String] = [:]
            query("SELECT key, zh FROM unit WHERE path = ?", [path]) { st in
                out[col(st, 0)] = col(st, 1)
            }
            return out
        }
    }

    /// 在线版：给旧译文加上 "legacy:" 前缀收起来（只做一次，不删除）。
    /// 旧译文没有记录是哪个引擎翻的（混着云端与本机），收起后"本机"和"DeepSeek"两份缓存都从干净状态开始。
    public func archiveLegacyUnitsOnce() {
        guard meta("unit-ns-v1") == nil else { return }
        queue.sync {
            _ = try? exec("UPDATE unit SET path = 'legacy:' || path WHERE path NOT LIKE 'ds:%' AND path NOT LIKE 'ds-pro:%' AND path NOT LIKE 'legacy:%';")
        }
        setMeta("unit-ns-v1", "1")
    }

    /// 清掉某一篇文章的全部段落译文（"重新翻译本篇"用）
    public func clearTranslations(for path: String) {
        queue.sync {
            transaction {
                let st = prepare("DELETE FROM unit WHERE path = ?")
                defer { sqlite3_finalize(st) }
                bind(st, [path])
                sqlite3_step(st)
            }
        }
    }

    public func add(_ entries: [String: String], for path: String) {
        guard !entries.isEmpty else { return }
        queue.sync {
            transaction {
                let st = prepare("INSERT OR REPLACE INTO unit(path, key, zh) VALUES(?, ?, ?)")
                defer { sqlite3_finalize(st) }
                for (k, v) in entries {
                    bind(st, [path, k, v])
                    sqlite3_step(st)
                    sqlite3_reset(st)
                }
            }
        }
    }

    public func unitCount(for path: String) -> Int {
        queue.sync { scalarInt("SELECT COUNT(*) FROM unit WHERE path = ?", [path]) }
    }

    // MARK: 标题译文

    public func titleZh(for path: String) -> String? {
        queue.sync {
            var r: String?
            query("SELECT zh FROM title WHERE path = ?", [path]) { r = col($0, 0) }
            return r
        }
    }

    public func titlesZh(for paths: [String]) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        return queue.sync {
            var out: [String: String] = [:]
            let st = prepare("SELECT zh FROM title WHERE path = ?")
            defer { sqlite3_finalize(st) }
            for p in paths {
                bind(st, [p])
                if sqlite3_step(st) == SQLITE_ROW { out[p] = col(st, 0) }
                sqlite3_reset(st)
            }
            return out
        }
    }

    public func setTitles(_ items: [(path: String, en: String, zh: String)]) {
        guard !items.isEmpty else { return }
        queue.sync {
            transaction {
                let st = prepare("INSERT OR REPLACE INTO title(path, en, zh) VALUES(?, ?, ?)")
                defer { sqlite3_finalize(st) }
                for it in items {
                    bind(st, [it.path, it.en, it.zh])
                    sqlite3_step(st)
                    sqlite3_reset(st)
                }
            }
        }
    }

    /// 中文标题搜索（子串匹配，按排名优先）
    public func searchChineseTitles(_ q: String, limit: Int = 20) -> [(path: String, en: String, zh: String)] {
        let needle = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return queue.sync {
            var out: [(String, String, String)] = []
            let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            query("""
            SELECT t.path, t.en, t.zh FROM title t LEFT JOIN rank r ON r.path = t.path
            WHERE t.zh LIKE ? ESCAPE '\\'
            ORDER BY (t.zh = ?) DESC, (t.zh LIKE ? ESCAPE '\\') DESC, COALESCE(r.ord, 9999999), length(t.zh)
            LIMIT ?
            """, ["%\(escaped)%", needle, "\(escaped)%", limit]) { st in
                out.append((col(st, 0), col(st, 1), col(st, 2)))
            }
            return out.map { (path: $0.0, en: $0.1, zh: $0.2) }
        }
    }

    // MARK: 排名

    public var rankCount: Int { queue.sync { scalarInt("SELECT COUNT(*) FROM rank", []) } }

    public func saveRanking(_ items: [(path: String, title: String, score: Int)]) {
        queue.sync {
            transaction {
                _ = try? exec("DELETE FROM rank")
                let st = prepare("INSERT OR IGNORE INTO rank(ord, path, title, score) VALUES(?, ?, ?, ?)")
                defer { sqlite3_finalize(st) }
                for (i, it) in items.enumerated() {
                    bind(st, [i, it.path, it.title, it.score])
                    sqlite3_step(st)
                    sqlite3_reset(st)
                }
            }
        }
    }

    /// 一批条目的热门名次（ord 越小越热门）；不在排名里的条目不会出现在结果中
    public func rankScores(for paths: [String]) -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        queue.sync {
            let marks = Array(repeating: "?", count: paths.count).joined(separator: ",")
            query("SELECT path, ord FROM rank WHERE path IN (\(marks))", paths) { st in
                out[col(st, 0)] = Int(sqlite3_column_int64(st, 1))
            }
        }
        return out
    }

    /// 排名切片 [from, to)
    public func ranked(from: Int, to: Int) -> [(path: String, title: String, score: Int)] {
        queue.sync {
            var out: [(String, String, Int)] = []
            query("SELECT path, title, score FROM rank WHERE ord >= ? AND ord < ? ORDER BY ord", [from, to]) { st in
                out.append((col(st, 0), col(st, 1), Int(sqlite3_column_int64(st, 2))))
            }
            return out.map { (path: $0.0, title: $0.1, score: $0.2) }
        }
    }

    // MARK: 预翻译进度

    public func jobLevel(for path: String) -> Int {
        queue.sync { scalarInt("SELECT level FROM job WHERE path = ?", [path]) }
    }

    public func setJob(path: String, level: Int, units: Int, chars: Int) {
        queue.sync {
            let st = prepare("""
            INSERT INTO job(path, level, units, chars, updated) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET level = max(level, excluded.level), units = excluded.units + units, chars = excluded.chars + chars, updated = excluded.updated
            """)
            defer { sqlite3_finalize(st) }
            bind(st, [path, level, units, chars, Date().timeIntervalSince1970])
            sqlite3_step(st)
        }
    }

    public struct Coverage: Sendable, Equatable {
        public var titles = 0
        public var leads = 0
        public var full = 0
        public var units = 0
        public var articlesWithUnits = 0
        public var ranked = 0
    }

    /// 已排名范围内的覆盖统计（只统计前 n 名）
    public func coverage(titleTop: Int, leadTop: Int, fullTop: Int) -> Coverage {
        queue.sync {
            var c = Coverage()
            c.ranked = scalarInt("SELECT COUNT(*) FROM rank", [])
            c.titles = scalarInt("SELECT COUNT(*) FROM rank r JOIN title t ON t.path = r.path WHERE r.ord < ?", [titleTop])
            c.leads = scalarInt("SELECT COUNT(*) FROM rank r JOIN job j ON j.path = r.path WHERE r.ord < ? AND j.level >= 1", [leadTop])
            c.full = scalarInt("SELECT COUNT(*) FROM rank r JOIN job j ON j.path = r.path WHERE r.ord < ? AND j.level >= 2", [fullTop])
            c.units = scalarInt("SELECT COUNT(*) FROM unit", [])
            c.articlesWithUnits = scalarInt("SELECT COUNT(DISTINCT path) FROM unit", [])
            return c
        }
    }

    /// 全局统计（不限排名）
    public func totals() -> (titles: Int, units: Int, articles: Int, leadJobs: Int, fullJobs: Int) {
        queue.sync {
            (scalarInt("SELECT COUNT(*) FROM title", []),
             scalarInt("SELECT COUNT(*) FROM unit", []),
             scalarInt("SELECT COUNT(DISTINCT path) FROM unit", []),
             scalarInt("SELECT COUNT(*) FROM job WHERE level >= 1", []),
             scalarInt("SELECT COUNT(*) FROM job WHERE level >= 2", []))
        }
    }

    // MARK: meta

    public func meta(_ k: String) -> String? {
        queue.sync {
            var r: String?
            query("SELECT v FROM meta WHERE k = ?", [k]) { r = col($0, 0) }
            return r
        }
    }

    public func setMeta(_ k: String, _ v: String) {
        queue.sync {
            let st = prepare("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)")
            defer { sqlite3_finalize(st) }
            bind(st, [k, v])
            sqlite3_step(st)
        }
    }

    /// 清空全部译文（保留排名）
    public func clearTranslations() {
        queue.sync {
            _ = try? exec("DELETE FROM unit; DELETE FROM title; DELETE FROM job;")
            _ = try? exec("VACUUM;")
        }
    }

    public var fileSize: Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            total += (try? fm.attributesOfItem(atPath: url.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    // MARK: SQLite 小工具（只在 queue 上调用）

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "TranslationStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return st
    }

    private func bind(_ st: OpaquePointer?, _ values: [Any]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(st, idx, s, -1, Self.SQLITE_TRANSIENT)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(st, idx, d)
            default: sqlite3_bind_null(st, idx)
            }
        }
    }

    private func query(_ sql: String, _ values: [Any], _ row: (OpaquePointer?) -> Void) {
        let st = prepare(sql)
        defer { sqlite3_finalize(st) }
        bind(st, values)
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func scalarInt(_ sql: String, _ values: [Any]) -> Int {
        var r = 0
        query(sql, values) { r = Int(sqlite3_column_int64($0, 0)) }
        return r
    }

    private func col(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
}
