import AppKit
import WebKit
import WikiCore

/// 页面资源（CSS / JS），从 App 包读取；开发时回退到源码目录
enum ReaderAssets {
    static let css: String = load("reader", "css")
    static let js: String = load("reader", "js")

    static func load(_ name: String, _ ext: String) -> String {
        if let u = Bundle.main.url(forResource: name, withExtension: ext), let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).\(ext)")
        return (try? String(contentsOf: src, encoding: .utf8)) ?? ""
    }
}

/// 线程安全的小盒子：scheme handler 在后台线程读取当前阅读样式
final class StyleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _style = ReaderStyle()
    var style: ReaderStyle {
        get { lock.lock(); defer { lock.unlock() }; return _style }
        set { lock.lock(); _style = newValue; lock.unlock() }
    }
}

/// 页面数据源：后台读取 ZIM → 清洗 → 套模板（含缓存译文）
final class ContentSource: @unchecked Sendable {
    let service: ZimService
    let store: TranslationStore?
    let style: StyleBox

    init(service: ZimService, store: TranslationStore?, style: StyleBox) {
        self.service = service
        self.store = store
        self.style = style
    }

    struct Response {
        var data: Data
        var mime: String
    }

    func response(for path: String) -> Response {
        guard let res = service.content(path: path) else {
            return Response(data: Data(ArticlePage.notFound(path: path, css: ReaderAssets.css, js: ReaderAssets.js, style: style.style).utf8), mime: "text/html")
        }
        guard res.isHTML else { return Response(data: res.data, mime: res.mimeType) }
        let raw = String(decoding: res.data, as: UTF8.self)
        let p = HTMLCleaner.process(raw, fallbackTitle: res.title)
        var cache: [String: Any] = [:]
        if let store {
            let t = store.translations(for: res.path)
            if !t.isEmpty { cache["t"] = t }
            // 站内链接的中文标题（译文模式下用来保留链接）
            let links = Array(PopularityRanker.links(in: p.body, from: res.path).prefix(800))
            let titles = store.titlesZh(for: links)
            if !titles.isEmpty { cache["l"] = titles }
            if let tz = store.titleZh(for: res.path), t.isEmpty || t[UnitText.key(UnitText.normalize(p.title))] == nil {
                cache["t"] = (cache["t"] as? [String: String] ?? [:]).merging([UnitText.key(UnitText.normalize(p.title)): tz]) { a, _ in a }
            }
        }
        let html = ArticlePage.buildWithCache(
            path: res.path, title: p.title, shortDescription: p.shortDescription, body: p.body,
            style: style.style, cache: cache, css: ReaderAssets.css, js: ReaderAssets.js)
        return Response(data: Data(html.utf8), mime: "text/html")
    }
}

/// wiki:// 协议处理器
final class WikiSchemeHandler: NSObject, WKURLSchemeHandler {
    var source: ContentSource?
    private var active = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "wiki.scheme", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        guard let url = task.request.url, let source else {
            task.didFailWithError(URLError(.cannotLoadFromNetwork))
            return
        }
        let path = WikiURL.path(from: url) ?? ""
        queue.async { [weak self] in
            let r = path.isEmpty ? ContentSource.Response(data: Data(), mime: "text/plain") : source.response(for: path)
            DispatchQueue.main.async {
                guard let self, self.active.contains(id) else { return }
                self.active.remove(id)
                let resp = URLResponse(url: url, mimeType: r.mime, expectedContentLength: r.data.count, textEncodingName: r.mime.hasPrefix("text/") ? "utf-8" : nil)
                task.didReceive(resp)
                task.didReceive(r.data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}

/// 拥有 WKWebView，处理导航、消息与离线拦截
@MainActor
final class ReaderController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    let webView: WKWebView
    let scheme = WikiSchemeHandler()

    var onMessage: ((String, [String: Any]) -> Void)?
    var onNavigationChange: (() -> Void)?
    var onBlockedExternal: ((URL) -> Void)?
    var onStartLoading: ((String?) -> Void)?

    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: WikiURL.scheme)
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(WeakMessageHandler(self), name: "reader")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false   // 返回/前进统一走 AppModel 的浏览历史栈
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .textBackgroundColor

        // 第二道防线：内容规则直接屏蔽一切 http(s) 子资源
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "wiki-offline-block-network", encodedContentRuleList: rules) { [weak self] list, _ in
            guard let list else { return }
            Task { @MainActor in self?.webView.configuration.userContentController.add(list) }
        }

        observers.append(webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.onNavigationChange?() } })
        observers.append(webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.onNavigationChange?() } })
        observers.append(webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.onNavigationChange?() } })
    }

    func load(path: String) {
        onStartLoading?(path)
        webView.load(URLRequest(url: WikiURL.article(path)))
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    var currentPath: String? { webView.url.flatMap(WikiURL.path(from:)) }

    func js(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func call(_ fn: String, _ args: Any...) {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return }
        js("window.Reader && Reader.\(fn)(...\(s))")
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        onMessage?(type, body)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == WikiURL.scheme || url.scheme == "about" {
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame ?? true,
               url.fragment == nil || WikiURL.path(from: url) != currentPath {
                onStartLoading?(WikiURL.path(from: url))
            }
            return decisionHandler(.allow)
        }
        // 外部链接：一律拦截（完全离线）
        onBlockedExternal?(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigationChange?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate —— 禁止新窗口（target=_blank）打开外部网页
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme == WikiURL.scheme { webView.load(URLRequest(url: url)) } else { onBlockedExternal?(url) }
        }
        return nil
    }
}

/// 避免 WKUserContentController 强引用造成循环
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
