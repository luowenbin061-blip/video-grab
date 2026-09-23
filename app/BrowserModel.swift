import Foundation
import UIKit
import WebKit

/// 嗅探到的一条地址。
struct SniffItem: Identifiable, Hashable {
    let id = UUID()
    let url: String
    let kind: String        // hls / file / dash / blob / segment / other
    let src: String         // 来源：video.src、var now、fetch……
    let page: String
    var hits: Int

    /// 能直接下的是 hls 和直链文件；blob / segment 只能当线索。
    var isDownloadable: Bool { kind == "hls" || kind == "file" }

    var badge: String {
        switch kind {
        case "hls": return "M3U8"
        case "file": return "MP4"
        case "dash": return "MPD"
        case "blob": return "BLOB"
        case "segment": return "TS"
        default: return "?"
        }
    }

    var fileName: String {
        guard let u = URL(string: url) else { return "video" }
        let last = u.lastPathComponent
        if last.isEmpty || last == "/" { return "video" }
        return last.removingPercentEncoding ?? last
    }
}

/// 浏览器 + 嗅探结果的中枢。
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    @Published var items: [SniffItem] = []
    @Published var address = ""
    @Published var pageTitle = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var longPressFired = false      // 长按视频 → 弹面板
    @Published var toast: String?
    @Published var mseSeen = false
    @Published var hint: String?

    weak var webView: WKWebView?

    /// 注入脚本的源码（从 bundle 读 resources/sniffer.js）
    static let snifferSource: String = {
        guard let url = Bundle.main.url(forResource: "sniffer", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* sniffer.js 没打进 bundle */"
        }
        return s
    }()

    func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        // 自用工具：不要求用户手势就能自动播放，方便页面自己把视频跑起来
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let ucc = cfg.userContentController
        // ★ 必须用 page world —— 要 hook 页面自己的 fetch/XHR，也要读页面上的
        //   var now / player_aaaa 这些全局变量。isolated world 读不到。
        let world = WKContentWorld.page
        let script = WKUserScript(source: Self.snifferSource,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false,        // ★ 覆盖 iframe
                                  in: world)
        ucc.addUserScript(script)
        ucc.addScriptMessageHandler(self, contentWorld: world, name: "vgSniff")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = false
        // 有些站会检测「是不是 App 内置浏览器」，用桌面 UA 降低被拒概率
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        webView = wv
        return wv
    }

    // MARK: - 导航

    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let wv = webView else { return }
        wv.load(URLRequest(url: u))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        items.removeAll()
        mseSeen = false
        webView?.reload()
    }

    /// 手动催一次扫描（面板下拉刷新用）
    func forceScan() {
        webView?.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
        showToast("已重新扫描")
    }

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.toast == s { self.toast = nil }
        }
    }

    func copy(_ s: String) {
        UIPasteboard.general.string = s
        showToast("已复制地址")
    }

    func clearItems() {
        items.removeAll()
        showToast("已清空列表")
    }

    // MARK: - 从 JS 收到的数据

    fileprivate func ingest(href: String, mse: Bool, raw: [[String: Any]]) {
        var merged: [String: SniffItem] = [:]
        for old in items { merged[old.url] = old }
        for d in raw {
            guard let url = d["url"] as? String, !url.isEmpty else { continue }
            let item = SniffItem(
                url: url,
                kind: (d["kind"] as? String) ?? "other",
                src: (d["src"] as? String) ?? "",
                page: (d["page"] as? String) ?? href,
                hits: (d["hits"] as? Int) ?? 1)
            merged[url] = item
        }
        let order: [String: Int] = ["hls": 0, "file": 1, "dash": 2, "blob": 3, "other": 4, "segment": 9]
        items = merged.values.sorted {
            let a = order[$0.kind] ?? 5, b = order[$1.kind] ?? 5
            return a != b ? a < b : $0.url < $1.url
        }
        mseSeen = mse
        if let web = webView, web.url?.absoluteString != href {
            // 只在第一次同步地址栏，避免打字时被覆盖
            if address.isEmpty { address = href }
        }
        updateHint()
    }

    private func updateHint() {
        let hasHls = items.contains { $0.kind == "hls" }
        if hasHls {
            hint = nil
        } else if items.isEmpty {
            hint = "还没嗅到东西。让视频先播几秒，再点右下角圆圈刷新。"
        } else if items.allSatisfy({ $0.kind == "segment" }) {
            hint = "只看到分片。往上翻，通常能找到一个 .m3u8 —— 那个才是要下的。"
        } else {
            hint = "看到地址了，但没有 m3u8。用长按视频再试，或换个线路。"
        }
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserModel: WKScriptMessageHandler {
    nonisolated func userContentController(_ ucc: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in
            if let t = body["type"] as? String, t == "longpress" {
                if !self.items.isEmpty || true { self.longPressFired.toggle() }
                return
            }
            let href = (body["href"] as? String) ?? ""
            let mse = (body["mse"] as? Bool) ?? false
            let raw = (body["items"] as? [[String: Any]]) ?? []
            self.ingest(href: href, mse: mse, raw: raw)
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {

    nonisolated func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        Task { @MainActor in self.isLoading = true }
    }

    nonisolated func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.pageTitle = wv.title ?? ""
            self.address = wv.url?.absoluteString ?? self.address
            self.syncNav(wv)
            // 页面加载完再补扫一次（有些地址是 DOM 造好之后才有的）
            wv.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.showToast("加载失败：\(e.localizedDescription)")
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.showToast("打不开：\(e.localizedDescription)")
        }
    }

    private func syncNav(_ wv: WKWebView) {
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
    }

    /// 站内 target=_blank 之类的，直接在同一个 WebView 里打开，
    /// 免得弹出一个我们嗅探不到的新窗口。
    nonisolated func webView(_ wv: WKWebView,
                             createWebViewWith cfg: WKWebViewConfiguration,
                             for action: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            Task { @MainActor in wv.load(URLRequest(url: url)) }
        }
        return nil
    }
}
