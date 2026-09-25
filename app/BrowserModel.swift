import Foundation
import Security
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
    /// 页面加载进度 0~1（来自 WebView 自带的 estimatedProgress，KVO 实时更新）
    @Published var progress: Double = 0
    /// 进度条要不要显示（走满后自动收起 —— 对齐 Safari）
    @Published var progressActive = false
    /// 「打不开这个网页」—— 非空时界面整页盖一层错误页（对齐 Safari）。
    /// 原来只是一闪而过的一行小字，用户来不及看清原因。
    @Published var loadError: PageError?
    @Published var canGoBack = false
    @Published var canGoForward = false
    // MARK: - 长按视频 → 弹菜单（批次 D）

    /// 非空 = 长按菜单正在显示
    @Published var lpMenu: LongPressMenuInfo?
    /// 长按诊断：设置里那个开关打开才写。真机测一次，卡在哪一步一眼能看出来。
    @Published var lpDebug: String?
    private var lpDebugStamp = UUID()

    // ★ UserDefaults 的坑：bool(forKey:) 对「从没写过的 key」返回 false。
    //   所以「长按下载」这种默认要开的开关不能直接用它 —— 新装的用户会默认关掉。
    //   一律走 object(forKey:) as? Bool ?? 默认值。
    /// 设置里的「长按视频弹下载菜单」（默认开）。关掉 = 长按完全不接管
    private var lpDownloadOn: Bool {
        (UserDefaults.standard.object(forKey: "lpLongPressDownload") as? Bool) ?? true
    }
    /// 设置里的「长按诊断」（默认关，不给平时用加噪音）
    private var lpDebugOn: Bool {
        (UserDefaults.standard.object(forKey: "lpDebug") as? Bool) ?? false
    }

    /// 系统长按菜单里的「Download」被点 —— 界面接线成真正的下载动作
    var onDownloadRequest: ((String) -> Void)?
    @Published var toast: String?
    @Published var mseSeen = false
    @Published var hint: String?
    /// 列表最后一次刷新时间（面板上显示，让用户知道数据新不新）
    @Published var lastUpdated: Date?
    /// 加载超时 / 进度条收起的定时器
    private var loadTimeoutTask: Task<Void, Never>?
    private var progressHideTask: Task<Void, Never>?
    /// 加载完成后延迟截缩略图的定时器
    private var thumbTask: Task<Void, Never>?

    // MARK: - 网页弹窗 / 证书（v1.0.80）

    /// 用户点过「仍然访问」的域名 —— 同一个站不再反复问（问一次就够了）
    private var trustedHosts: Set<String> = []
    /// 有系统弹窗正在显示。防止连环弹窗（网页一个接一个 alert）把 present 弄乱
    private var dialogBusy = false

    /// 又开始加载 / 加载成功了 → 错误页收掉。
    /// 传标签就一起清它的（两个失败回调都只动当前标签，这条必须成对清）。
    @MainActor
    private func clearLoadError(_ t: BrowserTab? = nil) {
        if let t { t.loadError = nil }
        loadError = nil
    }

    /// 错误页上的「重试」
    func retry() {
        guard let s = loadError?.url, !s.isEmpty,
              let u = URL(string: s), let wv = webView else { return }
        clearLoadError(currentTab)
        wv.load(URLRequest(url: u))
    }

    /// 证书错误页上的「仍然访问」：把这个站记进白名单，然后重新加载。
    /// 这条是「证书挑战回调没收到」时的第二条路 —— 两条路都能通到「放行」。
    func trustAndReload() {
        guard let s = loadError?.url, let u = URL(string: s), let wv = webView else { return }
        if let h = u.host { trustedHosts.insert(h) }
        clearLoadError(currentTab)
        wv.load(URLRequest(url: u))
    }

    // MARK: 系统弹窗的公共零件

    /// 这个弹窗该不该弹、由谁弹。
    /// 规则：**只有你正在看的那一页**才弹（后台窗口突然弹出来只会莫名其妙），
    /// 且同一时刻只允许一个系统弹窗。
    /// ★ 返回 nil 时调用方**必须**按"默认答案"回调 —— 绝不能让网页一直等。
    @MainActor
    private func dialogHost(for wv: WKWebView) -> UIViewController? {
        guard tab(for: wv) === currentTab else { return nil }
        guard !dialogBusy else { return nil }
        return Self.topViewController()
    }

    /// 弹窗标题用域名 —— Safari 就是这么显示的，比一个"提示"有用得多
    private func hostOf(_ wv: WKWebView) -> String {
        (wv.url?.host).flatMap { $0.isEmpty ? nil : $0 } ?? "网页提示"
    }

    /// 当前能弹东西的控制器：取最前面那个窗口的 rootViewController，再往它最上层找。
    /// （我们自己也有若干弹层，直接往 rootViewController 上 present 会失败。）
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let win = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var vc = win.rootViewController else { return nil }
        while let p = vc.presentedViewController { vc = p }
        return vc
    }

    /// 当前标签的 WebView。
    /// ★ 它仍然是 weak —— 真正持有 WebView 的是每个标签对象（BrowserTab）
    ///   以及界面上的 BrowserView。多标签之后后台标签没有视图撑着，
    ///   必须靠标签对象强引用，否则一切换就被回收。
    weak var webView: WKWebView?

    // MARK: - 标签（多窗口）

    /// 标签总数上限。★ 真正的定义在 TabLimits（见 BrowserTab.swift）——
    /// 这里保留一个别名只为兼容旧引用；别再往这里加第二个数。
    static let maxTabs = TabLimits.maxTabs

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

    /// 网格界面用的标签快照（标题 / 缩略图 / 谁是当前）—— 值类型，变化时整体换一份。
    /// ★ 为什么不把 BrowserTab 直接给界面：它是 class、属性不是 @Published，
    ///   标题和缩略图变了 SwiftUI 不会刷新。
    @Published private(set) var tabSnapshot: [TabSnapshot] = []

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
        return activate(currentTabOrFirst())
    }

    /// 当前标签；越界或空时兜到第一个（并保证至少有一个）
    private func currentTabOrFirst() -> BrowserTab {
        if let t = currentTab { return t }
        if tabs.isEmpty { newTab() }
        return tabs[0]
    }

    // MARK: - 唤醒 / 休眠（「能开几十个标签」靠的就是这一对）

    /// 唤醒一个档案：没有 WebView 就现建一个，返回它的 WebView。
    ///
    /// ★ 这是本批改造的核心。以前一个标签 = 一个 WebView，开 5 个就到顶了；
    ///   现在只有 `TabLimits.maxLive` 个档案同时持有 WebView，其余是「睡着的」，
    ///   点回去时走这里现建 + 加载它的地址。代价是点回旧标签要重新加载一次页面
    ///   —— Safari 的「标签页卸载」也是这个行为。
    @discardableResult
    func activate(_ t: BrowserTab) -> WKWebView {
        if let wv = t.webView { return wv }          // 醒着 → 直接用，切回去是瞬间的

        let wv = makeRawWebView()
        t.webView = wv
        t.warmupNav = nil                            // 这次是真导航，回调要认领
        byWebView[ObjectIdentifier(wv)] = t
        t.lastActiveAt = Date()
        t.observations = makeObservations(for: wv)

        if t.address.isEmpty {
            // 新标签：加载一次空白页，只为让 WebKit 提前把进程拉起来（冷启动很贵）
            t.warmupNav = wv.load(URLRequest(url: URL(string: "about:blank")!))
        } else if let u = URL(string: t.address) {
            wv.load(URLRequest(url: u))              // 睡过的标签：把它的页面重新拉起来
        }
        return wv
    }

    /// KVO 三件套（进度 / 地址 / 标题）。
    /// 每次唤醒都要重建 —— observation 是绑在**那个 WebView**上的，
    /// 而休眠时那个 WebView 已经被丢掉了。
    private func makeObservations(for wv: WKWebView) -> [NSKeyValueObservation] {
        // KVO 回调在任意线程，要跳主线程；而"嵌套并发闭包引用 weak self"在这个工程里
        // 编译不过（别处的注释也写了），所以照同样办法先绑成 let。
        let target = self
        return [
            wv.observe(\.estimatedProgress, options: [.new]) { w, _ in
                Task { @MainActor in target.progressChanged(w) }
            },
            wv.observe(\.url, options: [.new]) { w, _ in
                Task { @MainActor in target.urlChanged(w) }
            },
            wv.observe(\.title, options: [.new]) { w, _ in
                Task { @MainActor in target.titleChanged(w) }
            },
        ]
    }

    /// 让一个档案睡下：把 WebView 彻底放掉，档案本身留着。
    /// ★ 必须摘掉消息处理器：ucc 是**强引用 self** 的 ——
    ///   摘掉 + 丢掉 WebView，BrowserModel → tabs → webView → ucc → BrowserModel
    ///   这个环才断得干净（否则开着开着就爆内存）。
    private func sleep(_ t: BrowserTab) {
        guard let wv = t.webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        t.observations.forEach { $0.invalidate() }
        t.observations = []
        wv.configuration.userContentController
            .removeScriptMessageHandler(forName: "vgSniff", contentWorld: .page)
        byWebView[ObjectIdentifier(wv)] = nil
        t.webView = nil
        t.isLoading = false
        if t === currentTab {
            isLoading = false
            progressActive = false
            progress = 0
        }
    }

    /// 活着的太多了 → 把「最久没用过、且不是当前」的睡掉。
    ///
    /// ★ 为什么要跳过"刚用过 2 秒内"的：切走那一瞬我们要给旧标签截一张缩略图，
    ///   立刻把 WebView 拆掉就会截到空白。给它留 2 秒。
    ///   （少数情况下这一轮就少睡一个，下次切换会补上，不影响正确性。）
    private func trimLive() {
        let cur = currentTab
        let now = Date()
        while tabs.filter({ $0.isAwake }).count > TabLimits.maxLive {
            let candidates = tabs.filter {
                $0.isAwake && $0 !== cur && now.timeIntervalSince($0.lastActiveAt) > 2
            }
            guard let oldest = candidates.min(by: { $0.lastActiveAt < $1.lastActiveAt }) else { break }
            sleep(oldest)
        }
    }

    // MARK: - 缩略图（网格卡片上的那张图）

    /// 给当前显示的标签截一张缩略图。
    /// ★ 只在它**正显示**的时候截 —— 休眠或后台的 WebView 截出来是空白；
    ///   所以还要它真的在窗口里（wv.window != nil）。
    func snapshotCurrent() {
        guard let t = currentTab, let wv = t.webView, wv.window != nil,
              wv.bounds.width > 1, wv.bounds.height > 1 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: wv.bounds.size)   // 只要看得见这一屏
        wv.takeSnapshot(with: cfg) { img, _ in
            guard let img else { return }
            let small = Self.shrink(img, toWidth: 300)
            Task { @MainActor in
                t.thumb = small
                t.thumbAt = Date()
                self.trimThumbs()
                self.refreshTabs()
            }
        }
    }

    /// 页面加载完成后**隔一下**再截 —— 立刻截常常截到还白着的那一瞬。
    private func snapshotThumbSoon() {
        thumbTask?.cancel()
        let target = self
        thumbTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            target.snapshotCurrent()
        }
    }

    /// 截图 → **取页面顶部 4:3** → 缩到宽 300。
    ///
    /// ★ 为什么取顶部 4:3：
    ///   ① 网格卡片是 4:3 的块，这样刚好填满、不用裁也不留白；
    ///   ② 页面顶部（网站标题 + 首屏内容）最有辨识度 —— 拿整屏缩放的话，
    ///      卡片里只能看到中间一条，认不出是哪一页；
    ///   ③ 顺带省内存：一张位图 1~2 MB，裁一半再缩，留十几张也不心疼。
    private static func shrink(_ img: UIImage, toWidth w: CGFloat) -> UIImage {
        guard img.size.width > 0, img.size.height > 0 else { return img }

        var base = img
        if let cg = img.cgImage {
            let cropH = min(CGFloat(cg.height), CGFloat(cg.width) * 0.75)
            if let sub = cg.cropping(to: CGRect(x: 0, y: 0,
                                                width: CGFloat(cg.width),
                                                height: cropH)) {
                base = UIImage(cgImage: sub, scale: img.scale, orientation: img.imageOrientation)
            }
        }

        let scale = w / base.size.width
        let size = CGSize(width: w, height: max(1, base.size.height * scale))
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 缩略图留太多也吃内存 → 只留最近的 maxThumbs 张。
    private func trimThumbs() {
        let withThumb = tabs.filter { $0.thumb != nil }
        guard withThumb.count > TabLimits.maxThumbs else { return }
        let sorted = withThumb.sorted { ($0.thumbAt ?? .distantPast) > ($1.thumbAt ?? .distantPast) }
        for t in sorted.dropFirst(TabLimits.maxThumbs) {
            t.thumb = nil
            t.thumbAt = nil
        }
    }

    // MARK: - 标签操作

    /// 新建一个窗口（顺带切过去）
    @discardableResult
    func newTab(load url: String? = nil) -> BrowserTab {
        if tabs.count >= TabLimits.maxTabs { reclaimOne() }
        let tab = BrowserTab()
        tabs.append(tab)
        switchTo(tabs.count - 1)
        if let url, !url.isEmpty { load(url) }
        return tab
    }

    /// 切到某个窗口。允许重复切（幂等）。
    func switchTo(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // ★ 切走之前先给当前页截一张 —— 只有它正显示着的时候才截得到
        if tabs[index] !== currentTab { snapshotCurrent() }

        currentTabIndex = index
        let t = tabs[index]
        t.lastActiveAt = Date()
        webView = activate(t)              // 睡着的现建、醒着的直接用
        syncFromTab(t)
        trimLive()
        refreshTabs()
        // 切过来补扫一次：这个页面的嗅探可能是在别的标签跑的时候完成的
        webView?.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
    }

    func switchTo(id: UUID) {
        guard let i = index(of: id) else { return }
        switchTo(i)
    }

    /// 关掉某个窗口。只剩一个时不真关，而是把它清回空白页。
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else { resetOnlyTab(); return }
        sleep(tabs[index])                  // 先把这个 WebView 干净地放掉
        tabs.remove(at: index)
        if index < currentTabIndex {
            currentTabIndex -= 1            // 关的是前面的 → 当前标签下标前移
        } else if index == currentTabIndex {
            currentTabIndex = min(index, tabs.count - 1)
            let t = tabs[currentTabIndex]
            t.lastActiveAt = Date()
            webView = activate(t)
            syncFromTab(t)
            trimLive()
        }
        refreshTabs()
    }

    func closeTab(id: UUID) {
        guard let i = index(of: id) else { return }
        closeTab(i)
    }

    /// 档案 → 界面状态（单向）。
    ///
    /// ★ v1.0.82 起**不再需要「把界面状态存回档案」那一步**（原来的 stash）：
    ///   所有回调本来就是「先写档案、再同步界面」，档案始终是最新的那份。
    ///   以前那种双向搬运才是 bug 之源（两边不一致时不知道信谁）。
    private func syncFromTab(_ t: BrowserTab) {
        pageTitle = t.title
        address = t.address
        items = t.items
        groups = t.groups
        mseSeen = t.mseSeen
        hint = t.hint
        lastUpdated = t.lastUpdated
        isLoading = t.isLoading
        loadError = t.loadError
        canGoBack = t.canGoBack
        canGoForward = t.canGoForward
    }

    /// 最后一个窗口的「关闭」= 清回空白页（真关掉的话界面就空了）
    private func resetOnlyTab() {
        guard let t = currentTab else { return }
        t.items = []; t.groups = []; t.mseSeen = false
        t.hint = nil; t.lastUpdated = nil
        t.address = ""; t.title = ""
        t.loadError = nil
        t.canGoBack = false; t.canGoForward = false
        t.thumb = nil; t.thumbAt = nil
        syncFromTab(t)
        activate(t).load(URLRequest(url: URL(string: "about:blank")!))
        refreshTabs()
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

    /// 界面看的标签快照（值类型）—— 界面靠它渲染网格。
    private func refreshTabs() {
        let cur = currentTab
        tabSnapshot = tabs.map {
            TabSnapshot(id: $0.id, title: $0.displayTitle, address: $0.address,
                        thumb: $0.thumb, isCurrent: $0 === cur)
        }
    }

    /// 按 id 找下标。★ 界面一律拿 id 说话 —— 下标会漂（关掉一个，后面的全前移）。
    func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
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
        clearLoadError(currentTab)
        wv.load(URLRequest(url: u))
    }

    // MARK: - KVO 回调（进度 / 地址 / 标题）

    /// 进度变了 → 推进进度条。走满后过一小会儿收起（对齐 Safari：走满、闪一下、消失）。
    @MainActor private func progressChanged(_ wv: WKWebView) {
        guard let t = tab(for: wv), t === currentTab else { return }
        let p = wv.estimatedProgress
        progress = p
        if p >= 1 {
            progressActive = true
            hideProgressSoon()
        } else if p > 0 {
            progressActive = true
            progressHideTask?.cancel(); progressHideTask = nil
        }
    }

    @MainActor private func hideProgressSoon() {
        progressHideTask?.cancel()
        let target = self
        progressHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            target.progressActive = false
            target.progress = 0
        }
    }

    /// 地址变了（KVO）—— ★ **前端路由（pushState / 换 hash）也走这里**，这就是
    /// "顶部网址不跟着页面变"的正解：原来只在 didFinish 读一次，SPA 永远不更新。
    @MainActor private func urlChanged(_ wv: WKWebView) {
        guard let t = tab(for: wv) else { return }
        guard let u = wv.url?.absoluteString, !u.isEmpty else { return }
        // 建标签时那次预热空白页不算
        if u == "about:blank", t.address.isEmpty { return }
        t.address = u
        if t === currentTab { address = u }
    }

    /// 标题变了（KVO）—— 比 didFinish 早，标签条能更早显示页面名
    @MainActor private func titleChanged(_ wv: WKWebView) {
        guard let t = tab(for: wv) else { return }
        let ti = wv.title ?? ""
        guard !ti.isEmpty, ti != t.title else { return }
        t.title = ti
        if t === currentTab {
            pageTitle = ti
            refreshTabs()
        }
    }

    /// 加载超时兜底（loading 开始后 25 秒还没完就认它卡了）。
    /// 原来没有这一层：页面卡住时 isLoading 永远是 true，进度条一直转，
    /// 用户的感觉就是"它死了，只能刷新"。
    @MainActor private func startLoadTimeout(_ t: BrowserTab) {
        loadTimeoutTask?.cancel()
        let target = self
        loadTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            guard t.isLoading else { return }
            t.isLoading = false
            if t === target.currentTab {
                target.isLoading = false
                target.progressActive = false
                target.progress = 0
                target.showToast("这一页超过 25 秒还没加载完，可能卡住了 —— 可以点刷新重试")
            }
        }
    }

    /// 加载中点「停止」：停下并复位（对齐 Safari 的 ✕）
    @MainActor func stop() {
        webView?.stopLoading()
        loadTimeoutTask?.cancel()
        progressHideTask?.cancel()
        progressActive = false
        progress = 0
        isLoading = false
        currentTab?.isLoading = false
        clearLoadError(currentTab)      // 用户主动停了 → 错误页也收掉
    }

    func goBack() { clearLoadError(currentTab); webView?.goBack() }
    func goForward() { clearLoadError(currentTab); webView?.goForward() }
    func reload() {
        clearItems(silent: true)      // 顺带把标签快照一起清掉，免得旧数据复活
        clearLoadError(currentTab)
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
        refreshTabs()
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
            self.clearLoadError(t)      // 又开始加载了 → 上一页的错误页收掉
            self.startLoadTimeout(t)
        }
    }

    /// 内容开始到达（比 didFinish 早得多）—— 地址和前进后退状态**这时候就更新**，
    /// 对齐 Safari 的做法：地址先变，页面慢慢来。
    nonisolated func webView(_ wv: WKWebView, didCommit n: WKNavigation!) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            if let u = wv.url?.absoluteString, !u.isEmpty {
                t.address = u
                if t === self.currentTab { self.address = u }
            }
            self.clearLoadError(t)      // 内容开始到达 → 确实打开了
            t.canGoBack = wv.canGoBack
            t.canGoForward = wv.canGoForward
            if t === self.currentTab {
                self.canGoBack = t.canGoBack
                self.canGoForward = t.canGoForward
            }
        }
    }

    /// ★ v1.0.79：网页的渲染进程被系统回收 / 崩掉 —— **必须自己兜**。
    /// 不实现这个回调时：页面白屏或冻住、点什么都没反应，用户只能手动刷新。
    /// Safari 会自己重载，用户几乎察觉不到。
    nonisolated func webViewWebContentProcessDidTerminate(_ wv: WKWebView) {
        Task { @MainActor in
            guard let t = self.tab(for: wv) else { return }
            t.isLoading = false
            if t === self.currentTab {
                self.isLoading = false
                self.progressActive = false
                self.progress = 0
                self.showToast("页面被系统回收了，正在自动恢复…")
            }
            if !t.address.isEmpty, t.address != "about:blank" {
                wv.reload()
            }
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            t.isLoading = false
            self.clearLoadError(t)
            t.title = wv.title ?? ""
            t.address = wv.url?.absoluteString ?? t.address
            t.canGoBack = wv.canGoBack
            t.canGoForward = wv.canGoForward

            self.loadTimeoutTask?.cancel()
            if t === self.currentTab {
                self.isLoading = false
                self.pageTitle = t.title
                self.address = t.address
                // 加载完成：进度条走满后收起
                if self.progressActive { self.progress = 1; self.hideProgressSoon() }
                self.snapshotThumbSoon()      // 页面画出来了 → 隔一下截张缩略图（网格要用）
                self.canGoBack = t.canGoBack
                self.canGoForward = t.canGoForward
                self.refreshTabs()
                // 历史只记「你正在看的这一页」—— 后台标签加载完成不算你访问过
                self.onPageFinished?(t.address, t.title)
            }
            // 页面加载完再补扫一次（有些地址是 DOM 造好之后才有的）
            wv.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
        }
    }

    /// 两个失败回调共用：翻成人话 → 整页错误页。
    @MainActor
    private func handleLoadFailure(_ t: BrowserTab, error e: Error) {
        // ★ 第一件事必须是**滤掉"取消"** —— 见 isCancelled 的说明。
        guard !Self.isCancelled(e) else { return }
        t.isLoading = false
        loadTimeoutTask?.cancel()
        // 后台窗口失败不打扰你（又没在你眼前）；状态仍记在它自己的标签里，
        // 切过去就能看到那一页的错误原因。
        guard t === currentTab else { return }
        isLoading = false
        progressActive = false
        progress = 0
        let info = PageError.make(fallbackURL: t.address, error: e)
        t.loadError = info
        loadError = info
    }

    /// 系统报的"失败"里有两种其实是**正常打断**，绝不能当错误报给用户：
    ///   · NSURLErrorCancelled(-999)：用户点了「停止」、或页面自己发起了新导航
    ///   · WebKitErrorDomain 102：frame load interrupted（同样是"被新导航打断"）
    /// 不滤掉就会出现"我点了个链接，反而弹出一个错误页"这种莫名其妙的表现。
    nonisolated static func isCancelled(_ e: Error) -> Bool {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return true }
        return false
    }

    nonisolated func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            self.handleLoadFailure(t, error: e)
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            self.handleLoadFailure(t, error: e)
        }
    }

    // MARK: 网页里的弹窗（alert / confirm / 输入框）
    //
    // ★ 为什么要实现：不实现时 WebKit 自己当"确定 / 取消"处理 —— 页面不会卡，
    //   但用户**什么都看不见**。有些站靠它提示信息、或者问"要不要继续"，
    //   在我们这儿就表现成"点了没反应"，看着像坏了。
    //
    // ★ 最要命的一条：completionHandler **必须且只能调用一次**。
    //   不调 → 网页的 JS 引擎会一直等它（页面像卡死）；调两次 → 未定义行为。
    //   所以下面每条路径都过 OnceGate 那道闸，"弹不出来"时也必须回调。
    //
    // ★ 写法上跟工程里既有的 UIAction 一致：回调里要动的东西一律包进
    //   Task { @MainActor in } —— UIAlertAction 的 handler 不是主线程隔离闭包，
    //   直接碰 @MainActor 属性在 Swift 严格检查下编不过。

    nonisolated func webView(_ wv: WKWebView,
                             runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        let gate = OnceGate()
        let done: () -> Void = { if gate.take() { completionHandler() } }
        Task { @MainActor in
            guard let vc = self.dialogHost(for: wv) else { done(); return }   // 弹不出 → 当"确定"
            let a = UIAlertController(title: self.hostOf(wv), message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    done()
                }
            })
            self.dialogBusy = true
            vc.present(a, animated: true) {
                Task { @MainActor in
                    if vc.presentedViewController !== a {   // 没弹出来 → 也得回调
                        self.dialogBusy = false
                        done()
                    }
                }
            }
        }
    }

    nonisolated func webView(_ wv: WKWebView,
                             runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        let gate = OnceGate()
        let done: (Bool) -> Void = { v in if gate.take() { completionHandler(v) } }
        Task { @MainActor in
            guard let vc = self.dialogHost(for: wv) else { done(false); return }
            let a = UIAlertController(title: self.hostOf(wv), message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    done(false)
                }
            })
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    done(true)
                }
            })
            self.dialogBusy = true
            vc.present(a, animated: true) {
                Task { @MainActor in
                    if vc.presentedViewController !== a {
                        self.dialogBusy = false
                        done(false)
                    }
                }
            }
        }
    }

    nonisolated func webView(_ wv: WKWebView,
                             runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (String?) -> Void) {
        let gate = OnceGate()
        let done: (String?) -> Void = { v in if gate.take() { completionHandler(v) } }
        Task { @MainActor in
            guard let vc = self.dialogHost(for: wv) else { done(nil); return }
            let a = UIAlertController(title: self.hostOf(wv), message: prompt, preferredStyle: .alert)
            a.addTextField { tf in
                tf.text = defaultText
                // UIKit 上是这两个属性（autocorrectionDisabled 是 SwiftUI 的写法，UITextField 没有）
                tf.autocorrectionType = .no
                tf.autocapitalizationType = .none
            }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    done(nil)
                }
            })
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    done(a.textFields?.first?.text ?? defaultText)
                }
            })
            self.dialogBusy = true
            vc.present(a, animated: true) {
                Task { @MainActor in
                    if vc.presentedViewController !== a {
                        self.dialogBusy = false
                        done(nil)
                    }
                }
            }
        }
    }

    // MARK: 服务器证书有问题 → 问一句"仍要继续访问吗"（对齐 Safari）

    /// 证书过期 / 自签 / 不是它自己的时候，系统会来这里问。
    ///
    /// ★ 原来这种站**直接打不开**，用户不知道发生了什么。
    /// ★ 一个不确定点（老实说）：iOS 上这个回调能不能收到，资料说法不一。
    ///   所以另外配了第二条路 —— 真收不到时，加载会失败并走到错误页
    ///   （-1202 这类错误码会被翻成"这个网站的证书有问题"），
    ///   用户在那一页点「仍然访问」也能进去。
    nonisolated func webView(_ wv: WKWebView,
                             didReceive challenge: URLAuthenticationChallenge,
                             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 只管"服务器证书"这一类；HTTP 用户名/密码那种交回系统默认处理
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 证书本身没问题 → 直接放行（不该拦的一律别拦）
        var evalErr: CFError?
        if SecTrustEvaluateWithError(trust, &evalErr) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let host = challenge.protectionSpace.host
        Task { @MainActor in
            // 用户对这个站过一次「仍然访问」→ 之后直接放行，不再反复问
            if self.trustedHosts.contains(host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            let gate = OnceGate()
            guard let vc = self.dialogHost(for: wv) else {
                if gate.take() { completionHandler(.cancelAuthenticationChallenge, nil) }
                return
            }
            let a = UIAlertController(
                title: "这个网站的证书有问题",
                message: "\(host) 的身份证书不被信任（可能过期，或者不是它自己的）。\n继续访问 = 不再检查这个网站的身份，请确认你信任它。",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    if gate.take() { completionHandler(.cancelAuthenticationChallenge, nil) }
                }
            })
            a.addAction(UIAlertAction(title: "仍然访问", style: .default) { _ in
                Task { @MainActor in
                    self.dialogBusy = false
                    self.trustedHosts.insert(host)
                    if gate.take() { completionHandler(.useCredential, URLCredential(trust: trust)) }
                }
            })
            self.dialogBusy = true
            vc.present(a, animated: true) {
                Task { @MainActor in
                    if vc.presentedViewController !== a {
                        self.dialogBusy = false
                        if gate.take() { completionHandler(.cancelAuthenticationChallenge, nil) }
                    }
                }
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
        // 设置里关了「长按视频弹下载菜单」→ 什么都不做（手势还挂着，但是空的）
        guard lpDownloadOn else { return }
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

    /// 诊断日志：只在开关打开时显示，8 秒后自己消失（也能点一下立刻关掉）——
    /// 别让它一直糊在屏幕上挡着页面
    private func finishLPDebug(_ lines: [String]) {
        guard lpDebugOn else { lpDebug = nil; return }
        let stamp = UUID()
        lpDebugStamp = stamp
        lpDebug = lines.joined(separator: "\n")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.lpDebugStamp == stamp { self.lpDebug = nil }
        }
    }

    /// 地址太长，日志里只留域名 + 尾巴
    static func briefURL(_ s: String) -> String {
        guard let u = URL(string: s), let h = u.host else { return String(s.prefix(48)) }
        return h + (u.path.isEmpty ? "" : String(u.path.suffix(24)))
    }

    /// 手动关掉诊断条（点它一下）
    func dismissLPDebug() {
        lpDebug = nil
        lpDebugStamp = UUID()      // 让那个 8 秒的定时器认不出自己，别再覆盖回来
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

/// 让一个回调**最多只被调用一次**。
///
/// JS 弹窗和证书挑战的 completionHandler 都是"必须且只能调一次"：
///   · 不调 → 网页的 JS 引擎 / WebKit 一直等它，表现就是页面卡死；
///   · 调两次 → 未定义行为。
/// 下面这些回调里分支很多（弹不出、present 失败、用户点了取消…），
/// 与其每条路径都小心翼翼，不如统一过一道闸。
final class OnceGate: @unchecked Sendable {
    private var used = false
    func take() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
