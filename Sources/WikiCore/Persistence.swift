import Foundation

/// App 数据目录：~/Library/Application Support/WikiOffline
public enum AppPaths {
    public static var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WikiOffline", isDirectory: true)
    }()

    public static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// 简单的 Codable JSON 文件读写（原子写入）
public struct JSONFile<T: Codable> {
    public let url: URL
    public init(_ url: URL) { self.url = url }

    public func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    public func save(_ value: T) {
        AppPaths.ensure(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 历史记录条目
public struct HistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var title: String
    public var titleZh: String?
    public var date: Date
    public var id: String { path + "@" + String(date.timeIntervalSince1970) }
    public init(path: String, title: String, titleZh: String? = nil, date: Date = Date()) {
        self.path = path
        self.title = title
        self.titleZh = titleZh
        self.date = date
    }
}

/// 收藏条目
public struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var title: String
    public var titleZh: String?
    public var added: Date
    public var id: String { path }
    public init(path: String, title: String, titleZh: String? = nil, added: Date = Date()) {
        self.path = path
        self.title = title
        self.titleZh = titleZh
        self.added = added
    }
}

/// 历史记录的纯逻辑：去重（同一文章只保留最近一次）、限长
public enum HistoryLogic {
    public static func record(_ item: HistoryItem, into list: [HistoryItem], limit: Int = 1000) -> [HistoryItem] {
        var l = list.filter { $0.path != item.path }
        l.insert(item, at: 0)
        if l.count > limit { l.removeLast(l.count - limit) }
        return l
    }
}

/// 找到 ZIM 文件，并判断它是否仍在下载（aria2 控制文件存在 → 不能打开）
public enum ZimLocator {
    public static let defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/维基百科离线", isDirectory: true)
    public static let defaultFileName = "wikipedia_en_top1m_nopic_2026-04.zim"

    public enum State: Equatable {
        case ready(URL)
        case downloading(URL, bytes: Int64)
        case missing
    }

    public static func isDownloading(_ url: URL) -> Bool {
        let fm = FileManager.default
        let p = url.path
        return fm.fileExists(atPath: p + ".aria2") || fm.fileExists(atPath: p + ".part")
            || fm.fileExists(atPath: p + ".crdownload") || fm.fileExists(atPath: p + ".download")
    }

    public static func state(for url: URL) -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || isDownloading(url) else { return .missing }
        if isDownloading(url) {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return .downloading(url, bytes: size)
        }
        return .ready(url)
    }

    /// 按优先级：用户设置的路径 → 默认路径 → 默认目录下任意 .zim
    public static func locate(preferred: String?) -> State {
        if let preferred, !preferred.isEmpty {
            let s = state(for: URL(fileURLWithPath: preferred))
            if s != .missing { return s }
        }
        let def = defaultDirectory.appendingPathComponent(defaultFileName)
        let s = state(for: def)
        if s != .missing { return s }
        if let items = try? FileManager.default.contentsOfDirectory(at: defaultDirectory, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension.lowercased() == "zim" {
                let st = state(for: u)
                if case .ready = st { return st }
            }
            for u in items where u.pathExtension.lowercased() == "zim" { return state(for: u) }
        }
        return .missing
    }
}
