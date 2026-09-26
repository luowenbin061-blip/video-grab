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

    // ★ 这里原来有一份「用户点过仍然访问的域名」内存名单（v1.0.87 已删）——
    //   改成存盘的 `TrustedHosts`：那份名单在 TLS 握手的回调里用，不能只在内存里
    //   （App 一重启就忘 = 同一个站又被问一遍）。
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
        guard let s = loadError?.url, !s.isEmpty, let u = URL(string: s) else { return }
        // ★ 手动重试 = 给一次全新的机会（崩溃计数清零），
        //   否则「一直崩」那页会一进来就又立刻认输，重试等于没试。
        currentTab?.crashCount = 0
        clearLoadError(currentTab)
        readyWebView().load(URLRequest(url: u))
    }

    /// 证书错误页上的「仍然访问」：把这个站记进放行名单，然后重新加载。
    ///
    /// ★ v1.0.87 起这只是**兜底的第二条路** —— 正常情况下证书有问题的站会被
    ///   `didReceive challenge` 里无条件放行，根本走不到错误页。留着它是为了
    ///   "万一还是失败了"时给用户一个明确的再试入口。
    func trustAndReload() {
        guard let s = loadError?.url, let u = URL(string: s) else { return }
        if let h = u.host { TrustedHosts.add(h) }      // 存盘，重开也记得
        clearLoadError(currentTab)
        readyWebView().load(URLRequest(url: u))
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

    /// 当前标签的 WebView —— **直接问当前标签要，不再另存一份**。
    ///
    /// ★★ v1.0.84 修 P0（第二次启动后地址栏 / 刷新 / 后退全都没反应）：
    ///   这里原来是 `weak var webView` —— 「当前 WebView」的**第二份副本**。
    ///   v1.0.83 加「启动恢复」时，恢复路径只把标签建出来、**没给这份副本赋值**，
    ///   于是第二次启动之后 `load()` 里 `guard let wv = webView else { return }` 静默返回
    ///   —— 地址栏输入任何网址、点「前往」都毫无反应。
    ///   （KVO / 嗅探上报 / 长按 / 下载都不走这份副本，所以 App 看着还活着，只有导航死了。）
    ///
    ///   为什么「卸载重装后第一次能用」：没有存档 → 标签列表为空 → 启动时走
    ///   `newTab()` 那条路（它会经 `switchTo` 给这个字段赋值）；有存档就走另一条，漏赋值。
    ///   为什么老版本没这问题：v1.0.82 之前没有启动恢复，标签列表启动时永远是空的。
    ///
    /// ★ 教训：**同一样东西存两份，早晚不一致。** 现在只有一份真相 ——
    ///   标签自己持有，这里现问现取。副作用是好的：8 处手工赋值全删掉了，
    ///   以后再加任何启动/切换路径都不可能"忘了同步"。
    var webView: WKWebView? { currentTab?.webView }

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

    // MARK: - 标签页组（v1.0.83）

    /// 标签页组。★ 名字不能叫 groups —— 那个已经被「嗅探结果分组」占了。
    @Published private(set) var tabGroups: [TabGroup] = []
    /// 当前在第几个组（下标指向 tabGroups）
    @Published private(set) var currentGroupIndex = 0

    /// 写盘节流用（详见 scheduleSave）
    private var saveTask: Task<Void, Never>?

    /// 当前组包含的标签（按组内顺序）。**网格界面看的就是这一份。**
    ///
    /// ★ 组只是一层过滤器：标签本身还在 `tabs` 那个扁平数组里，
    ///   组只记「包含哪些 id、什么顺序」。所以切组是零搬迁的。
    var visibleTabs: [BrowserTab] {
        guard tabGroups.indices.contains(currentGroupIndex) else { return tabs }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return tabGroups[currentGroupIndex].tabIDs.compactMap { byID[$0] }
    }

    /// 界面上「开了几个标签」= **当前组**的标签数（不是全部组的）
    var tabCount: Int { visibleTabs.count }

    /// 当前正在看的标签。★ currentTabIndex 是**组内下标**。
    var currentTab: BrowserTab? {
        let v = visibleTabs
        if v.indices.contains(currentTabIndex) { return v[currentTabIndex] }
        return v.first
    }

    /// 当前组（可能没有）
    var currentGroup: TabGroup? {
        tabGroups.indices.contains(currentGroupIndex) ? tabGroups[currentGroupIndex] : nil
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
    // MARK: - 启动 / 重启恢复

    /// ★ v1.0.83：启动时把上次的标签和组读回来。
    override init() {
        super.init()
        restoreFromDisk()

        // ★ v1.0.94：第一次打开时主动碰一下网络 —— 把国行设备的
        //   「允许"XX"使用数据?」弹窗提前引出来（用户要求：打开程序就弹，
        //   而不是等开网页时才弹）。延迟 1 秒是为了让界面先出来，别把弹窗盖在黑屏上。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NetWarmup.runIfNeeded()
        }
    }

    /// 从存档恢复「档案」。
    /// ★ **不建 WebView** —— 那是懒建的，只有当前那个会被真正加载（见 currentWebView）。
    ///   所以哪怕你关了 30 个标签，启动那一刻也只会拉起一个网页，不会卡也不会爆内存。
    private func restoreFromDisk() {
        guard let p = TabStore.load(), !p.groups.isEmpty else {
            tabGroups = [TabGroup(name: "标签页")]     // 第一次用 / 存档被清了
            currentGroupIndex = 0
            // ★ 存档「在、但读不出来」时必须说一声（v1.0.85）——
            //   以前的写法是静默当没有：用户只看到「我的标签莫名其妙全没了」，
            //   而且不知道为什么。真·第一次用不会有 lastError，所以不会乱弹。
            if let why = TabStore.lastError {
                showToast("上次的标签没能恢复：\(why)")
            }
            openStartPage()
            return
        }
        tabGroups = p.groups
        if let cid = p.currentGroupID, let i = p.groups.firstIndex(where: { $0.id == cid }) {
            currentGroupIndex = i
        } else {
            currentGroupIndex = 0
        }

        // 用存档里的 id 重建档案（id 必须一致 —— 组里存的是它、缩略图文件名也是它）
        var made: Set<UUID> = []
        for r in p.records {
            let t = BrowserTab(id: r.id)
            t.title = r.title
            t.address = r.address
            t.lastActiveAt = r.lastActiveAt
            t.thumb = TabStore.loadThumb(id: r.id)
            tabs.append(t)
            made.insert(r.id)
        }
        // 存档不一致时自愈：组里引用了已经不存在的标签，去掉
        for i in tabGroups.indices {
            tabGroups[i].tabIDs = tabGroups[i].tabIDs.filter { made.contains($0) }
        }
        // 当前组是空的（比如上次把标签都关了）→ 给一个空白标签，别让人面对空界面
        if visibleTabs.isEmpty { _ = newTab() }

        // 回到这个组上次在看的那个标签
        let v = visibleTabs
        if let cid = tabGroups[currentGroupIndex].currentTabID,
           let i = v.firstIndex(where: { $0.id == cid }) {
            currentTabIndex = i
        } else {
            currentTabIndex = 0
        }
        if let t = currentTab { syncFromTab(t) }
        refreshTabs()
        openStartPage()
    }

    /// ★ v1.0.90：启动时前台打开什么。
    ///
    /// 用户的要求：**每次打开程序固定加载设置好的主页**；主页没填就**只显示空白页**
    /// —— 总之**不要**把"上次浏览的那个网页"摆到最前面。
    /// 而他之前要的"上次标签还在"照旧：那些标签都恢复在**后台**，从网格里点得到。
    ///
    /// ★ 关键细节：**先去已有标签里找"就是这一页"的，找到就切过去**，找不到才新建。
    ///   否则每启动一次就多一个标签，用不了几天就堆到上限 30 —— 那会变成一个新 bug。
    ///
    /// ★ 这里只改「当前指向哪个标签」，**不建 WebView** —— 跟 restoreFromDisk 的做法一致，
    ///   网页是等界面出现时才懒建的（见 activate 的说明）。
    private func openStartPage() {
        let home = (UserDefaults.standard.string(forKey: "homePageURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if home.isEmpty {
            // 留空 → 前台是空白页：已有空白标签就切过去，没有才新建
            if let t = visibleTabs.first(where: { $0.address.isEmpty }) {
                pointCurrentTabAt(t)
            } else {
                _ = newTab()
            }
            return
        }

        var s = home
        if !s.contains("://") { s = "https://" + s }
        guard URL(string: s) != nil else { return }   // 写得不成样子 → 保持现状，别把界面搞空白
        if let t = visibleTabs.first(where: { $0.address == s }) {
            pointCurrentTabAt(t)
            return
        }
        _ = newTab(load: s)
    }

    /// 只把"当前标签"指向它（不建 WebView）
    private func pointCurrentTabAt(_ t: BrowserTab) {
        guard let i = visibleTabs.firstIndex(where: { $0.id == t.id }) else { return }
        currentTabIndex = i
        if tabGroups.indices.contains(currentGroupIndex) {
            tabGroups[currentGroupIndex].currentTabID = t.id
        }
        syncFromTab(t)
    }

    // MARK: - 落盘

    /// 节流写盘：变化后 1.2 秒写一次。
    /// ★ 连续变化时**不重排**（不是每次都取消重来）—— 否则页面一直在上报嗅探的话，
    ///   写盘会被无限推迟、永远写不进去。
    private func scheduleSave() {
        guard saveTask == nil else { return }
        let target = self
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            target.saveTask = nil
            target.saveNow()
        }
    }

    /// 立刻写盘。App 要进后台时必须调它 —— 后台随时可能被系统杀掉，等不了节流。
    func saveNow() {
        guard !tabGroups.isEmpty else { return }
        var groupOf: [UUID: UUID] = [:]
        for g in tabGroups {
            for id in g.tabIDs { groupOf[id] = g.id }
        }
        var recs: [TabRecord] = []
        for t in tabs {
            // 不在任何组里的标签不该存在；真出现了就跳过（别把脏数据写进存档）
            guard groupOf[t.id] != nil else { continue }
            recs.append(TabRecord(id: t.id, title: t.title, address: t.address,
                                  groupID: groupOf[t.id]!, lastActiveAt: t.lastActiveAt))
        }
        TabStore.save(TabStorePayload(groups: tabGroups,
                                      records: recs,
                                      currentGroupID: currentGroup?.id))
        // 存档里已经没有的标签，缩略图文件也一并清掉（否则越攒越多）
        TabStore.pruneThumbs(keep: Set(tabs.map { $0.id }))
    }

    /// 设置里的「清空标签存档」：清了之后下次启动是干净的空白页。
    func wipeSavedTabs() {
        TabStore.wipe()
        showToast("已清空标签存档（下次启动是空白页）")
    }

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
    ///
    /// ★ v1.0.84：这里**原来少了「把 self.webView 也设上」这一步**，就是 P0 的现场。
    ///   现在 webView 是计算属性（直接问当前标签），不存在"两边不同步"这回事了。
    func currentWebView() -> WKWebView {
        if tabs.isEmpty { newTab() }
        return activate(currentTabOrFirst())
    }

    /// 「要动手了，确保有一个能用的 WebView」。
    ///
    /// ★ v1.0.84：这几个入口原来是 `guard let wv = webView else { return }` ——
    ///   拿不到就**静默什么都不做**，用户看到的是「点了完全没反应」，而且没有任何提示。
    ///   P0 就是这么炸的（恢复路径漏赋值 → 整条导航被静默吞掉）。
    ///   现在拿不到就现建一个，绝不静默失败。
    @discardableResult
    private func readyWebView() -> WKWebView {
        webView ?? currentWebView()
    }

    /// 当前标签；越界或空时兜到第一个（并保证至少有一个）
    private func currentTabOrFirst() -> BrowserTab {
        if let t = currentTab { return t }
        if visibleTabs.isEmpty { newTab() }
        if let t = currentTab { return t }
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
        } else {
            // ★ v1.0.86：存档里的地址是坏的（带空格 / 编码坏了 / 根本不是 URL）。
            //   以前这条分支**什么都不做** —— 标签是白的、也不说为什么，
            //   又是一个"点了完全没反应"。现在把它当空白标签收尾：
            //   说一声 + 清掉坏地址（下次切回来就走上面 `address.isEmpty` 那条正常路）。
            t.address = ""
            t.title = ""
            t.warmupNav = wv.load(URLRequest(url: URL(string: "about:blank")!))
            showToast("有一个标签的地址读不出来，已恢复成空白标签")
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

    /// 正在截图、还没回来的标签（id → 开始时刻）。
    ///
    /// ★ 为什么需要它（v1.0.86 修的一个真 bug）：这里原来是「切走不到 2 秒的跳过不睡」，
    ///   为的是给旧标签留出截图时间。但那个判据在**快速连点切标签**时会**一个都不符合**
    ///   —— 每个刚被访问过的标签都在豁免期内 → 一个都不睡 → 活着的 WebView 越堆越多，
    ///   每个几十 MB。（三家 AI 独立提到了这条。）
    ///   正解**不是**把那 2 秒砍短（砍短了缩略图会变白），而是**盯住"截图这件事本身"**：
    ///   截完就让它睡（回调里再收一次）。外加 3 秒兜底 —— 万一回调永远不来
    ///   （WebView 已被拆掉），也不会把某个标签永远钉在"不能睡"。
    private var snapshotPending: [UUID: Date] = [:]

    private func pruneSnapshotPending() {
        let cut = Date().addingTimeInterval(-3)
        snapshotPending = snapshotPending.filter { $0.value > cut }
    }

    /// 活着的太多了 → 把「最久没用过、且不是当前」的睡掉。
    ///
    /// ★ 唯一的例外是"截图还没回来"的那一个（见 snapshotPending）——
    ///   它是**事件驱动**的，不是拍脑袋定个 2 秒，所以快速连点也不会卡住不动。
    private func trimLive() {
        let cur = currentTab
        pruneSnapshotPending()
        while tabs.filter({ $0.isAwake }).count > TabLimits.maxLive {
            let others = tabs.filter { $0.isAwake && $0 !== cur }
            guard !others.isEmpty else { break }
            // 优先挑"没在截图"的；一个都没有时，只有在**超出上限 2 个以上**的情况下
            // 才强行睡一个 —— 宁可缩略图偶发空白，也不能让 WebView 无限堆下去。
            let free = others.filter { snapshotPending[$0.id] == nil }
            let overBudget = tabs.filter({ $0.isAwake }).count > TabLimits.maxLive + 1
            let pool = free.isEmpty ? (overBudget ? others : []) : free
            guard let victim = pool.min(by: { $0.lastActiveAt < $1.lastActiveAt }) else { break }
            sleep(victim)
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
        // ★ 截这张图的期间不许把它睡掉（睡了截出来是空白）—— 见 snapshotPending 的说明。
        snapshotPending[t.id] = Date()
        wv.takeSnapshot(with: cfg) { img, _ in
            Task { @MainActor in
                // 不管截到没截到，都要销账 + 再收一次 ——
                // 「截完再让它睡」的落点就在这一句 trimLive()。
                self.snapshotPending[t.id] = nil
                if let img {
                    let small = Self.shrink(img, toWidth: 300)
                    t.thumb = small
                    t.thumbAt = Date()
                    TabStore.saveThumb(small, id: t.id)   // 顺手落盘：重启后网格里还有图
                    self.trimThumbs()
                    self.refreshTabs()
                }
                self.trimLive()
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

    /// 新建一个标签（放进**当前组**，顺带切过去）
    @discardableResult
    func newTab(load url: String? = nil) -> BrowserTab {
        ensureCurrentGroup()
        if tabCount >= TabLimits.maxTabs { reclaimOne() }
        let tab = BrowserTab()
        tabs.append(tab)
        tabGroups[currentGroupIndex].tabIDs.append(tab.id)
        switchTo(tabCount - 1)
        if let url, !url.isEmpty { load(url) }
        return tab
    }

    /// 没有任何组时补一个（启动、存档被清、删光了组）
    private func ensureCurrentGroup() {
        if tabGroups.isEmpty {
            tabGroups = [TabGroup(name: "标签页")]
            currentGroupIndex = 0
        }
        if !tabGroups.indices.contains(currentGroupIndex) {
            currentGroupIndex = 0
        }
    }

    /// 切到当前组里的某个标签（下标是**组内**的）。允许重复切（幂等）。
    func switchTo(_ index: Int) {
        let v = visibleTabs
        guard v.indices.contains(index) else { return }
        let t = v[index]
        // ★ 切走之前先给当前页截一张 —— 只有它正显示着的时候才截得到
        if t !== currentTab { snapshotCurrent() }

        currentTabIndex = index
        if tabGroups.indices.contains(currentGroupIndex) {
            tabGroups[currentGroupIndex].currentTabID = t.id   // 记住这个组在看哪个
        }
        t.lastActiveAt = Date()
        _ = activate(t)              // 睡着的现建、醒着的直接用
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

    /// 关掉当前组里的某个标签。只剩一个时不真关，而是把它清回空白页。
    func closeTab(_ index: Int) {
        let v = visibleTabs
        guard v.indices.contains(index) else { return }
        guard v.count > 1 else { resetOnlyTab(); return }

        let closing = v[index]
        sleep(closing)                      // 先把这个 WebView 干净地放掉
        removeFromGroups(closing.id)        // 从各个组的名单里摘掉
        tabs.removeAll { $0.id == closing.id }
        TabStore.removeThumb(id: closing.id)

        if index < currentTabIndex {
            currentTabIndex -= 1            // 关的是前面的 → 当前下标前移
        } else if index == currentTabIndex {
            currentTabIndex = min(index, max(0, tabCount - 1))
            if let t = currentTab {
                t.lastActiveAt = Date()
                _ = activate(t)
                syncFromTab(t)
                if tabGroups.indices.contains(currentGroupIndex) {
                    tabGroups[currentGroupIndex].currentTabID = t.id
                }
                trimLive()
            }
        }
        refreshTabs()
    }

    /// 把一个标签从所有组的名单里摘掉（编号统一走这一处，免得漏）
    private func removeFromGroups(_ id: UUID) {
        for i in tabGroups.indices {
            tabGroups[i].tabIDs.removeAll { $0 == id }
            if tabGroups[i].currentTabID == id { tabGroups[i].currentTabID = nil }
        }
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
        TabStore.removeThumb(id: t.id)
        syncFromTab(t)
        activate(t).load(URLRequest(url: URL(string: "about:blank")!))
        refreshTabs()
        showToast("已回到空白页")
    }

    /// 到上限了：优先丢「没用过的空标签」，否则丢最旧的（绝不动当前那个）。
    /// 先在本组里找；本组只有一个且是当前 → 退到全局找（内存是全局的事）。
    private func reclaimOne() {
        let v = visibleTabs
        if let i = v.firstIndex(where: { $0.isPristine && $0 !== currentTab }) {
            closeTab(i)
            return
        }
        if let i = v.firstIndex(where: { $0 !== currentTab }) {
            closeTab(i)
            return
        }
        // 本组没得丢 → 全局丢一个最老的空标签
        if let t = tabs.first(where: { $0.isPristine && $0 !== currentTab }) {
            sleep(t)
            removeFromGroups(t.id)
            tabs.removeAll { $0.id == t.id }
            TabStore.removeThumb(id: t.id)
            refreshTabs()
        }
    }

    /// 界面看的标签快照（值类型）—— 界面靠它渲染网格。**只包含当前组的标签。**
    /// 顺手排一次写盘（标签/标题/地址/缩略图的变化都会走到这里，一处就够）。
    private func refreshTabs() {
        let cur = currentTab
        tabSnapshot = visibleTabs.map {
            TabSnapshot(id: $0.id, title: $0.displayTitle, address: $0.address,
                        thumb: $0.thumb, isCurrent: $0 === cur)
        }
        scheduleSave()
    }

    /// 按 id 找**组内**下标。★ 界面一律拿 id 说话 —— 下标会漂（关掉一个，后面的全前移）。
    func index(of id: UUID) -> Int? {
        visibleTabs.firstIndex { $0.id == id }
    }

    // MARK: - 标签页组操作（v1.0.83）

    /// 切到某个组。★ 会回到「这个组上次在看哪个标签」。
    func switchGroup(_ index: Int) {
        guard tabGroups.indices.contains(index), index != currentGroupIndex else { return }
        snapshotCurrent()                  // 走之前给当前页留张缩略图
        currentGroupIndex = index
        currentTabIndex = 0
        let v = visibleTabs
        if let cid = tabGroups[index].currentTabID,
           let i = v.firstIndex(where: { $0.id == cid }) {
            currentTabIndex = i
        }
        if let t = currentTab {
            t.lastActiveAt = Date()
            _ = activate(t)
            syncFromTab(t)
        } else {
            _ = newTab()                   // 空组 → 给一个空白标签，别让人面对空界面
        }
        trimLive()
        refreshTabs()
    }

    /// 新建一个空组并切过去。
    @discardableResult
    func newGroup(name: String? = nil) -> TabGroup {
        snapshotCurrent()
        let g = TabGroup(name: name ?? "标签页 \(tabGroups.count + 1)")
        tabGroups.append(g)
        currentGroupIndex = tabGroups.count - 1
        currentTabIndex = 0
        _ = newTab()                       // 空组先放一个空白标签
        refreshTabs()
        return g
    }

    /// 把当前这组标签**整组搬到**一个新组里（原来那个组留一个空白标签）。
    /// ★ Safari 的「从 N 个标签页新建标签页组」是复制一份，但那样同一批标签会同时属于两组 ——
    ///   我们的模型是"一个标签只属于一个组"，所以做成"搬过去"，名字也照实写"移到"。
    @discardableResult
    func moveCurrentTabsToNewGroup(name: String? = nil) -> TabGroup {
        ensureCurrentGroup()
        let moved = tabGroups[currentGroupIndex].tabIDs
        let keep = currentTab?.id
        let g = TabGroup(name: name ?? "标签页 \(tabGroups.count + 1)", tabIDs: moved)
        tabGroups.append(g)

        // 原组清空（currentTabID 也清掉），它下面会得到一个空白标签
        tabGroups[currentGroupIndex].tabIDs = []
        tabGroups[currentGroupIndex].currentTabID = nil

        currentGroupIndex = tabGroups.count - 1
        currentTabIndex = 0
        let v = visibleTabs
        if let keep, let i = v.firstIndex(where: { $0.id == keep }) { currentTabIndex = i }
        if let t = currentTab {
            t.lastActiveAt = Date()
            _ = activate(t)
            syncFromTab(t)
            tabGroups[currentGroupIndex].currentTabID = t.id
        }
        // 原组现在是空的 → 下次切回去会自己补一个空白标签（见 switchGroup）
        trimLive()
        refreshTabs()
        return g
    }

    func renameGroup(_ index: Int, to name: String) {
        guard tabGroups.indices.contains(index) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabGroups[index].name = n
        scheduleSave()
    }

    /// 删组：**组里的标签一起关掉**（Safari 也是这个行为，会先提示）。
    func deleteGroup(_ index: Int) {
        guard tabGroups.indices.contains(index), tabGroups.count > 1 else { return }
        for id in tabGroups[index].tabIDs {
            if let t = tabs.first(where: { $0.id == id }) { sleep(t) }
            TabStore.removeThumb(id: id)
            tabs.removeAll { $0.id == id }
        }
        tabGroups.remove(at: index)
        if currentGroupIndex >= tabGroups.count { currentGroupIndex = tabGroups.count - 1 }
        currentTabIndex = 0
        if let t = currentTab {
            t.lastActiveAt = Date()
            _ = activate(t)
            syncFromTab(t)
        } else {
            _ = newTab()
        }
        trimLive()
        refreshTabs()
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
        guard let u = URL(string: s) else {
            // 以前这里跟「拿不到 WebView」挤在同一个 guard 里静默 return ——
            // 用户只看到"点了没反应"。地址不合法至少要吭一声。
            showToast("这个地址好像不对，检查一下再试")
            return
        }
        clearLoadError(currentTab)
        readyWebView().load(URLRequest(url: u))
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

    /// 顶部提示。seconds 默认 1.8 秒 —— 普通提示（"已复制地址"这种）保持不变。
    ///
    /// ★ 为什么加 seconds（v1.0.88）：证书那条提示有 18 个字，1.8 秒根本读不完，
    ///   而这时候页面正在加载、用户注意力也在页面上 —— 实测就是"没看到"。
    ///   凡是要用户读懂一句话的提示，必须给它足够的时间。
    func showToast(_ s: String, seconds: Double = 1.8) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
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

        // ★ 截断到上限（v1.0.85）—— 这份列表只增不减，见 TabLimits.maxSniffItems 的说明。
        //   排序已经保证「hls 优先、同类里最近的在前」，所以从头截断留下的就是最有用的那批。
        let capped = sorted.count > TabLimits.maxSniffItems
            ? Array(sorted.prefix(TabLimits.maxSniffItems))
            : sorted

        // 先落到这个标签自己身上
        t.items = capped
        t.groups = Self.makeGroups(capped)
        t.lastUpdated = now
        t.mseSeen = mse
        t.hint = Self.hint(for: capped)
        if t.address.isEmpty { t.address = href }

        guard isCurrent else { return }      // 后台标签：到此为止，不碰界面状态

        items = capped
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
    ///
    /// ★ v1.0.86 加了「认输机制」：自动重载原本**没有上限** —— 遇到那种稳定把内核
    ///   搞崩的页面，就是"崩 → 重载 → 崩"死循环，风扇起飞。现在崩够
    ///   TabLimits.maxCrashReloads 次就停手，把这一页摆成错误页，由用户决定要不要再来。
    nonisolated func webViewWebContentProcessDidTerminate(_ wv: WKWebView) {
        Task { @MainActor in
            guard let t = self.tab(for: wv) else { return }
            t.isLoading = false
            if t === self.currentTab {
                self.isLoading = false
                self.progressActive = false
                self.progress = 0
            }
            let recoverable = !t.address.isEmpty && t.address != "about:blank"

            // 崩太多次了 → 不再自动重载（只提示一次，别反复刷屏）
            if t.crashCount >= TabLimits.maxCrashReloads {
                if t.crashCount == TabLimits.maxCrashReloads {
                    t.crashCount += 1
                    t.loadError = PageError.crashGaveUp(url: t.address,
                                                        attempts: TabLimits.maxCrashReloads)
                    if t === self.currentTab {
                        self.loadError = t.loadError
                        self.showToast("这页反复崩，先不自动恢复了 —— 点「重试」再试一次")
                    }
                }
                return
            }

            t.crashCount += 1
            if t === self.currentTab {
                self.showToast("页面被系统回收了，正在自动恢复…")
            }
            if recoverable { wv.reload() }
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
            t.crashCount = 0     // ★ v1.0.86：这一页正常活下来了 → 崩溃计数清零

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

    // MARK: 服务器证书有问题 → **一律放行**，只在第一次提醒一句（v1.0.87 改）

    /// 证书过期 / 自签 / 身份对不上的时候，系统会来这里问。
    ///
    /// ★ v1.0.87 按用户要求重做（原话：「不能影响我正常访问」「首次访问可以有提示，
    ///   我选择了仍然访问后下次就不能再提示我」「不拦截网站加载，可以有提醒，
    ///   但到底选不选择访问的权利还是在用户」）。现在的规矩：
    ///   · **绝不取消加载** —— 无条件放行，页面照常打开；
    ///   · **第一次**遇到这个站 → 顶部轻提示一句（不挡页面、不要你点任何东西）；
    ///   · 之后**永久不再提示**（名单存磁盘，见 `TrustedHosts`）；
    ///   · 去留完全由你 —— 我们不拦，也不替你决定。
    ///
    /// ★ 为什么原来那版会"点了也进不去"：它是"先拦下来、弹窗问你"。弹不出来
    ///   （后台标签 / 已有别的弹窗）就直接 cancel → 页面变成"打不开"；而"记住这个站"
    ///   只存在内存里、重开就忘。旧注释甚至承认过「iOS 上这个回调能不能收到，资料说法不一」
    ///   —— 真收不到时，错误页那条补救路（`trustAndReload`）**同样依赖这个回调** →
    ///   死循环，永远进不去。现在**放行是无条件的**，不再依赖"你点过什么"。
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
        // ★ 证书有问题：**先放行**。这一步必须无条件、同步做掉 —— 不能等任何 UI，
        //   否则"UI 没弹出来"就等于"页面打不开"。
        let host = challenge.protectionSpace.host
        let firstTime = TrustedHosts.add(host)      // 存盘；true = 第一次见
        completionHandler(.useCredential, URLCredential(trust: trust))
        // 第一次见 → 轻提示一句（只在你看的这一页上说，后台标签别来打扰）
        if firstTime {
            Task { @MainActor in
                guard self.tab(for: wv) === self.currentTab else { return }
                // 8 秒：这句要读得完（默认 1.8 秒实测会被错过）
                self.showToast("这个网站的证书不被信任，已放行 —— 以后不再提示", seconds: 8)
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
            // ★ v1.0.86：以前只报个"跨域=是/否"，而 JS 侧把"同源但还没加载完"也算成了
            //   跨域 —— 于是一律被读成"跨域进不去"，照着去查是白查。现在两种分开写。
            let cross = (d["cross"] as? Bool) == true
            extra = (cross ? "跨域 iframe" : "同源 iframe（拿不到内容 = 还没加载完）")
                    + "  框 \(w)×\(h)"
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
                // ★ 按**真实原因**分两种说法：跨域是"进不去"，同源多半是"还没加载完"。
                if (d["cross"] as? Bool) == true {
                    out.append("视频在跨域 iframe 里 → 同源策略进不去，不弹菜单")
                } else {
                    out.append("命中的是同源 iframe，但里面没找到 video"
                               + "（多半是还没加载完 / 视频在更深一层）→ 不弹菜单")
                }
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
