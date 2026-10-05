# 维基离线（WikiOffline）

macOS 原生**离线英文维基百科阅读器**：读 Kiwix 的 ZIM 离线包，阅读时用 **Apple 端侧翻译**（Translation 框架）把英文实时译成中文。全程不联网。

## 特点

- **完全离线**：正文通过自定义 `wiki://` 协议提供，并加了三道防线（内容安全策略、WKContentRuleList、导航拦截），运行时零外网请求
- **端侧翻译**：边读边翻，可见区优先，译文淡入（错峰浮现）；译文与标题缓存到 SQLite，重读秒开
- **杂志风排版**：中文 / English / 对照三态；中文按 clreq 处理（中西文间距、标点挤压、悬挂标点、全角引号）；开篇两栏（正文填满左侧、信息框独立右栏）；`Aa` 面板可调字号 / 行距 / 字体 / 版面宽度 / 对照版式 / 主题，全部持久化
- **阅读导航**：章节浮层（第 n 节 · 共 m 节、上一节/下一节 ⌥↑⌥↓）、窗口底部阅读进度线、浏览器式的返回/前进（记录"看过哪个界面"）
- **搜索**：中文查询自动反向翻译成英文再检索；先查中文标题库 + 标题建议（按站内热门度排序）+ 全文搜索；结果里的英文标题会用本机翻译补成中文
- **参考资料也翻译**，可做中英对照

## 环境要求

- macOS 26+、Xcode 26+（Swift 6）
- Homebrew 的 `libzim`、`xapian`（构建时链接；打包时会把依赖 dylib 拷进 App，运行时不再依赖 Homebrew）
- 一份 Kiwix 英文维基 ZIM（例如 `wikipedia_en_top1m_nopic_2026-04.zim`）
- 系统「翻译语言包」：英语 + 简体中文（首次由系统弹窗确认下载，之后离线可用）

## 构建与运行

```bash
./build.sh            # 构建到 ../.staging/，并校验签名与"不再依赖 /opt/homebrew"
./build.sh install    # 旧版移入 backups/，替换 ../维基离线.app
swift test            # 单元测试
```

命令行验证工具（不需要界面）：

```bash
swift run -c release wikitool info       <zim>
swift run -c release wikitool units      <zim> <path>     # 分段与单元
swift run -c release wikitool page       <zim> <path> Resources   # 导出成品 HTML
swift run -c release wikitool linkcheck  <zim> <path>     # 译文里能挂上链接的比例
swift run -c release wikitool searchcheck <zim> <query>   # 复刻整条搜索链路
swift run -c release wikitool illustration <zim> <out.png> [maxSize]
```

## 目录

| 路径 | 作用 |
|---|---|
| `Sources/CZim` | libzim 的 ObjC++ 薄桥 |
| `Sources/WikiCore` | 纯逻辑：HTML 清洗、分段、翻译管线、术语表、SQLite 存储、页面模板（可单测） |
| `Sources/WikiOffline` | SwiftUI 界面 + WKWebView 阅读器 |
| `Sources/wikitool` | 命令行验证工具 |
| `Sources/wikipretranslate` | 预翻译 worker（已停用，保留代码） |
| `Resources/reader.css` `reader.js` | 阅读页排版与脚本（翻译单元 `.u > .en/.tr`） |
| `Tests/WikiCoreTests` | 单元测试 |
| `HANDOFF.md` `NOTES.md` | 交接文档与工作笔记（中文，含设计决策与已验证/未验证清单） |

## 注意

- 离线数据（`.zim`，十几 GB）与构建产物、旧版备份都不入库，见 `.gitignore`
- 翻译完全由 macOS 端侧完成，App 不发起任何网络请求
- **图标**：仓库里默认的图标取自 ZIM 元数据，是 Wikimedia Foundation 的商标；对外发布请换成自己的图标（`Resources/AppIcon-source.png` 换掉后 `./build.sh` 会自动生成 icns）
- 签名是 ad-hoc：本机自用没问题，拷到别的 Mac 首次需右键打开
- **许可证**：代码用 MIT（见 `LICENSE`）。注意依赖 `libzim`（GPLv3）与 `xapian`（GPLv2+）：自己用不受影响，**把打包好的 App 分发给别人时需一并提供源码**（本仓库即是源码）
