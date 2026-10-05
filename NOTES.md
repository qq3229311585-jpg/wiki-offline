# 维基离线 · 工作笔记
- 构建：`./build.sh`（暂存 ../.staging/）→ `./build.sh install`（旧版移入 backups/，替换 ../维基离线.app）；启动 `open ../维基离线.app`
- 结构：CZim(ObjC++ libzim 桥) / WikiCore(清洗 HTMLCleaner、分段 UnitExtractor、翻译管线 TranslationPipeline+Glossary、存储 TranslationStore SQLite) / WikiOffline(SwiftUI) / wikitool(验证 CLI) / wikipretranslate
- 页面：Resources/reader.css + reader.js（翻译单元 .u > .en/.tr；html[data-mode]=original|translated|bilingual；data-theme / data-font / data-width / data-bi）
- 视觉：杂志风；纸色 #F6F1E7 / 炭 #23211E（夜间 #1B1915 / #EDE7DA）；朱红 #C0392B（夜间提亮 #E0685A）；New York + Songti SC + PingFang SC
- 浮层：书架 ⌘B（左）、章节导航 ⌘T/右缘悬停（右）、搜索 ⌘K/⌘L、排版 Aa（⌘⇧A，含字号/行距/字体/宽度/对照/主题）
- 翻译：现场翻译（可见区优先）；术语表只预替换本条目自指、其余译后"中文（English）"；繁→简；缓存 SQLite（Translations/<uuid>.sqlite）
- 参考资料（references/reflist）现在也参与翻译（做成双语）；导航框/公式/目录仍排除

## 设计决策（调研后）
1. 行宽按模式且以 em 计：中文 44em，英文 40em；窄/标准/宽/满宽 四档；min(92vw, …)
2. 中西文间距 `text-autospace: normal` + `text-spacing-trim: space-first`（新引擎），旧引擎走 .pc 兜底
3. 标点挤压：JS 给相邻全角标点的前者加 `.pc`（letter-spacing:-.5em）
4. 行末标点悬挂 `hanging-punctuation: allow-end last`；`line-break: strict`；中文两端对齐
5. 引号：译文直引号 → “ ”（仅当引号内含中文才转，避免破坏英文撇号）；CJK 旁半角括号 → 全角
6. 英文：`hyphens:auto`；旧式数字；导语首行小型大写 + 首字下沉
7. 对照：英文 .82em 淡色在上、中文主字号在下、中间朱红细线；可选并排（data-bi=side，窄窗自动退回上下）
8. 标题尺度阶梯：h1 ×2.5、h2 ×1.5、h3 ×1.2；分隔线 12% 透明、圆角 3px、阴影克制（调研结论）
9. 开篇两栏：reader.js 把「信息框 + 第一个章节标题之前的内容」包成 `.lead-cols`，信息框固定在右栏（grid），文字填满左侧；**第一个章节标题之后恢复整幅宽度**（比原来的 float 稳：float 在应用里会出现左侧空白）
10. 深色纸感：正文对比度 ≈14.8:1，朱红 ≈5.5:1（WCAG AA）

## 本轮（2026-10-05 02:20–03:10）做了什么
- **Aa 排版面板**（新文件 TypePanel.swift，顶栏 Aa 按钮 + ⌘⇧A + 菜单）：字号/行距/字体(宋体·混排·黑体)/版面宽度(窄·标准·宽·满宽)/对照(上下·并排)/主题，全部持久化；`ReaderStyle` 扩展并输出 data-font/data-width/data-bi/--lhs
- **章节导航**：面板高度按条目数计算并受窗口高度限制（不再 fixedSize 撑高被居中）、显示「第 n 节 · 共 m 节」、底部「上一节 ⌥↑ / 下一节 ⌥↓」；菜单同名项
- **阅读进度细线**：窗口底部 2px 朱红线（滚动实时更新）
- **焦点框**：全局 `.focusEffectDisabled()`
- **排版细节**：JS 标点挤压 `.pc`、引号/括号规整、相邻标点去重；深色配色改为暖色纸感深底；圆角 6→3
- **中文模式链接**：linkify 支持「中文标题 / 去括号变体 / 译文里保留的英文原名」；术语表就绪与每批译文后 `setLinkTitles + relink`（原先中文几乎点不了）；链接样式加深以便看出可点
- **开篇两栏 + 信息框**：字号 .7rem→.78rem、加内边距与底色、去掉末行分隔线
- **搜索**：回车先给「结果列表」（中文标题匹配 + 标题匹配 + 全文相关），再由使用者挑；↑↓ 选择、再回车打开；结果缺中文标题时用本机翻译补上并写回标题库
- **质量**：`ZimService.isInteresting` 扩展（标识符页/命名空间页/List of/年份页/消歧义页），随机漫游不再直接落在排名第一的条目；搜索建议按热门度重排（`TranslationStore.rankScores`）；新增 18 个 XCTest（全绿）；`wikitool` 新增 `linkcheck` 命令（统计译文里能挂上链接的比例）

