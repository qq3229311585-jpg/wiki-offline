// CZim —— libzim 的 Objective-C++ 实现。所有 C++ 异常都在这里截住，Swift 侧只见 nil / 空数组。
#import "CZim.h"

#include <zim/archive.h>
#include <zim/entry.h>
#include <zim/item.h>
#include <zim/search.h>
#include <zim/suggestion.h>
#include <zim/error.h>

#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>

static NSString *ZStr(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

static std::string CStr(NSString *s) {
    const char *u = s.UTF8String;
    return u ? std::string(u) : std::string();
}

static BOOL IsHTML(const std::string &mime) {
    return mime.rfind("text/html", 0) == 0;
}

#pragma mark - ZimEntryInfo

@implementation ZimEntryInfo
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title snippet:(NSString *)snippet redirectedFrom:(NSString *)redirectedFrom {
    if ((self = [super init])) {
        _path = [path copy];
        _title = [title copy];
        _snippet = [snippet copy];
        _redirectedFrom = [redirectedFrom copy];
    }
    return self;
}
- (NSString *)description { return [NSString stringWithFormat:@"<ZimEntryInfo %@ | %@>", _path, _title]; }
@end

#pragma mark - ZimContent

@interface ZimContent ()
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title mimeType:(NSString *)mime data:(NSData *)data wasRedirect:(BOOL)wasRedirect;
@end

@implementation ZimContent
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title mimeType:(NSString *)mime data:(NSData *)data wasRedirect:(BOOL)wasRedirect {
    if ((self = [super init])) {
        _path = [path copy];
        _title = [title copy];
        _mimeType = [mime copy];
        _data = data;
        _wasRedirect = wasRedirect;
    }
    return self;
}
@end

#pragma mark - ZimArchive

@implementation ZimArchive {
    std::unique_ptr<zim::Archive> _archive;
    std::unique_ptr<zim::SuggestionSearcher> _suggester;
    std::unique_ptr<zim::Searcher> _searcher;
    std::mutex _suggestMutex;
    std::mutex _searchMutex;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        try {
            _archive = std::make_unique<zim::Archive>(CStr(path));
            _filePath = [path copy];
            _uuid = ZStr(static_cast<std::string>(_archive->getUuid()));
        } catch (const std::exception &e) {
            if (error) {
                *error = [NSError errorWithDomain:@"CZim" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法打开 ZIM 文件：%s", e.what()]}];
            }
            return nil;
        } catch (...) {
            if (error) {
                *error = [NSError errorWithDomain:@"CZim" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法打开 ZIM 文件（未知错误）"}];
            }
            return nil;
        }
    }
    return self;
}

+ (void)setClusterCacheMaxSize:(size_t)bytes { try { zim::setClusterCacheMaxSize(bytes); } catch (...) {} }
+ (size_t)clusterCacheMaxSize { try { return zim::getClusterCacheMaxSize(); } catch (...) { return 0; } }
+ (size_t)clusterCacheCurrentSize { try { return zim::getClusterCacheCurrentSize(); } catch (...) { return 0; } }
- (void)setDirentCacheMaxSize:(size_t)count { try { _archive->setDirentCacheMaxSize(count); } catch (...) {} }

- (uint32_t)articleCount { try { return _archive->getArticleCount(); } catch (...) { return 0; } }
- (uint32_t)allEntryCount { try { return _archive->getAllEntryCount(); } catch (...) { return 0; } }
- (uint64_t)fileSize { try { return _archive->getFilesize(); } catch (...) { return 0; } }
- (BOOL)hasFulltextIndex { try { return _archive->hasFulltextIndex(); } catch (...) { return NO; } }
- (BOOL)hasTitleIndex { try { return _archive->hasTitleIndex(); } catch (...) { return NO; } }
- (BOOL)hasNewNamespaceScheme { try { return _archive->hasNewNamespaceScheme(); } catch (...) { return NO; } }

- (nullable NSString *)metadataForKey:(NSString *)key {
    try {
        return ZStr(_archive->getMetadata(CStr(key)));
    } catch (...) {
        return nil;
    }
}

- (NSArray<NSString *> *)metadataKeys {
    NSMutableArray *a = [NSMutableArray array];
    try {
        for (const auto &k : _archive->getMetadataKeys()) [a addObject:ZStr(k)];
    } catch (...) {}
    return a;
}

- (nullable NSData *)illustrationPNGWithSize:(unsigned int)size {
    try {
        if (!_archive->hasIllustration(size)) return nil;
        auto item = _archive->getIllustrationItem(size);
        auto blob = item.getData();
        return [NSData dataWithBytes:blob.data() length:blob.size()];
    } catch (...) {
        return nil;
    }
}

/// 解析一个 entry：跟随重定向，返回最终条目信息。非 HTML 时 requireHTML 为真则返回 nil。
- (nullable ZimEntryInfo *)infoForEntry:(const zim::Entry &)entry requireHTML:(BOOL)requireHTML {
    try {
        NSString *from = nil;
        zim::Item item = entry.getItem(true);
        if (entry.isRedirect()) from = ZStr(entry.getTitle());
        if (requireHTML && !IsHTML(item.getMimetype())) return nil;
        return [[ZimEntryInfo alloc] initWithPath:ZStr(item.getPath()) title:ZStr(item.getTitle()) snippet:nil redirectedFrom:from];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimEntryInfo *)mainEntry {
    try {
        if (!_archive->hasMainEntry()) return nil;
        return [self infoForEntry:_archive->getMainEntry() requireHTML:NO];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimEntryInfo *)randomArticle {
    for (int i = 0; i < 24; i++) {
        try {
            ZimEntryInfo *info = [self infoForEntry:_archive->getRandomEntry() requireHTML:YES];
            if (info) return info;
        } catch (...) {}
    }
    return nil;
}

- (nullable ZimEntryInfo *)articleAtTitleIndex:(uint32_t)index {
    try {
        return [self infoForEntry:_archive->getEntryByTitle((zim::entry_index_type)index) requireHTML:YES];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimEntryInfo *)entryForPath:(NSString *)path {
    try {
        return [self infoForEntry:_archive->getEntryByPath(CStr(path)) requireHTML:NO];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimEntryInfo *)articleForPath:(NSString *)path {
    try {
        return [self infoForEntry:_archive->getEntryByPath(CStr(path)) requireHTML:YES];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimEntryInfo *)entryForTitle:(NSString *)title {
    try {
        return [self infoForEntry:_archive->getEntryByTitle(CStr(title)) requireHTML:NO];
    } catch (...) {
        return nil;
    }
}

- (nullable ZimContent *)contentForPath:(NSString *)path {
    try {
        zim::Entry entry = _archive->getEntryByPath(CStr(path));
        zim::Item item = entry.getItem(true);
        zim::Blob blob = item.getData();
        NSData *data = [NSData dataWithBytes:blob.data() length:blob.size()];
        return [[ZimContent alloc] initWithPath:ZStr(item.getPath())
                                          title:ZStr(item.getTitle())
                                       mimeType:ZStr(item.getMimetype())
                                           data:data
                                    wasRedirect:entry.isRedirect()];
    } catch (...) {
        return nil;
    }
}

- (NSArray<ZimEntryInfo *> *)suggestionsForQuery:(NSString *)query limit:(NSInteger)limit {
    NSMutableArray<ZimEntryInfo *> *out = [NSMutableArray array];
    std::string q = CStr(query);
    if (q.empty() || limit <= 0) return out;
    std::lock_guard<std::mutex> lock(_suggestMutex);
    try {
        if (!_suggester) _suggester = std::make_unique<zim::SuggestionSearcher>(*_archive);
        auto search = _suggester->suggest(q);
        // 多取一些，去掉指向同一篇文章的重定向重复项
        auto results = search.getResults(0, (int)limit * 2);
        std::unordered_set<std::string> seen;
        for (auto it = results.begin(); it != results.end(); ++it) {
            if ((NSInteger)out.count >= limit) break;
            try {
                zim::Entry entry = it.getEntry();
                zim::Item item = entry.getItem(true);
                if (!IsHTML(item.getMimetype())) continue;
                std::string target = item.getPath();
                if (seen.count(target)) continue;
                seen.insert(target);
                NSString *from = entry.isRedirect() ? ZStr(entry.getTitle()) : nil;
                NSString *snippet = it->hasSnippet() ? ZStr(it->getSnippet()) : nil;
                [out addObject:[[ZimEntryInfo alloc] initWithPath:ZStr(target) title:ZStr(item.getTitle()) snippet:snippet redirectedFrom:from]];
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        _suggester.reset();
    }
    return out;
}

- (NSArray<ZimEntryInfo *> *)searchFulltext:(NSString *)query limit:(NSInteger)limit estimatedTotal:(NSInteger *)estimatedTotal {
    NSMutableArray<ZimEntryInfo *> *out = [NSMutableArray array];
    if (estimatedTotal) *estimatedTotal = 0;
    std::string q = CStr(query);
    if (q.empty() || limit <= 0) return out;
    std::lock_guard<std::mutex> lock(_searchMutex);
    try {
        if (!_archive->hasFulltextIndex()) return out;
        if (!_searcher) _searcher = std::make_unique<zim::Searcher>(*_archive);
        zim::Query zq(q);
        auto search = _searcher->search(zq);
        if (estimatedTotal) *estimatedTotal = search.getEstimatedMatches();
        auto results = search.getResults(0, (int)limit);
        for (auto it = results.begin(); it != results.end(); ++it) {
            try {
                NSString *snippet = ZStr(it.getSnippet());
                [out addObject:[[ZimEntryInfo alloc] initWithPath:ZStr(it.getPath()) title:ZStr(it.getTitle()) snippet:snippet redirectedFrom:nil]];
            } catch (...) {
                continue;
            }
        }
    } catch (...) {
        _searcher.reset();
    }
    return out;
}

@end
