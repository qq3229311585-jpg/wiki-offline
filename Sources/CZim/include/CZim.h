// CZim —— libzim 的 Objective-C 薄封装，供 Swift 调用。
// 头文件只包含 Objective-C，C++ 细节全部藏在 .mm 里。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 条目的基本信息（已解析重定向后的真实路径 + 标题）。
@interface ZimEntryInfo : NSObject
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSString *title;
/// 搜索结果摘要（全文搜索时可能有，可能含 <b> 标签）
@property (nonatomic, copy, readonly, nullable) NSString *snippet;
/// 请求的原始路径若是重定向，这里记录原路径
@property (nonatomic, copy, readonly, nullable) NSString *redirectedFrom;
- (instancetype)initWithPath:(NSString *)path
                       title:(NSString *)title
                     snippet:(nullable NSString *)snippet
              redirectedFrom:(nullable NSString *)redirectedFrom;
@end

/// 条目内容。
@interface ZimContent : NSObject
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *mimeType;
@property (nonatomic, strong, readonly) NSData *data;
@property (nonatomic, readonly) BOOL wasRedirect;
@end

/// 一个打开的 ZIM 档案。内容读取可多线程并发；搜索在内部串行化。
@interface ZimArchive : NSObject

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;

/// libzim 全局簇缓存（解压后的 cluster）上限，字节
+ (void)setClusterCacheMaxSize:(size_t)bytes;
+ (size_t)clusterCacheMaxSize;
+ (size_t)clusterCacheCurrentSize;
/// 本档案的目录项缓存条数上限
- (void)setDirentCacheMaxSize:(size_t)count;

@property (nonatomic, copy, readonly) NSString *filePath;
@property (nonatomic, copy, readonly) NSString *uuid;
@property (nonatomic, readonly) uint32_t articleCount;
@property (nonatomic, readonly) uint32_t allEntryCount;
@property (nonatomic, readonly) uint64_t fileSize;
@property (nonatomic, readonly) BOOL hasFulltextIndex;
@property (nonatomic, readonly) BOOL hasTitleIndex;
@property (nonatomic, readonly) BOOL hasNewNamespaceScheme;

- (nullable NSString *)metadataForKey:(NSString *)key;
- (NSArray<NSString *> *)metadataKeys;
- (nullable NSData *)illustrationPNGWithSize:(unsigned int)size;

/// 首页（已解析重定向）
- (nullable ZimEntryInfo *)mainEntry;
/// 随机正文条目（HTML，已解析重定向）
- (nullable ZimEntryInfo *)randomArticle;
/// 按标题序号取正文条目（用于"今日推荐"的确定性取样），非 HTML 返回 nil
- (nullable ZimEntryInfo *)articleAtTitleIndex:(uint32_t)index;

/// 解析路径（跟随重定向）。不存在返回 nil。
- (nullable ZimEntryInfo *)entryForPath:(NSString *)path;
/// 解析路径并要求最终是 HTML 文章（跟随重定向）。
- (nullable ZimEntryInfo *)articleForPath:(NSString *)path;
/// 按精确标题查找
- (nullable ZimEntryInfo *)entryForTitle:(NSString *)title;
/// 读取内容（跟随重定向）。不存在返回 nil。
- (nullable ZimContent *)contentForPath:(NSString *)path;

/// 标题建议搜索（Xapian 标题索引；没有索引时 libzim 退化为前缀匹配）
- (NSArray<ZimEntryInfo *> *)suggestionsForQuery:(NSString *)query limit:(NSInteger)limit;
/// 全文搜索；没有全文索引时返回空数组
- (NSArray<ZimEntryInfo *> *)searchFulltext:(NSString *)query
                                      limit:(NSInteger)limit
                             estimatedTotal:(nullable NSInteger *)estimatedTotal;

@end

NS_ASSUME_NONNULL_END
