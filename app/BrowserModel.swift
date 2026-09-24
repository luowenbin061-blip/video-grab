import Foundation
import UIKit
import WebKit

/// 嗅探到的一条地址。
struct SniffItem: Identifiable, Hashable {
    /// 用地址当 id（不能再用随机 UUID）——
    /// 面板每刷新一次都会重建这些结构，随机 id 会让"已选中"和列表高亮一直跳。
    var id: String { url }
    let url: String
    let kind: String        // hls / file / dash / blob / segment / other
    var src: String         // 来源：video.src、var now、fetch……（video 来源会覆盖刷新）
    let page: String
    /// 嗅探那一刻的页面上下文 —— 下载分片和取 AES key 都要用（防盗链 / 鉴权）。
    /// 老记录里没有这些字段，所以给默认空串。
    var referrer = ""
    var ua = ""
    var cookie = ""
    var hits: Int
    /// 第一次嗅到的时刻（JS 那边记的，绝对时钟）
    var first: Date
    /// 最近一次被看到的时刻
    var last: Date
    /// 来自「正在播放的 video 元素」→ 面板置顶的绿标，就是用户要下的那个
    var playing: Bool

    /// 能直接下的是 hls 和直链文件；blob / segment 只能当线索。
    var isDownloadable: Bool { kind == "hls" || kind == "file" }

    /// 分组键：同目录的清单变体（master / media / 线路）合并成一条。
    /// 聚合站一个页面会预加载几十个视频的清单，全平铺用户根本没法选。
    var groupKey: String {
        guard let u = URL(string: url) else { return url }
        let host = u.host ?? ""
        if kind == "blob" { return url }                       // blob 每条独立
        let parts = u.path.split(separator: "/").map(String.init)
        let dir = parts.dropLast().joined(separator: "/")
        return host + "/" + dir
    }

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

    /// 页面域名，用来判断这条是在哪个站嗅到的
    var host: String {
        URL(string: page)?.host ?? URL(string: url)?.host ?? ""
    }

    /// 90 秒内出现过就算"新的"
    var isRecent: Bool { Date().timeIntervalSince(last) < 90 }

    /// HH:mm:ss
    var timeText: String { Self.clock.string(from: first) }

    /// 相对时间：刚刚 / 3 分钟前 / 今天 14:32 / 09-22 14:32
    var relativeText: String {
        let age = Date().timeIntervalSince(first)
        if age < 60 { return "刚刚" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前" }
        let cal = Calendar.current
        let hm = Self.hm.string(from: first)
        if cal.isDateInToday(first) { return "今天 \(hm)" }
        if cal.isDateInYesterday(first) { return "昨天 \(hm)" }
        return Self.mdhm.string(from: first)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let mdhm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    /// 给面板显示"更新于 HH:mm:ss"用
    static func clockText(_ d: Date) -> String { clock.string(from: d) }
}

/// 分组去重后的一条展示项（同目录的清单变体合并成一条，用户就不用在
/// 几十条近似地址里猜了）。下载用 best。
struct SniffGroup: Identifiable {
    let id: String          // groupKey
    let best: SniffItem     // 代表这条下载用的地址
    let total: Int          // 组内变体条数
}

/// 浏览器 + 嗅探结果的中枢。
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    @Published var items: [SniffItem] = []
    /// 分组去重后的展示列表（同目录清单变体合并成一条）
    @Published var groups: [SniffGroup] = []
    @Published var address = ""
    @Published var pageTitle = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var longPressFired = false      // 长按视频 → 弹面板
    @Published var toast: String?
    @Published var mseSeen = false
    @Published var hint: String?
    /// 列表最后一次刷新时间（面板上显示，让用户知道数据新不新）
    @Published var lastUpdated: Date?

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
        // 注意：这个方法名在 Swift 里是 add(_:contentWorld:name:)，
        // 老的 addScriptMessageHandler(_:contentWorld:name:) 已被废弃。
        ucc.add(self, contentWorld: world, name: "vgSniff")

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
        groups.removeAll()
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
        groups.removeAll()
        showToast("已清空列表")
    }

    // MARK: - 从 JS 收到的数据

