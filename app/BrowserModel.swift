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
    // MARK: - 长按视频 → 弹菜单（批次 D）

    /// 非空 = 长按菜单正在显示
    @Published var lpMenu: LongPressMenuInfo?
    /// 长按诊断：设置里那个开关打开才写。真机测一次，卡在哪一步一眼能看出来。
    @Published var lpDebug: String?
    private var lpDebugStamp = UUID()

    /// 设置里的「长按诊断」开关（默认关，不给平时用加噪音）
    private var lpDebugOn: Bool { UserDefaults.standard.bool(forKey: "lpDebug") }

    /// 系统长按菜单里的「Download」被点 —— 界面接线成真正的下载动作
    var onDownloadRequest: ((String) -> Void)?
    @Published var toast: String?
    @Published var mseSeen = false
    @Published var hint: String?
    /// 列表最后一次刷新时间（面板上显示，让用户知道数据新不新）
    @Published var lastUpdated: Date?

    /// 当前标签的 WebView。
    /// ★ 它仍然是 weak —— 真正持有 WebView 的是每个标签对象（BrowserTab）
    ///   以及界面上的 BrowserView。多标签之后后台标签没有视图撑着，
    ///   必须靠标签对象强引用，否则一切换就被回收。
    weak var webView: WKWebView?

    // MARK: - 标签（多窗口）

    /// 最多同时开几个窗口。一个 WebView 光它的渲染进程就要几十 MB，
    /// 小屏手机上 5 个是「够用、又不至于被系统连累着杀」的量。
    static let maxTabs = 5

    /// 所有标签（数组保序 —— 标签条按这个顺序显示）
    private var tabs: [BrowserTab] = []

    /// WebView → 标签 的反查表。
    /// ★ 这是多标签能省一大截改动的关键：导航回调和 JS 消息**都自带来源 WebView**
    ///   （didFinish 的 wv 参数、WKScriptMessage.webView），靠这张表就能知道
    ///   这条消息属于哪个标签 —— 不用再额外造一层「消息中转对象」。
    private var byWebView: [ObjectIdentifier: BrowserTab] = [:]

    /// 当前标签序号。界面用 .id(currentTabIndex) 监听它 —— 一变就整体重建
    /// BrowserView，从而把新标签的 WebView 挂上去。
    @Published private(set) var currentTabIndex = 0

    /// 标签条显示用（不把 WKWebView 暴露给界面）
    @Published private(set) var tabTitles: [String] = []

    var tabCount: Int { tabs.count }

    var currentTab: BrowserTab? {
        tabs.indices.contains(currentTabIndex) ? tabs[currentTabIndex] : nil
    }

    /// 页面真的加载完成时回调（地址、标题）。
    /// 历史记录挂在这里，而**不是**监听 address 变化 —— 切换标签也会让
    /// address 变，监听它的话每切一次窗口就虚增一次「访问次数」。
    var onPageFinished: ((String, String) -> Void)?

    /// 注入脚本的源码（从 bundle 读 resources/sniffer.js）
    static let snifferSource: String = {
        guard let url = Bundle.main.url(forResource: "sniffer", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* sniffer.js 没打进 bundle */"
        }
        return s
    }()

    /// 建一个「裸」的 WebView（不登记成标签）。
    /// 配置跟单窗口时代完全一致 —— 嗅探脚本、消息通道、查找开关、UA 一个都不能少。
    private func makeRawWebView() -> WKWebView {
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
        // 每个标签的 WebView 有自己的 configuration/ucc，但 handler 都是 self ——
        // 靠 WKScriptMessage.webView 认领是哪个标签（见 didReceive）。
        ucc.add(self, contentWorld: world, name: "vgSniff")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        // 工具箱的「页内查找」：iOS 16 起 WKWebView 自带系统的 UIFindInteraction，
        // 但**默认是关的** —— 不打开这个开关，wv.findInteraction 就是 nil。
        if #available(iOS 16.0, *) {
            wv.isFindInteractionEnabled = true
        }
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        // 长按菜单（批次 D）走的是「自己挂长按手势 + 自己画菜单」（见 LongPressMenu.swift），
        // 不靠系统那套 —— Safari 的长按菜单是 WebKit 私有的（只给 Safari 和它的扩展），
        // 而且 <video> 默认根本不触发 WKUIDelegate 的菜单回调。
        // 这个开关跟那条路无关，保持打开即可（踩过：它关掉时 WebKit 连「长按链接」
        // 都不识别，为此白调过两轮 —— 别再关）。
        wv.allowsLinkPreview = true
        // 长按视频 → 弹自己的菜单。
        // cancelsTouchesInView = false 是关键：绝不能把触摸从网页手里夺走，
        // 否则点击、滚动、页面自己的长按全坏。
        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        wv.addGestureRecognizer(longPress)
        // 有些站会检测「是不是 App 内置浏览器」，用桌面 UA 降低被拒概率
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        return wv
    }

    /// 界面当前该显示的那个 WebView。首次调用会把第一个标签建出来
    /// （WebView 必须由界面这一步创建 —— 它进了视图层级才会渲染）。
    func currentWebView() -> WKWebView {
        if tabs.isEmpty { newTab() }
        return tabs[min(currentTabIndex, tabs.count - 1)].webView
    }

    // MARK: - 标签操作

    /// 新建一个窗口（顺带切过去）
    @discardableResult
    func newTab(load url: String? = nil) -> BrowserTab {
        if tabs.count >= Self.maxTabs { reclaimOne() }
        let wv = makeRawWebView()
        let tab = BrowserTab(webView: wv)
        tabs.append(tab)
        byWebView[ObjectIdentifier(wv)] = tab
        // 预热：立刻加载一次空白页。不为显示任何东西（WebView 本来就是白的），
        // 而是让 WebKit 提前把 WebContent / 网络进程拉起来 —— 用户第一次真正
        // 导航时就不用再等这套冷启动。这次导航的回调整段忽略。
        tab.warmupNav = wv.load(URLRequest(url: URL(string: "about:blank")!))
        switchTo(tabs.count - 1)
        if let url, !url.isEmpty { load(url) }
        return tab
    }

    /// 切到某个窗口。
    /// 允许重复切（幂等）—— 建第一个标签时也走这条路径，省一个分支。
    func switchTo(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        stash()                          // 界面状态 → 原来那个标签
        currentTabIndex = index
        restore(tabs[index])             // 新标签的快照 → 界面状态
        syncTabTitles()
        // 切过来补扫一次：这个页面的嗅探可能是在后台跑的时候完成的
        webView?.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
    }

    /// 关掉某个窗口。只剩一个时不真关，而是把它清回空白页。
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else { resetOnlyTab(); return }
        dispose(tabs[index])
        tabs.remove(at: index)
        if index < currentTabIndex {
            currentTabIndex -= 1         // 关的是前面的 → 当前标签下标前移
        } else if index == currentTabIndex {
            currentTabIndex = min(index, tabs.count - 1)
            restore(tabs[currentTabIndex])
        }
        syncTabTitles()
    }

    /// 界面状态 → 当前标签的快照
    private func stash() {
        guard let t = currentTab else { return }
        t.title = pageTitle
        t.address = address
        t.items = items
        t.groups = groups
        t.mseSeen = mseSeen
        t.hint = hint
        t.lastUpdated = lastUpdated
        t.isLoading = isLoading
        t.canGoBack = canGoBack
        t.canGoForward = canGoForward
    }

    /// 某个标签的快照 → 界面状态
    private func restore(_ t: BrowserTab) {
        pageTitle = t.title
        address = t.address
        items = t.items
        groups = t.groups
        mseSeen = t.mseSeen
        hint = t.hint
        lastUpdated = t.lastUpdated
        isLoading = t.isLoading
        canGoBack = t.canGoBack
        canGoForward = t.canGoForward
        webView = t.webView
    }

    /// 放掉一个标签。
    /// ★ 必须摘掉消息处理器：ucc 是**强引用 self** 的，不摘就形成
    ///   BrowserModel → tabs → webView → configuration → ucc → BrowserModel 的环，
    ///   被关掉的窗口永远不释放（开着开着就爆内存）。
    private func dispose(_ t: BrowserTab) {
        t.webView.stopLoading()
        t.webView.navigationDelegate = nil
        t.webView.uiDelegate = nil
        t.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "vgSniff", contentWorld: .page)
        byWebView[ObjectIdentifier(t.webView)] = nil
    }

    /// 最后一个窗口的「关闭」= 清回空白页（真关掉的话界面就空了）
    private func resetOnlyTab() {
        guard let t = currentTab else { return }
        items = []; groups = []; mseSeen = false
        hint = nil; lastUpdated = nil
        address = ""; pageTitle = ""
        canGoBack = false; canGoForward = false
        t.items = []; t.groups = []; t.mseSeen = false
        t.hint = nil; t.lastUpdated = nil
        t.address = ""; t.title = ""
        t.canGoBack = false; t.canGoForward = false
        t.webView.load(URLRequest(url: URL(string: "about:blank")!))
        syncTabTitles()
        showToast("已回到空白页")
    }

    /// 到上限了：优先丢「没用过的空窗口」，否则丢最旧的（绝不动当前窗口）
    private func reclaimOne() {
        if let i = tabs.firstIndex(where: { $0.isPristine && $0 !== currentTab }) {
            closeTab(i)
            return
        }
        if let i = tabs.firstIndex(where: { $0 !== currentTab }) {
            closeTab(i)
        }
    }

    private func syncTabTitles() {
        tabTitles = tabs.map { $0.displayTitle }
    }

    /// 界面按序号取标题。
    /// 不直接写 tabTitles[i]：列表在渲染间隙可能刚好少了一个（你点关闭那一瞬），
    /// 越界会崩 —— 界面取值一律走这里。
    func tabTitle(_ i: Int) -> String {
        tabTitles.indices.contains(i) ? tabTitles[i] : "新标签页"
    }

    /// 这条回调 / 消息来自哪个标签。不认识的 WebView（已关闭）返回 nil。
    private func tab(for wv: WKWebView) -> BrowserTab? {
        byWebView[ObjectIdentifier(wv)]
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
        clearItems(silent: true)      // 顺带把标签快照一起清掉，免得旧数据复活
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

    /// 清空嗅探列表。
    /// ★ 除了界面状态，还要清**当前标签的快照** —— 否则会出现这种情况：
    ///   你清了列表，页面紧接着又上报一条，ingest 拿标签里残留的旧数据当底子
    ///   合并，刚被你清掉的那一堆全回来了。
    ///   （silent：reload 用得到 —— 它也要清，但不该弹「已清空列表」。）
    func clearItems(silent: Bool = false) {
        items.removeAll()
        groups.removeAll()
        mseSeen = false
        hint = nil
        lastUpdated = nil
        if let t = currentTab {
            t.items.removeAll()
            t.groups.removeAll()
            t.mseSeen = false
            t.hint = nil
            t.lastUpdated = nil
        }
        if !silent { showToast("已清空列表") }
    }

    // MARK: - 给收藏 / 工具箱用的三个小接口

    /// 当前真实页面地址（空串与 about:blank 视为「没有页面」）。
    /// 收藏、复制 URL、翻译都走这里 —— 判断只写一处，免得各写一遍又漏一处。
    var currentURL: String? {
        let s = webView?.url?.absoluteString ?? address
        guard !s.isEmpty, s != "about:blank" else { return nil }
        return s
    }

    /// 工具箱 · 页内查找：调系统原生查找条。
    /// 返回 nil = 已调起；返回一段文字 = 没起来，并说明**真实**原因
    /// （不再像上一版那样一律甩锅给系统版本）。
    func presentFind() -> String? {
        if #available(iOS 16.0, *) {
            guard let wv = webView else { return "网页还没准备好，稍后再试" }
            guard let fi = wv.findInteraction else {
                return "查找功能没能启用（isFindInteractionEnabled 没生效）"
            }
            fi.presentFindNavigator(showingReplace: false)
            return nil
        }
        return "页内查找要 iOS 16 以上"
    }

    // MARK: - 从 JS 收到的数据

    /// 这个地址像不像媒体 —— 决定系统长按菜单里给不给 Download。
    /// 用 contains 不用结尾匹配：很多站的地址带查询串（?url=xx.m3u8）也该中。
    static func looksLikeMedia(_ s: String) -> Bool {
        let lower = s.lowercased()
        let exts = [".m3u8", ".mp4", ".ts", ".m4s", ".mov", ".webm", ".flv", ".avi", ".mkv", ".mpd"]
        return exts.contains { lower.contains($0) }
    }

    /// 收到**某个标签**的嗅探结果。
    /// ★ 多标签的关键分流：先写进这个标签自己的快照；
    ///   只有它是当前标签时，才同步到界面状态上 ——
    ///   否则你在 A 页面上会看到 B 页面（后台正在跑的那个）嗅出来的地址。
    fileprivate func ingest(tab t: BrowserTab, isCurrent: Bool,
                            href: String, mse: Bool, raw: [[String: Any]]) {
        var merged: [String: SniffItem] = [:]
        for old in t.items { merged[old.url] = old }
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
        let sorted = all.sorted {
            let a = order[$0.kind] ?? 5, b = order[$1.kind] ?? 5
            if a != b { return a < b }
            // 同类里**最近嗅到的排前面** —— 用户一般就是要刚出来的那一条
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.url < $1.url
        }

        // 先落到这个标签自己身上
        t.items = sorted
        t.groups = Self.makeGroups(sorted)
        t.lastUpdated = now
        t.mseSeen = mse
        t.hint = Self.hint(for: sorted)
        if t.address.isEmpty { t.address = href }

        guard isCurrent else { return }      // 后台标签：到此为止，不碰界面状态

        items = sorted
        groups = t.groups
        lastUpdated = now
        mseSeen = mse
        hint = t.hint
        if address.isEmpty { address = href }
        syncTabTitles()
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

    /// 面板上的提示语。
    /// 原来叫 updateHint，直接改 self.hint —— 多标签后改成「按一组结果算出来」，
    /// 因为后台标签也要各自算自己的提示。
    static func hint(for items: [SniffItem]) -> String? {
        let hasHls = items.contains { $0.kind == "hls" }
        if hasHls {
            return nil
        } else if items.isEmpty {
            return "还没嗅到东西。让视频先播几秒，再点右下角圆圈刷新。"
        } else if items.allSatisfy({ $0.kind == "segment" }) {
            return "只看到分片。往上翻，通常能找到一个 .m3u8 —— 那个才是要下的。"
        } else {
            return "看到地址了，但没有 m3u8。用长按视频再试，或换个线路。"
        }
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserModel: WKScriptMessageHandler {
    nonisolated func userContentController(_ ucc: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        // ★ 多标签：消息自带来源 WebView（message.webView），靠它认领标签 ——
        //   这样后台标签的上报只会写进它自己的快照，不会串到当前界面上。
        let src = message.webView
        Task { @MainActor in
            guard let wv = src, let t = self.tab(for: wv) else { return }
            let isCurrent = (t === self.currentTab)
            // （原来这里有一条 longpress 分支：网页层的 900ms 兜底 → 弹嗅探面板。
            //   已删除 —— 长按不该把嗅探结果弹出来，面板只由右下角按钮/底栏入口打开。）
            let href = (body["href"] as? String) ?? ""
            let mse = (body["mse"] as? Bool) ?? false
            let raw = (body["items"] as? [[String: Any]]) ?? []
            self.ingest(tab: t, isCurrent: isCurrent, href: href, mse: mse, raw: raw)
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {

    /// 长按链接的原生菜单 —— WebKit 只对「链接」弹这个（JS 已把视频盖成链接）。
    /// 媒体地址 → 只给「Download」（对齐 Stay）；普通链接 → 系统默认菜单。
    nonisolated func webView(_ webView: WKWebView,
                             contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                             completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        let link = elementInfo.linkURL
        Task { @MainActor in
            let s = link?.absoluteString ?? ""
            // 只接管「媒体文件链接」；普通链接一律交回系统（返回 nil = 不弹菜单）
            guard let link, !s.isEmpty, Self.looksLikeMedia(s) else {
                completionHandler(nil)
                return
            }
            let cfg = UIContextMenuConfiguration(identifier: nil, previewProvider: nil,
                                                 actionProvider: { _ in
                UIMenu(children: [
                    UIAction(title: "Download",
                             image: UIImage(systemName: "arrow.down.circle.fill")) { _ in
                        Task { @MainActor in self.onDownloadRequest?(s) }
                    }
                ])
            })
            completionHandler(cfg)
        }
    }

    /// 回调回来第一件事：认领这是哪个标签的 WebView。
    /// 认不到（窗口已关）或属于预热那次空白页导航 → 整段忽略。
    nonisolated func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            t.isLoading = true
            if t === self.currentTab { self.isLoading = true }
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            t.isLoading = false
            t.title = wv.title ?? ""
            t.address = wv.url?.absoluteString ?? t.address
            t.canGoBack = wv.canGoBack
            t.canGoForward = wv.canGoForward

            if t === self.currentTab {
                self.isLoading = false
                self.pageTitle = t.title
                self.address = t.address
                self.canGoBack = t.canGoBack
                self.canGoForward = t.canGoForward
                self.syncTabTitles()
                // 历史只记「你正在看的这一页」—— 后台标签加载完成不算你访问过
                self.onPageFinished?(t.address, t.title)
            }
            // 页面加载完再补扫一次（有些地址是 DOM 造好之后才有的）
            wv.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            t.isLoading = false
            // 后台标签加载失败不弹提示 —— 又没在你眼前，弹了只会莫名其妙
            if t === self.currentTab {
                self.isLoading = false
                self.showToast("加载失败：\(e.localizedDescription)")
            }
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            t.isLoading = false
            if t === self.currentTab {
                self.isLoading = false
                self.showToast("打不开：\(e.localizedDescription)")
            }
        }
    }

    /// 站内 target=_blank 之类的，直接在**它自己那个** WebView 里打开，
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

// MARK: - 长按视频 → 弹菜单

extension BrowserModel {

    @objc func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let wv = g.view as? WKWebView else { return }
        probeLongPress(wv: wv, at: g.location(in: wv))
    }

    /// 长按落点 → 问网页层「这点上有视频吗」→ 有就弹菜单。
    /// 全程回调式（不用 async/await）：这个类在 @MainActor 上，回调里再跳回主线程最稳。
    private func probeLongPress(wv: WKWebView, at point: CGPoint) {
        var lines: [String] = []
        // 坐标换算：网页视图的点 → 页面 CSS 像素（页面被「大小」缩放时要除 zoomScale）
        let zoom = max(wv.scrollView.zoomScale, 0.01)
        let cx = point.x / zoom
        let cy = point.y / zoom
        lines.append(String(format: "落点 (%.0f, %.0f) → css (%.0f, %.0f)  zoom %.2f",
                            point.x, point.y, cx, cy, zoom))
        let js = "window.__vgHit && window.__vgHit(\(cx), \(cy))"
        wv.evaluateJavaScript(js) { [weak self] raw, _ in
            Task { @MainActor in
                guard let self else { return }
                self.afterHit(wv: wv, point: point, raw: raw, lines: lines)
            }
        }
    }

    private func afterHit(wv: WKWebView, point: CGPoint, raw: Any?, lines: [String]) {
        var out = lines
        guard let d = raw as? [String: Any] else {
            out.append("网页层没回话（__vgHit 没定义？）")
            finishLPDebug(out)
            return
        }
        let kind = (d["hit"] as? String) ?? "none"
        let url = (d["url"] as? String) ?? ""
        var extra = ""
        switch kind {
        case "iframe":
            let w = (d["w"] as? NSNumber)?.intValue ?? 0
            let h = (d["h"] as? NSNumber)?.intValue ?? 0
            extra = "跨域=\((d["cross"] as? Bool) == true)  框 \(w)×\(h)"
        case "other":
            let cls = (d["cls"] as? String) ?? ""
            let n = (d["vids"] as? NSNumber)?.intValue ?? -1
            let near = (d["near"] as? String) ?? ""
            extra = "元素=" + cls + "  页内 video=\(n)"
            if !near.isEmpty { extra += "  " + near }
        case "error":
            extra = (d["msg"] as? String) ?? ""
        default:
            break
        }
        let via = (d["via"] as? String) ?? ""
        out.append("命中: " + kind
                   + (via.isEmpty ? "" : "(\(via))")
                   + (url.isEmpty ? "" : "  " + BrowserModel.briefURL(url))
                   + (extra.isEmpty ? "" : "  " + extra))

        guard kind == "media", !url.isEmpty else {
            if kind == "iframe" {
                out.append("视频在 iframe 里（跨域进不去）→ 不弹菜单")
            } else {
                out.append("这点上不是视频 → 不弹菜单，页面照旧")
            }
            finishLPDebug(out)
            return
        }

        let host = wv.url?.host ?? ""
        let title = (d["title"] as? String) ?? ""
        out.append("弹菜单  域名=\(host)  标题=\(title.prefix(24))")
        finishLPDebug(out)

        lpMenu = LongPressMenuInfo(point: point, url: url,
                                   title: title.isEmpty ? pageTitle : title,
                                   host: host)
    }

    /// 诊断日志：只在开关打开时显示，12 秒后自己消失（免得一直糊在屏幕上）
    private func finishLPDebug(_ lines: [String]) {
        guard lpDebugOn else { lpDebug = nil; return }
        let stamp = UUID()
        lpDebugStamp = stamp
        lpDebug = lines.joined(separator: "\n")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if self.lpDebugStamp == stamp { self.lpDebug = nil }
        }
    }

    /// 地址太长，日志里只留域名 + 尾巴
    static func briefURL(_ s: String) -> String {
        guard let u = URL(string: s), let h = u.host else { return String(s.prefix(48)) }
        return h + (u.path.isEmpty ? "" : String(u.path.suffix(24)))
    }

    /// 关掉菜单
    func closeLongPressMenu() {
        guard lpMenu != nil else { return }
        lpMenu = nil
    }

    /// 菜单里点了 Download
    func downloadFromLongPressMenu() {
        guard let m = lpMenu else { return }
        closeLongPressMenu()
        onDownloadRequest?(m.url)
    }
}

extension BrowserModel: UIGestureRecognizerDelegate {
    /// 和网页自己的手势共存：不抢、也不让页面失灵
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