## 已验证（有据）
- 编译/签名/启动/真实条目渲染（截图）；首页封面杂志版式（截图）；对照上下（截图）；对照并排（截图）；章节面板 + 计数 + 按钮（截图）；Aa 面板全部行项（截图）；阅读进度线（截图）；开篇两栏（截图 + 三条目静态校验）；参考资料进入翻译单元（wikitool units）；18 个 XCTest；链接可点（放大截图可见译文里带下划线的链接）
- 本轮共 7 次构建，旧版备份见 backups/（最新 维基离线-20261005-030746.app）

## 未验证
- 断网翻译实测（需要断网环境，建议最后人工验证）
- ⌘⇧H 首页快捷键（自动化里驱动不出来；顶栏房子图标与菜单项正常）
- ⌥↓「下一节」的滚动效果（同上，按键注入不可靠）
- 搜索结果显示中文标题的实际效果（代码已接、未截到图）
- 参考资料双语的实际观感与长条目翻译耗时

## 已知问题
- 引擎仍会把个别拼音人名译错（如 Xi Zhongxun →"西忠勋"），偶尔漏译
- 无 h2 的短条目会把整篇包进两栏（罕见）
- 首页"今日推荐"的英文摘要偶发不翻译（待查）

## 搜索与动画（03:20 追加）
- **条数**：结果模式改成「标题建议 60 条 + 全文相关 60 条」（原先 24/18），右下角显示总条数（例如"全文相关 · 约 254097 条"）；输入时的建议 20 条 + "查看全部结果"一行
- **中文标题**：结果里缺中文的标题用本机翻译补上并写回标题库（title 表），英文摘要也翻（前 8 条）；补译文改在结果落地后触发（修掉了原先在旧数据上执行的时序 bug）
- **建议排序**：回到以 Xapian 相关度为主；只有前 8 条**都以查询词开头**时才按热门度重排（einst → 爱因斯坦第一），避免把不相关条目顶上来（此前"游戏"的第一条会变成"艺术批评"，已修）
- **动画**：译文淡入 0.55s → 0.92s，缓动改 cubic-bezier(.22,.61,.36,1)，加 3px 模糊化开；同一批译文按 70ms 错峰（最多 6 段）；骨架 shimmer 1.3s→1.9s、呼吸 1.6s→2.6s；顶栏显示"正在翻译 x / y 段"
- 验证：`wikitool searchcheck <zim> <query>` 可复刻整条搜索链路并打印条数与中文标题覆盖率（新增命令）

## 收尾（03:27）
- **修**：开篇有多个信息框/侧栏模板的条目（例如「切斯特·A·阿瑟的总统任期」= infobox + sidebar）会在同一个网格单元里**重叠**、右边缘裁切 → reader.js 现在把它们合并成一个 `.lead-side` 容器；同时去掉 `table-layout: fixed`（复杂信息框会串行）
- **修**：搜索结果的「中文标题匹配」分组标题被我的一段收尾代码覆盖掉了 → 改成记录分组起始下标
- **改**：顶栏的「中文 / English / 对照」移到 Aa 面板第一行「语言」（⌘1/⌘2/⌘3 不变）；顶栏的 LanguageSwitch 结构体保留但已不再使用
- 实测确认：搜索结果每条都有中文标题、`标题匹配 · 共 48 条`、`全文约 254,097 条`；巴黎人开篇两栏正常；顶栏语言切换已移走

## 打包与图标（03:45）
- **交付物**：`~/Documents/维基百科离线/维基离线-1.0.dmg`（18.9 MB，内含 `维基离线.app` + 指向 /Applications 的快捷方式）。已验证：DMG 能挂载、内容完整、**从 DMG 里复制出来的一份能独立启动**（44M，自带 Frameworks，不依赖 /opt/homebrew）
- **图标**：`Resources/AppIcon.icns`。生成方式：把正方形 logo（建议 1024×1024 PNG）放到 `Resources/AppIcon-source.png`，`./build.sh` 会自动用 `scripts/makeicon.swift` 生成全套尺寸的 icns（圆角纸色底 + logo 居中 68% + 细边）
  - 当前这张源图是**从 ZIM 元数据 `Illustration_48x48@1` 导出的 48×48**（确实是维基的拼图地球），放大会糊 → 有高清图就替换源文件再 `./build.sh install`
  - `wikitool illustration <zim> <out.png>` 可导出 ZIM 自带的插图
- 签名是 ad-hoc（本机自用没问题）；拷到别的 Mac 会被 Gatekeeper 拦，且那台机器上要有 ZIM 文件