    fileprivate func ingest(href: String, mse: Bool, raw: [[String: Any]]) {
        var merged: [String: SniffItem] = [:]
        for old in items { merged[old.url] = old }
        let now = Date()
        for d in raw {
            guard let url = d["url"] as? String, !url.isEmpty else { continue }
            // JS 现在上报的是绝对时钟（epoch 毫秒），不再是被误读的 performance.now()
            let first = Self.date(fromMs: d["first"]) ?? merged[url]?.first ?? now
            let last = Self.date(fromMs: d["last"]) ?? merged[url]?.last ?? now
            let hits = (d["hits"] as? Int) ?? 1
            let isPlaying = (d["playing"] as? Bool) == true
            var item = SniffItem(
                url: url,
                kind: (d["kind"] as? String) ?? "other",
                src: (d["src"] as? String) ?? "",
                page: (d["page"] as? String) ?? href,
                hits: hits,
                first: first,
                last: last,
                playing: isPlaying)
            // 页面上下文：拿到就用，拿不到（老数据 / 空 cookie）不要覆盖已有的
            let ref = (d["ref"] as? String) ?? ""
            let uaStr = (d["ua"] as? String) ?? ""
            let ck = (d["ck"] as? String) ?? ""
            if !ref.isEmpty { item.referrer = ref }
            if !uaStr.isEmpty { item.ua = uaStr }
            if !ck.isEmpty { item.cookie = ck }
            if var old = merged[url] {
                // 同一 URL 可能来自主页面和多个 iframe（各自有独立的嗅探实例）
                old.hits = max(old.hits, hits)          // 取大者 —— 做加法会虚胖
                old.first = min(old.first, first)
                old.last = max(old.last, last)
                old.playing = old.playing || isPlaying
                if item.src.hasPrefix("video") { old.src = item.src }   // video 来源最有说服力
                if old.referrer.isEmpty { old.referrer = item.referrer }
                if old.ua.isEmpty { old.ua = item.ua }
                if old.cookie.isEmpty { old.cookie = item.cookie }
                merged[url] = old
            } else {
                merged[url] = item
            }
        }
        let all = Array(merged.values)
        let order: [String: Int] = ["hls": 0, "file": 1, "dash": 2, "blob": 3, "other": 4, "segment": 9]
        items = all.sorted {
            let a = order[$0.kind] ?? 5, b = order[$1.kind] ?? 5
            if a != b { return a < b }
            // 同类里**最近嗅到的排前面** —— 用户一般就是要刚出来的那一条
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.url < $1.url
        }
        groups = Self.makeGroups(all)
        lastUpdated = now
        mseSeen = mse
        if let web = webView, web.url?.absoluteString != href {
            // 只在第一次同步地址栏，避免打字时被覆盖
            if address.isEmpty { address = href }
        }
        updateHint()
    }

    /// 同目录的清单变体（master / media / 线路）合并成一组，每组选一条代表：
    /// 正在播的 > 最近请求的 > 出现次数多的。
    static func makeGroups(_ items: [SniffItem]) -> [SniffGroup] {
        var by: [String: [SniffItem]] = [:]
        for it in items { by[it.groupKey, default: []].append(it) }
        let order: [String: Int] = ["hls": 0, "file": 1, "dash": 2, "blob": 3, "other": 4, "segment": 9]
        var groups = by.map { key, list -> SniffGroup in
            let best = list.sorted { a, b in
                if a.playing != b.playing { return a.playing }
                if a.last != b.last { return a.last > b.last }
                return a.hits > b.hits
            }[0]
            return SniffGroup(id: key, best: best, total: list.count)
        }
        groups.sort { g1, g2 in
            let a = g1.best, b = g2.best
            if a.playing != b.playing { return a.playing }          // 正在播放的最前
            let ka = order[a.kind] ?? 5, kb = order[b.kind] ?? 5
            if ka != kb { return ka < kb }                          // 可下载的优先
            if a.last != b.last { return a.last > b.last }          // 最近嗅到的优先
            return a.url < b.url
        }
        return groups
    }

    private static func date(fromMs v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n / 1000) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) / 1000) }
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        return nil
    }

    /// 面板上显示「更新于 …」
    var updatedText: String {
        guard let t = lastUpdated else { return "" }
        return SniffItem.clockText(t)
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
