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

    /// 能直接下的是 hls、直链文件和图片/音频/文档；blob / segment 只能当线索。
    /// ★ v1.0.109：加了后三类 —— 否则放开嗅探后用户在图片 tab 里点一条，
    ///   底部会写"这一条不能直接下"、按钮还是灰的（改了白改）。
    var isDownloadable: Bool {
        ["hls", "file", "image", "audio", "doc"].contains(kind)
    }

    /// 分组键：同目录的清单变体（master / media / 线路）合并成一条。
    /// 聚合站一个页面会预加载几十个视频的清单，全平铺用户根本没法选。
    var groupKey: String {
        // ★ v1.0.109：图片**不参与**同目录合并 —— 每张图都是一个独立条目，
        //   合并会把 100 张图并成 1 条（"合并清单变体"只对视频有意义）。
        if kind == "image" { return url }
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
        case "image": return "图片"
        case "audio": return "音频"
        case "doc": return "文件"
        default: return "?"
        }
    }

    var fileName: String {
        // 兜底名按类型给 —— 图片存成 "video" 太难看了（v1.0.109）
        let fallback = (kind == "image") ? "image"
                     : (kind == "audio") ? "audio"
                     : (kind == "doc") ? "file" : "video"
        guard let u = URL(string: url) else { return fallback }
        let last = u.lastPathComponent
        if last.isEmpty || last == "/" { return fallback }
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

/// ★ v1.0.112：**网页自己触发的文件下载**（点页面的下载按钮 / 附件链接）。
/// 为什么需要它：WKWebView **默认根本不实现"下载"** —— 碰到不能显示的内容
/// （`Content-Disposition: attachment` 的 exe / zip / dmg…）它既不下也不提示，
/// 用户看到的就是"点了没反应"（用户实测 workdaddy.dev 的下载按钮就是这个）。
/// 所以得由导航回调里认出这类请求，转给我们自己的下载器。
struct FileDownloadRequest {
    var url: String
    /// 服务器建议的文件名（没有就空串，界面会兜底）
    var name: String
    /// 发出这次请求的页面地址（防盗链校验的是这个，不是 document.referrer）
    var referrer: String
    var ua: String
    var cookie: String
}

/// 浏览器 + 嗅探结果的中枢。
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    /// ★ v1.0.214：当前页的 `<video>` 清单（镜像当前标签的那份）。
    ///   它只用来决定「地址栏左侧要不要出现窗口按钮」+「点了播哪个」。
    @Published var pageVideos: [PageVideo] = []

    @Published var items: [SniffItem] = []
    /// 分组去重后的展示列表（同目录清单变体合并成一条）
    @Published var groups: [SniffGroup] = []
    /// ★ v1.0.109：图片走**独立列表**（用户要的就是"视频和图片分开"）。
    ///   只写当前标签的 —— 后台标签的图片不往界面上写，避免串台。
    @Published var images: [SniffItem] = []
    @Published var imageGroups: [SniffGroup] = []
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
    /// 设置里的「后台自动嗅探」（★ v1.0.104 起默认**关**）。
    ///
    /// 关着的时候：页面不会每 3 秒自己扫、也不会自动把结果推上来 ——
    /// 但**抓请求那一半照旧在跑**（hook 一直在记），而长按下载完全不受影响。
    /// 用户打开「嗅探结果」面板时会手动扫一次（见 scanQuietly）。
    /// 用户自己选的是「只关自动扫描」这一档，不是把嗅探整个关掉。
    private var autoSniffOn: Bool {
        (UserDefaults.standard.object(forKey: "autoSniff") as? Bool) ?? false
    }

    /// 系统长按菜单里的「Download」被点 —— 界面接线成真正的下载动作
    var onDownloadRequest: ((String) -> Void)?

    /// ★ v1.0.106：长按菜单里点了下载 → 走这个（**带着页面上下文**）。
    ///
    /// 为什么单开一个回调：长按探测时已经把 Referer/UA/Cookie 一起取回来了，
    /// 而上面那个老回调只收一个地址 —— 调用方拿到地址后还得去嗅探结果里找上下文，
    /// 那条路在「自动嗅探默认关」之后基本是空的（拿不到 → 防盗链站必失败）。
    /// 没人接这个新回调时，`downloadFromLongPressMenu` 会退回老回调。
    var onLongPressDownload: ((LongPressMenuInfo) -> Void)?
    /// ★ v1.0.112：**网页自己触发的文件下载**（点页面的下载按钮 / 附件链接 / 带 download 属性的链接）。
    /// 不接这个回调时，这类请求的结局是"什么都不发生"（WKWebView 不实现下载）——
    /// 正是用户报的「点了页面里的下载也没反馈」。接线后：取消原导航 + 交给我们自己的下载器，
    /// 进度 / 暂停 / 分类 / 存文件夹 全部复用。
    var onFileDownload: ((FileDownloadRequest) -> Void)?
    @Published var toast: String?
    @Published var mseSeen = false
    @Published var hint: String?
    /// 列表最后一次刷新时间（面板上显示，让用户知道数据新不新）
    @Published var lastUpdated: Date?
    /// 加载超时 / 进度条收起的定时器
    private var loadTimeoutTask: Task<Void, Never>?
    private var progressHideTask: Task<Void, Never>?
    /// ★ v1.0.205：**原始**（未节流）加载进度 —— 只用来判断"页面还在不在动"
    private var lastEstimatedProgress: Double = -1
    /// ★ v1.0.205：原始进度最后一次**真的**发生变化的时间 —— 加载兜底唯一的判据
    private var lastProgressTick = Date()
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

    // MARK: - 网页黑名单（★ v1.0.225）

    /// 导航被黑名单拦下 → 给这个标签记一条"拦截页"，界面整页显示（复用错误页那套 UI）。
    ///
    /// ★ 为什么是"整页提示"、不是"静默退回上一页"：
    ///   从地址栏敲进来的情况**没有上一页可退**；而地址栏又停在被拦的那个地址上
    ///   （导航被取消 → KVO 不会更新它）—— 不解释一句，用户只会觉得"点了没反应"。
    @MainActor
    private func showBlocked(_ wv: WKWebView, url: URL, rule: String) {
        guard let t = tab(for: wv) else { return }
        let info = PageError.blocked(url: url.absoluteString, host: rule)
        t.loadError = info
        if t === currentTab { loadError = info }
    }

    /// 拦截页上的「移出黑名单并访问」：把这个站从名单里删掉，然后重新加载。
    /// 跟 `trustAndReload()` 完全对称（一个加名单、一个删名单）。
    func unblockAndReload() {
        guard let s = loadError?.url, !s.isEmpty, let u = URL(string: s) else { return }
        if let h = u.host { BlockList.remove(h) }
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

    /// ★ v1.0.236：**内容开始到达**时回调（比「加载完成」早得多）。
    ///   历史改挂这里 —— 原来挂 `didFinish` 会**整类漏掉**两种页：
    ///   ① 永远加载不完的（长轮询 / 流媒体 / 广告挂住，视频站常见）；
    ///   ② 前端路由站内换页（压根不触发 `didFinish`）。
    ///   代价：会把"没成功打开"的也记进去 → 用 `onVisitFailed` 撤回（**只撤这次新插入的那条**，
    ///   老记录不能因为这次失败就被删）。
    ///   ★ 后台标签也记 —— 否则"我明明打开过"会缺一块。
    var onVisitBegan: ((String, String) -> Void)?

    /// ★ v1.0.236：这次导航失败 / 被取消 → 把 `onVisitBegan` 记的那一笔撤掉
    var onVisitFailed: ((String) -> Void)?

    /// ★ v1.0.236：每个标签"这次导航"还没等到结果的地址。
    ///
    /// 为什么需要它：同一个标签的导航是**串行**的 —— 新的开始，就意味着上一个
    /// 要么已经完成、要么被替换掉了（重定向就是这么一串）。所以每个标签只留一个
    /// 待确认地址，**重定向链自然只保留最后一跳**，不会把中间那些地址也记进历史。
    private var pendingVisit: [ObjectIdentifier: String] = [:]

    // MARK: - ★ v1.0.241 网页开弹窗 → 问"怎么打开"

    /// ★★ v1.0.242：**同一次页面加载里已经问过几次**（防刷屏；`didCommit` 时清零）。
    ///
    /// ★ 这是"**防刷屏**"，**不是"阻止网页弹窗"** —— 用户 2026-10-09 明确要求把"阻止"
    ///   去掉。所以到上限之后是**静默忽略**，绝不许写回成"拦掉 + 提示一句"。
    var popupAskCount = 0

    /// 界面要显示的那个询问（nil = 不显示）。**由 SwiftUI 的 `.alert` 呈现**，见 `ContentView`。
    ///
    /// ★ 为什么不做成 UIAlertController：老写法在这个 App 里**弹不出来** ——
    ///   顶层控制器上已有我们自己的 sheet（设置 / 嗅探面板 / 下载页…）时 `present`
    ///   会静默失败，而失败后 action 回调永不执行 → `dialogBusy` 永久锁死 →
    ///   这个菜单从做出来到 v1.0.240 **一次都没显示过**。细节见 `askPopup` 的注释。
    @Published var popupAsk: PopupAskInfo?

    /// 等用户选的时候，把"这一次的现场"留住（选完要用）。
    /// ★ 不用 weak：菜单显示期间**必须**保证这个 WebView 还在（就几秒，代价可忽略）。
    private var pendingPopupWebView: WKWebView?
    private var pendingPopupRequest: URLRequest?
    private var pendingPopupURL: URL?

    /// sniffer.js 的**原始**内容（只读一次盘）
    private static let rawSnifferSource: String = {
        guard let url = Bundle.main.url(forResource: "sniffer", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* sniffer.js 没打进 bundle */"
        }
        return s
    }()

    /// 要注入的脚本源码。
    ///
    /// ★ v1.0.104：按「后台自动嗅探」开关把 autoOn 那一行改掉。
    ///   **关着时脚本照样注入、hook 照旧装** —— 这是故意的：
    ///   ① 长按下载要的 `window.__vgHit` 就在这份脚本里，不注入长按就废了；
    ///   ② 抓请求（fetch / XHR / 播放地址）是抓到「一闪而过的 m3u8」的唯一手段，
    ///      它几乎不耗 CPU，不能跟着一起关 —— 关的只是「反复扫页面 + 自动上报」。
    static func snifferSource(autoSniff: Bool) -> String {
        var s = rawSnifferSource
        let line = "var autoOn = false;"
        if s.contains(line) {   // 脚本没这个开关 → 原样注入（下面同理，逐条独立判断）
            s = s.replacingOccurrences(
                of: line,
                with: "var autoOn = " + (autoSniff ? "true" : "false") + ";")
        }
        // ★ v1.0.230：把「网页媒体自动播放」策略也注进去（拦住自动播的那一层，
        //   见 sniffer.js 的 vgInstallAutoplayGuard）。默认两行都是 false = 不拦。
        let a = WebAutoplay.current
        let aLine = "var vgAutoBlockAudio = false;"
        let vLine = "var vgAutoBlockVideo = false;"
        if s.contains(aLine) {
            s = s.replacingOccurrences(of: aLine,
                                       with: "var vgAutoBlockAudio = \(a.blockAudio ? "true" : "false");")
        }
        if s.contains(vLine) {
            s = s.replacingOccurrences(of: vLine,
                                       with: "var vgAutoBlockVideo = \(a.blockVideo ? "true" : "false");")
        }
        return s
    }

    /// cleaner.js 的**原始**内容（只读一次盘）。跟 sniffer.js 一样随身打进 bundle。
    private static let rawCleanerSource: String = {
        guard let url = Bundle.main.url(forResource: "cleaner", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* cleaner.js 没打进 bundle */"
        }
        return s
    }()

    /// 网页广告清理脚本的注入源。
    ///
    /// ★★ v1.0.238：填一份 **`ONLY`（要清理的域名清单）** —— 见 `SiteRules`。
    ///   为什么走"注入"而不是"运行时通知"：清理是在 `DOMContentLoaded` 前后才开跑的，
    ///   导航回调再通知时间是够的、但**没有注入稳**；而且 `DOCUMENT START` 注入的脚本
    ///   **每次导航都会重新执行** —— 跳站后天然重新判一次，不用盯着导航事件去补。
    ///   （代价：改名单要**刷新页面**才生效，设置页里写明了。）
    ///
    /// ★ 名单为空 → **连脚本都不注入**（见 `makeRawWebView`）—— 那样连解析都省了。
    static func cleanerSource(hosts: [String]) -> String {
        var s = rawCleanerSource
        let line = "var ONLY = [];"
        if s.contains(line) {
            // ★ 拼串交给 `SiteRules.jsList`（纯函数，CI 单测盯着它 ——
            //   这个类不在测试 target 的源码清单里，测试够不着这里）
            s = s.replacingOccurrences(of: line,
                                       with: "var ONLY = [\(SiteRules.jsList(hosts))];")
        }
        return s
    }

    /// 把一条用户脚本包成「先判 `@match`、不匹配就整段不执行」。
    ///
    /// ★ 为什么匹配要在 **JS 侧**做：原生注入是**建 WebView 时一次性的**，
    ///   而同一个 WebView 会跳到不同站点 —— 只有页面自己知道当前在哪。
    ///   规则口径跟 Swift 侧 `UserScriptMatch` 一套（scheme / host / path 三段，
    ///   只认 `*` 通配，query 和 hash 不参与），两边靠同一批用例守住。
    static func wrapUserScript(_ code: String, matches: [String]) -> String {
        let list = (matches.isEmpty ? ["*://*/*"] : matches)
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ",")
        return """
        (function () {
          var M = [\(list)];
          if (!M.length) { M = ['*://*/*']; }   // 空规则 = 全部（上面已经替过一次，这里再兜一道 —— 空数组会静默不跑，很难查）
          var sc = String(location.protocol || '').replace(/:$/, '').toLowerCase();
          var ho = String(location.hostname || '').toLowerCase();
          var pa = String(location.pathname || '/') || '/';
          function g(p, t) {
            var pi = 0, ti = 0, st = -1, mk = 0;
            while (ti < t.length) {
              if (pi < p.length && p.charAt(pi) === t.charAt(ti)) { pi++; ti++; }
              else if (pi < p.length && p.charAt(pi) === '*') { st = pi; mk = ti; pi++; }
              else if (st >= 0) { pi = st + 1; mk++; ti = mk; }
              else { return false; }
            }
            while (pi < p.length && p.charAt(pi) === '*') { pi++; }
            return pi === p.length;
          }
          function hit(p) {
            var i = p.indexOf('://');
            if (i < 0) { return false; }
            var ps = p.slice(0, i).toLowerCase();
            if (ps !== '*' && ps !== sc) { return false; }
            var rest = p.slice(i + 3);
            var j = rest.indexOf('/');
            var ph = (j < 0 ? rest : rest.slice(0, j)).toLowerCase();
            var pp = (j < 0 ? '/*' : rest.slice(j));
            if (ph !== '*') {
              if (ph.indexOf('*.') === 0) {
                var b = ph.slice(2);
                if (ho !== b && ho.slice(-(b.length + 1)) !== ('.' + b)) { return false; }
              } else if (ph !== ho) { return false; }
            }
            return g(pp, pa);
          }
          var ok = false;
          for (var k = 0; k < M.length; k++) { if (hit(M[k])) { ok = true; break; } }
          if (!ok) { return; }
          try {
        \(code)
          } catch (e) {}
        })();
        """
    }

    /// 内置的「自动播放网页视频」跟「网页媒体自动播放」四档的**关系**：
    /// 用户在四档里明确选了「禁止视频自动播放」→ **他的选择优先**，催播脚本整段不干活。
    /// （其余三档都允许催播 —— 包括"禁止音频"：那种情况下脚本会先静音播起来。）
    static func applyUserScriptPolicy(_ src: String, scriptId: String) -> String {
        guard scriptId == "builtin.userscript-autoplay" else { return src }
        let line = "var VG_AUTOPLAY_BLOCKED = false;"
        guard src.contains(line) else { return src }
        let blocked = WebAutoplay.current.blockVideo
        return src.replacingOccurrences(of: line,
                                        with: "var VG_AUTOPLAY_BLOCKED = "
                                              + (blocked ? "true" : "false") + ";")
    }

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
        // ★ v1.0.120：跟 `homePageURL` 共用同一套规范化规则（缺协议补 https://）——
        //   以前两处各写一遍，容易出现"改一处漏一处"。
        //   ★ 注意「主页」只在**程序启动进页面**时用这一次；新建标签不走这里（见 newTab）。
        guard let s = Self.homePageURL else {
            // 没设（或写得不成样子）→ 前台是空白页：已有空白标签就切过去，没有才新建
            if let t = visibleTabs.first(where: { $0.address.isEmpty }) {
                pointCurrentTabAt(t)
            } else {
                _ = newTab()
            }
            return
        }

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
        // ★ v1.0.230：改成读「网页媒体自动播放」设置（四档）。原来是写死的 []（全部允许）。
        //   默认值仍是「允许全部」→ 行为跟以前一模一样。
        //   ★ 系统这一层**只拦得住带声音的自动播** —— 而"网页自己就播起来"最常见的形态是
        //     静音自动播，那要靠 sniffer.js 里的 `vgInstallAutoplayGuard()` 兜底，两层合起来才管得住。
        //   ★ 这里只在**建 WebView 时**读一次 → 改完只对新开的页面生效（不擅自重载用户正在看的页）。
        WebAutoplay.current.apply(to: cfg)
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let ucc = cfg.userContentController
        // ★ 必须用 page world —— 要 hook 页面自己的 fetch/XHR，也要读页面上的
        //   var now / player_aaaa 这些全局变量。isolated world 读不到。
        let world = WKContentWorld.page
        let script = WKUserScript(source: Self.snifferSource(autoSniff: autoSniffOn),
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false,        // ★ 覆盖 iframe
                                  in: world)
        ucc.addUserScript(script)
        // 注意：这个方法名在 Swift 里是 add(_:contentWorld:name:)，
        // 老的 addScriptMessageHandler(_:contentWorld:name:) 已被废弃。
        // 每个标签的 WebView 有自己的 configuration/ucc，但 handler 都是 self ——
        // 靠 WKScriptMessage.webView 认领是哪个标签（见 didReceive）。
        ucc.add(self, contentWorld: world, name: "vgSniff")

        // ★ v1.0.209 网页广告清理：**独立脚本**。
        //   为什么不并进 sniffer.js：sniffer 的定时器只在「后台自动嗅探」开着时才跑，
        //   而广告清理是"打开页面就要管"的 —— 合成一个的话，关掉自动嗅探就把清理也关了。
        //   注入时机/世界/frame 范围都跟 sniffer 一致（documentStart、page world、
        //   覆盖 iframe）——documentStart 是为了让"点击防护"能抢在页面自己的脚本前面装好。
        //
        // ★★ v1.0.238：**只对名单里的站清理**；名单为空就**连脚本都不注入**
        //   （少解析 14KB，也少一整套 Observer / 定时器 / 全局 click 监听）。
        //   注意：名单在这里是**建 WebView 时的快照** —— 改完名单要刷新页面才生效。
        let cleanHosts = SiteRules.all(.adCleanOn)
        if !cleanHosts.isEmpty {
            let cleanScript = WKUserScript(source: Self.cleanerSource(hosts: cleanHosts),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false,
                                           in: world)
            ucc.addUserScript(cleanScript)
        }
        // 诊断回传走**单独一条通道**（不能并进 vgSniff —— 那边的处理函数会把
        // 每条消息都当嗅探结果喂给 ingest，混进来会污染列表）。
        ucc.add(self, contentWorld: world, name: "vgClean")

        // ★ v1.0.233 用户脚本：**逐条独立注入**。
        //   为什么不拼成一条：用户粘进来的脚本可能有语法错 —— 拼成一条的话一错全挂
        //   （连别的脚本都跑不了）。逐条各自编译执行，互不牵连。
        //   ★ 开关只影响"下次加载注不注入"：已经打开的页面要**重载**才会生效
        //     （`WKUserContentController` 只有"全部移除"，没有单独移除某一条）。
        for item in UserScriptStore.shared.enabledSources {
            let src = Self.applyUserScriptPolicy(
                Self.wrapUserScript(item.code, matches: item.script.matches),
                scriptId: item.script.id)
            ucc.addUserScript(WKUserScript(source: src,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false,   // 跟我们的脚本一样覆盖 iframe
                                           in: world))
        }

        // ★ v1.0.214 页面视频清单：走**第三条通道**。
        //   为什么不并进 vgSniff —— ① 那边的处理会把每条消息都当嗅探结果喂给 ingest，
        //   混进来会污染下载列表；② 它受「自动嗅探」开关控制，而那个开关**默认是关的**，
        //   这个功能必须任何时候都在（打开有视频的页面就出现按钮）。
        ucc.add(self, contentWorld: world, name: "vgVideos")
        // ★ v1.0.236：**站内换页**（前端路由）单独一条通道 ——
        //   这类跳转原生侧一个导航回调都不会触发，历史会整类漏记（见 sniffer.js 的 startNavWatch）。
        //   不并进 vgSniff：那边每来一条都会当嗅探结果处理，混进来会污染列表。
        ucc.add(self, contentWorld: world, name: "vgNav")

        // ★ v1.0.119 无图模式：在网络层把图片请求拦掉（真省流量）。
        //   注意只能拿到**已经编译好**的规则 —— 编译是异步的，启动时已经预热过了
        //   （见 VideoGrabApp 里的 NoImageMode.warmUp()），所以这里基本都能拿到；
        //   万一还没好，这一次加载先不拦，下次就好（不至于为了它把建标签卡住）。
        if NoImageMode.isOn, let rule = NoImageMode.readyRuleList {
            ucc.add(rule)
        }

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
        // UA：默认是**移动版 Safari** —— 有些站会检测"是不是 App 内置浏览器"，
        // 用 Safari 的串能降低被拒概率。
        // ★ v1.0.119：加了「桌面模式」开关 —— 打开就用 Mac Safari 的串。
        //   对嗅探有实际好处：有些站的手机版是私有播放器（抓不到地址），
        //   桌面版反而吐标准 HLS；还有些站只在桌面 UA 下才给高清晰度。
        wv.customUserAgent = Self.userAgent(desktop: desktopUAOn)
        // ★ v1.0.224：下拉刷新 —— 系统控件（UIRefreshControl），挂在 WKWebView
        //   **自带的那层滚动视图**上。为什么要这么挂：WKWebView 不是 SwiftUI 的 ScrollView，
        //   `.refreshable` 对它完全无效，只有这条路。
        //   · `alwaysBounceVertical = true` 必须开 —— 内容不满一屏时也要拉得动，
        //     否则那些短页面上"下拉没反应"（这是 UIRefreshControl 的通用脾气）。
        //   · 每个标签的 WebView 都挂一个：切过去就是它自己的那层。
        wv.scrollView.alwaysBounceVertical = true
        let pullRefresh = UIRefreshControl()
        pullRefresh.addTarget(self, action: #selector(onPullToRefresh(_:)), for: .valueChanged)
        wv.scrollView.refreshControl = pullRefresh
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
        // ★ v1.0.236：四个通道**都要摘**。原来只摘了 vgSniff —— 另外三个同样**强引用** self，
        //   只摘一个等于"环只断了四分之一"（虽然真正断环靠下面的 `t.webView = nil`，
        //   但这一步不该不对称：哪天 WebView 被别处多留一会儿，漏的就是它）。
        let cc = wv.configuration.userContentController
        for nm in ["vgSniff", "vgClean", "vgVideos", "vgNav"] {
            cc.removeScriptMessageHandler(forName: nm, contentWorld: .page)
        }
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

    /// 新建一个标签（放进**当前组**，切过去并加载）。
    ///
    /// ★ v1.0.238 加了 `background`：**后台打开** —— 建档案 + 记地址，但**不切过去、
    ///   也不建 WebView**（网页弹窗菜单里的"后台窗口打开"用它）。
    ///   ★ 为什么后台标签不立刻加载：同时"活着"的 WebView 只有 `TabLimits.maxLive` 个（3），
    ///     硬塞进去会把**你正在看的这一页**挤成休眠 → 切回去得重载，那更烦。
    ///     现在这样是"先记账、点过去时再加载"（`activate()` 会照档案里的地址拉起来）。
    @discardableResult
    func newTab(load url: String? = nil, background: Bool = false) -> BrowserTab {
        ensureCurrentGroup()
        if tabCount >= TabLimits.maxTabs { reclaimOne() }
        let tab = BrowserTab()
        tabs.append(tab)
        tabGroups[currentGroupIndex].tabIDs.append(tab.id)
        guard !background else {
            tab.address = url ?? ""
            tab.lastActiveAt = Date()
            refreshTabs()
            return tab
        }
        switchTo(tabCount - 1)
        // ★ v1.0.120：**新建标签不再自动开主页**（上一版加错了，用户明确纠正）——
        //   主页只在「程序启动进页面」时加载一次（见 openStartPage）；
        //   新建标签一律是空白标签 → 界面显示「首页快捷入口」。
        // ★ v1.0.205：这里以前是裸调 load(url) —— 拆方法时漏了它（编译器直接报
        //   "static member 'load' cannot be used on instance"，因为 NSObject 有个
        //   类方法叫 +load）。传进来的是完整地址，走 openURL。
        if let url, !url.isEmpty { openURL(url) }
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
        // ★ v1.0.104：这里原来会「切过来补扫一次」。自动扫描默认关之后，
        //   这一扫就成了唯一还在自动跑的扫描 —— 而且它跑的是重活（整页序列化），
        //   正是最贵的那一下。取消，改由「打开嗅探面板」时扫（见 scanQuietly）。
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

    /// 关掉**当前组**里的全部标签。
    ///
    /// `closeTab` 自带保护：只剩一个时它不真关，而是把那个清回空白页 ——
    /// 所以"全关"之后会**留下一个干净的新标签**，跟桌面浏览器的行为一致
    /// （不是"什么也不剩"，那样子用户面对空界面反而懵）。
    func closeAllTabs() {
        while tabCount > 1 {
            closeTab(0)
        }
        closeTab(0)          // 最后一个 → 清回空白页
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
        images = t.images              // ★ v1.0.203：图片也要跟着标签换（以前漏了 → 串台）
        pageVideos = t.pageVideos      // ★ v1.0.214：窗口按钮跟着标签换
        imageGroups = t.imageGroups
        mseSeen = t.mseSeen
        hint = t.hint
        lastUpdated = t.lastUpdated
        isLoading = t.isLoading
        loadError = t.loadError
        canGoBack = t.canGoBack
        canGoForward = t.canGoForward
    }

    /// ★ v1.0.214：给某条「页面视频」挑一个能播的地址 + 该带的请求头。
    ///
    /// 两条路：
    /// ① 它自己有 `src`（直链 / m3u8）→ 直接用；能在嗅探结果里对上就用那条的 Referer/UA/Cookie。
    /// ② 它是 `blob:`（现代播放器最常见）→ **拿不到地址**，只能退到嗅探结果里能直接播的候选
    ///    （优先"正在播的那条"，其次 hls，再其次直链文件）。
    /// 都拿不到就返回 nil —— 由调用方提示"先去网页点一下播放"（别假装能播）。
    func pageVideoPlayTarget(_ v: PageVideo) -> (url: String, headers: [String: String])? {
        let playable = items.filter { $0.kind == "hls" || $0.kind == "file" }
        func heads(_ it: SniffItem?) -> [String: String] {
            // ★ v1.0.217：兜底把 **Referer + UA** 都带上。
            //   以前只在"没有嗅探记录"时兜一个 Referer —— 而有些站是**按 UA 放行/拦截**的，
            //   少这一项就可能整条流播不了。
            var h: [String: String] = ["Referer": address]
            let fbUA = Self.userAgent(desktop: desktopUAOn)
            if !fbUA.isEmpty { h["User-Agent"] = fbUA }
            if let it {
                if !it.referrer.isEmpty { h["Referer"] = it.referrer }
                if !it.ua.isEmpty { h["User-Agent"] = it.ua }
                if !it.cookie.isEmpty { h["Cookie"] = it.cookie }
            }
            return h
        }
        if !v.src.isEmpty {
            let hit = playable.first { $0.url == v.src } ?? items.first { $0.url == v.src }
            return (v.src, heads(hit))
        }
        guard let c = playable.first(where: { $0.playing })
                ?? playable.first(where: { $0.kind == "hls" })
                ?? playable.first else { return nil }
        return (c.url, heads(c))
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

    /// 打开一个**网址**（不做"是网址还是关键词"的判断）。
    ///
    /// ★★ v1.0.205 从原来的 `load()` 拆出来：首页快捷入口 / 收藏点开 / 历史点开
    ///   传进来的**本来就是网址**，不该再过搜索那一层。
    func openURL(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        guard let u = Self.makeURL(s) else {
            showToast("这个地址好像不对，检查一下再试")
            return
        }
        clearLoadError(currentTab)
        readyWebView().load(URLRequest(url: u))
    }

    /// 地址栏回车 / 点「前往」：**是网址就打开，不是就拿去搜**。
    ///
    /// ★★ v1.0.205：以前（`load()`）把任何输入都当网址 —— 输中文必然被拼成
    ///   `https://中文…` 然后弹一句「这个地址好像不对」。用户的原话是"输入地址麻烦"。
    func submit(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if let u = Self.makeURL(s) {
            clearLoadError(currentTab)
            readyWebView().load(URLRequest(url: u))
            return
        }
        guard let link = SearchEngine.current.url(for: s),
              let u = URL(string: link) else {
            showToast("这个地址好像不对，检查一下再试")
            return
        }
        showToast("正在用\(SearchEngine.current.title)搜「\(s)」", seconds: 1.2)
        clearLoadError(currentTab)
        readyWebView().load(URLRequest(url: u))
    }

    /// 一段文本 → 要去的地址；**返回 nil = 这不像网址**（交给搜索引擎）。
    ///
    /// 判据照 Safari：带协议头的直接用；没空格、没中文、又像"域名 / IP / localhost"
    /// 的补上 https。其余（含中文、含空格、光秃秃一个词）一律当关键词。
    static func makeURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // ① 已经带 `://`：认得的协议直接用
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            guard knownSchemes.contains(scheme) else { return nil }
            return URL(string: s) ?? percentEncodedURL(s)
        }
        // ② 没有 `://` 但确实是协议的（about:blank / mailto: / tel:）——
        //    ★ 不挡的话 `mailto:a@b.com` 会被拼成 https 地址
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("."),
           knownSchemes.contains(String(s[..<colon]).lowercased()) {
            return URL(string: s)
        }
        // ③ 一眼像网址吗？（★ 后两条是"或"的关系：域名像 **或** 是 IP/localhost）
        let hasSpace = s.contains(" ") || s.contains("\t") || s.contains("\n")
        let hasCJK = s.unicodeScalars.contains { $0.value > 0x2E80 }    // 中日韩 → 一定是关键词
        let hostRaw = s.split(separator: "/").first.map(String.init) ?? s
        let host = hostRaw.split(separator: ":").first.map(String.init) ?? hostRaw
        let dotOK = host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
        let isIPv4 = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#,
                                options: .regularExpression) != nil
        let hostish = host.lowercased() == "localhost" || isIPv4
        guard !hasSpace, !hasCJK, (dotOK || hostish) else { return nil }   // → 去搜
        return URL(string: "https://" + s) ?? percentEncodedURL("https://" + s)
    }

    /// 含中文 / 空格的地址：`URL(string:)` 在 iOS 15 上会直接失败 —— 兜一次百分号编码
    private static func percentEncodedURL(_ s: String) -> URL? {
        guard let e = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: e)
    }

    /// 认得的协议。别的（比如手滑输入的 `C:\xxx`）**不当网址** ——
    /// 不然会被拼成 `https://C:\xxx` 再弹一句让人摸不着头脑的提示。
    private static let knownSchemes: Set<String> = [
        "http", "https", "about", "mailto", "tel", "sms", "file", "data", "blob", "ftp",
    ]

    // MARK: - KVO 回调（进度 / 地址 / 标题）

    /// 进度变了 → 推进进度条。走满后过一小会儿收起（对齐 Safari：走满、闪一下、消失）。
    @MainActor private func progressChanged(_ wv: WKWebView) {
        guard let t = tab(for: wv), t === currentTab else { return }
        let p = wv.estimatedProgress
        // ★★ v1.0.205：两件事分开，别用一个变量干两份活 ——
        //   · lastEstimatedProgress：**原始**进度，只用来判断"页面还在不在动"（加载兜底靠它）。
        //     必须跟下面的 progress 分开：混用的话，节流造成的差值会让"在动"永远成立，
        //     兜底检测就永远不触发（这正是发出去核方案时被指出的坑）。
        //   · progress：给界面那根 2pt 进度条看的，节流后再写。
        if abs(p - lastEstimatedProgress) > 0.0005 {
            lastEstimatedProgress = p
            lastProgressTick = Date()
        }
        // 节流：2pt 宽的进度条看不出 0.01 的差别，但每写一次 @Published 都要整页重算
        // （加载期间 WebKit 每秒能推几十次 —— 用户说的"偶尔卡一下"多半就是这儿）。
        // ★ 到 100% 必须强制写进去：只差 0.005 就会让进度条卡在 99% 不动。
        if abs(p - progress) >= 0.01 || p >= 1 {
            progress = p
        }
        if p >= 1 {
            progressActive = true
            hideProgressSoon()
        } else if p > 0 {
            if !progressActive { progressActive = true }      // 已经亮了就别反复写
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
        // ★ v1.0.121：**只要落在空白页，就把地址清空** ——
        //   界面据此显示「首页」（用户要的：不只是新建标签，任何空白页都该进首页）。
        //   原来只在"新建标签的那次预热导航"时跳过（t.address.isEmpty 那条），
        //   于是"已有内容的标签跳到 about:blank"会把 about:blank 写进地址栏，
        //   既不显示首页、地址栏还是串英文。
        if u == "about:blank" {
            t.address = ""
            if t === currentTab { address = "" }
            return
        }
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
    /// 加载兜底：**不看"到点了没"、看"进度是不是真的不动了"**。
    ///
    /// ★★ v1.0.205 重写（用户报的"奇奇怪怪的提示：25 秒没加载完…"就是这条）。
    ///   原来是死等 25 秒，到点就①弹一句"可能卡住了"②**把 isLoading 和进度条全清掉**。
    ///   可视频站首页本来就要加载 25 秒以上（图片、广告、各种外链），于是**经常误报**；
    ///   更糟的是误报时进度条被清掉 —— 页面明明还在正常下载，看起来却像卡死了。
    ///   现在：每 3 秒看一眼**原始进度**动没动；只要在动就一直等（绝不打扰）；
    ///   连续 40 秒一动不动才提示一句 —— 而且**只提示，绝不碰任何界面状态**。
    @MainActor private func startLoadTimeout(_ t: BrowserTab) {
        loadTimeoutTask?.cancel()
        lastProgressTick = Date()
        lastEstimatedProgress = -1
        let target = self
        loadTimeoutTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                // 切走了就别管了（tick 只跟当前标签走，留着会误判成"卡住"）
                guard t === target.currentTab else { return }
                guard t.isLoading else { return }                 // 加载完了 → 收工
                if Date().timeIntervalSince(target.lastProgressTick) >= 40 {
                    target.showToast("这一页好像不动了 —— 可以点刷新重试", seconds: 3)
                    return
                }
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

    /// ★ v1.0.224：下拉刷新被触发（挂在每个 WebView 自带滚动视图上的那个系统控件）。
    ///   · 轻震一下 —— 这是本次新增的**唯一一个新交互**，震动能明确告诉用户"这一下拉到了"。
    ///   · 圈延后 0.35 秒收：真实的加载进度由顶部那条 2pt 进度线表示，
    ///     两个一起转反而乱；留一点点时间是为了让"确实刷新了"这件事**看得见**。
    @objc private func onPullToRefresh(_ sender: UIRefreshControl) {
        Haptics.tap()
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            sender.endRefreshing()
        }
    }

    /// 手动催一次扫描（面板下拉刷新用）
    func forceScan() {
        webView?.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
        showToast("已重新扫描")
    }

    /// 静默扫一次（不弹提示）—— 打开嗅探面板时用。
    /// 自动扫描默认关了，所以「用户点开面板」这个动作本身就是「现在需要嗅探」。
    func scanQuietly() {
        webView?.evaluateJavaScript("window.__vgScan ? window.__vgScan() : 0") { _, _ in }
    }

    /// ★ v1.0.109：用户切到「图片」tab —— 打开图片上报 + 扫一次当前页面的图片。
    /// 图片平时**不收也不上报**（一页几十上百张，白花跨进程开销），
    /// 所以"切过来"这个动作本身就是"现在要"的信号。
    func loadImages() {
        webView?.evaluateJavaScript(
            "window.__vgSetImages ? window.__vgSetImages(true) : 0") { _, _ in }
    }

    /// 离开「图片」tab —— 关掉上报（结果留着，不清）。
    func stopImages() {
        webView?.evaluateJavaScript(
            "window.__vgSetImages ? window.__vgSetImages(false) : 0") { _, _ in }
    }

    /// 设置里改了「后台自动嗅探」→ 通知**所有已经建好的页面**立刻生效，
    /// 不用刷新页面（新开的页面在注入时就带上正确的值，见 snifferSource）。
    func applyAutoSniffSetting() {
        let on = autoSniffOn ? "true" : "false"
        let js = "window.__vgSetAuto ? window.__vgSetAuto(\(on)) : 0"
        for t in tabs {
            guard let wv = t.webView else { continue }   // 还没建过 WebView 的标签不用管
            wv.evaluateJavaScript(js) { _, _ in }
        }
    }

    /// 设置里改了「网页媒体自动播放」→ 通知**所有已打开的页面立刻生效**。
    ///
    /// ★★ 为什么非得靠这一层（v1.0.234 修的真 bug）：
    ///   系统那个属性（`mediaTypesRequiringUserActionForPlayback`）是**建 WebView 时读一次的**，
    ///   之后改不动 —— `wv.configuration` 拿到的是**副本**，改它没用。
    ///   所以只靠系统那层的话，用户改完设置**必须重开标签**才生效
    ///   （上一版我在说明里写"重载一次也行"，**那句是错的**，重载不会重建 WebView）。
    ///   JS 这层改的是变量，一调就立刻生效。
    func applyAutoplaySetting() {
        let a = WebAutoplay.current
        let js = "window.__vgAutoSet ? window.__vgAutoSet("
            + (a.blockAudio ? "true" : "false") + ", "
            + (a.blockVideo ? "true" : "false") + ") : 0"
        for t in tabs {
            guard let wv = t.webView else { continue }
            wv.evaluateJavaScript(js) { _, _ in }
        }
    }

    // ★ v1.0.238：`applyAdCleanSetting()`（运行时用 `__vgCleanSet` 开关清理）**已删除** ——
    //   广告清理的"总开关"撤了，改成**按站名单**（见 `SiteRules.adCleanOn`）；
    //   而名单是**建 WebView 时的快照**，所以改名单必须**刷新页面**才生效，
    //   不存在运行时通道（设置页里已写明这一点）。

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
        images.removeAll()
        imageGroups.removeAll()
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

    // MARK: - ★ v1.0.119 首页 / 桌面模式 / 无图模式 / 截长图

    /// 该不该显示「首页快捷入口」。
    /// 条件 = 当前标签**还没打开任何网页**（地址还是空的）而且不在加载 —— 也就是新建的空白标签。
    /// · 设置里填了「主页地址」时不会走到这儿：那种情况新标签直接开那个网址（见 openStartPage）。
    /// · 打开任何网页后地址就不空了 → 首页自动消失，不需要额外记"首页开着/关着"这种状态。
    var showHomePage: Bool {
        guard !isLoading else { return false }
        // ★ v1.0.120：**不管设置里有没有填主页，新建的标签都显示首页**。
        //   用户把两个概念明确分开了（我上一版理解错了）：
        //     · **主页** = 设置里填的那个地址 → 只在**程序启动进页面**时加载一次（见 openStartPage）
        //     · **首页** = 这个快捷入口页 → **新建标签**进来就是它
        guard let t = currentTab else { return true }
        return t.address.isEmpty
    }

    /// 设置里的「主页地址」（规范化后的整串；没设、或写得不合法 = nil）
    /// 跟 openStartPage 用的是同一套规则：不带协议就补 https://
    static var homePageURL: String? {
        var s = (UserDefaults.standard.string(forKey: "homePageURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s) == nil ? nil : s
    }

    /// 桌面模式是否打开（建 WebView 时也读它）
    var desktopUAOn: Bool { UserDefaults.standard.bool(forKey: Self.desktopUAKey) }
    static let desktopUAKey = "desktopUA"

    /// 移动版 Safari（默认 UA）
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    /// 桌面版 Safari（Mac）
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    static func userAgent(desktop: Bool) -> String { desktop ? desktopUA : mobileUA }

    /// 切「桌面模式」：所有活着的 WebView 都换 UA（**必须重载才生效**）
    func toggleDesktopUA() {
        let on = !desktopUAOn
        UserDefaults.standard.set(on, forKey: Self.desktopUAKey)
        let ua = Self.userAgent(desktop: on)
        for t in tabs where t.webView != nil { t.webView?.customUserAgent = ua }
        currentTab?.webView?.reload()
        objectWillChange.send()          // 工具箱/首页上的"开/关"字样要立刻跟着变
        showToast(on ? "桌面模式：已按电脑版加载" : "桌面模式：回到手机版")
    }

    /// 切「无图模式」：图片请求在网络层被拦掉（**必须重载才生效**）
    func toggleNoImage() {
        let on = !NoImageMode.isOn
        UserDefaults.standard.set(on, forKey: NoImageMode.key)
        if on {
            // 规则可能还在编译（首次）→ 编译好再挂，然后重载
            NoImageMode.ruleList { [weak self] list in
                guard let self, list != nil else { return }
                for t in self.tabs {
                    if let wv = t.webView { NoImageMode.apply(to: wv, on: true) }
                }
                self.currentTab?.webView?.reload()
                self.showToast("无图模式已开：图片不再下载")
            }
            showToast("正在准备拦截规则…")
        } else {
            for t in tabs {
                if let wv = t.webView { NoImageMode.apply(to: wv, on: false) }
            }
            currentTab?.webView?.reload()
            showToast("无图模式已关")
        }
        objectWillChange.send()
    }

    /// 导出结果的落盘文件（PDF 一份；选了"顺带转图片"就是两份）。
    /// 非空 → 界面把它交给系统分享面板（存文件 / 发微信 / 存相册都走它）
    @Published var pagePDFResult: [URL]?

    /// ★ v1.0.122：正在导出 —— 防重入（渲染期间再点一次会互相打架）
    private var exportingPDF = false

    /// 把当前整页导出成**矢量** PDF；asImage = 顺带转一张长图。
    /// 为什么要转图：PDF 在微信里只能当"文件"发（对方得点开）；
    /// 图片能直接在聊天里看到、也能存相册 —— 用户自己按场合选。
    func exportPagePDF(asImage: Bool = false) {
        guard !exportingPDF else {
            showToast("上一份还在导出，稍等一下")
            return
        }
        guard let wv = currentTab?.webView else {
            showToast("现在没有打开的网页")
            return
        }
        exportingPDF = true
        showToast(asImage ? "正在导出 PDF 和图片，页面越长越慢…" : "正在导出 PDF，页面越长越慢…")
        PagePDF.capture(wv) { [weak self] result in
            guard let self else { return }
            self.exportingPDF = false
            switch result {
            case .success(let out):
                self.finishPagePDF(out, asImage: asImage)
            case .failure(let e):
                self.showToast(e.localizedDescription)
            }
        }
    }

    private func finishPagePDF(_ out: PagePDF.Output, asImage: Bool) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let base = Self.pdfName(from: pageTitle)
        let pdfURL = JobStore.file(named: "\(base)-\(stamp).pdf")
        do {
            try out.data.write(to: pdfURL, options: .atomic)
        } catch {
            showToast("PDF 存不下来（磁盘可能满了）")
            return
        }

        let head: String = {
            var m = "PDF 已生成 \(out.widthPts)×\(out.heightPts) 点 · \(max(1, out.data.count / 1024)) KB"
            if out.pages > 1 { m += " · \(out.pages) 页" }
            if out.veryLong { m += "\n页面很长，是一整页的大 PDF（有些阅读器会缩得很小）" }
            return m
        }()

        guard asImage else {
            pagePDFResult = [pdfURL]                  // 界面收到就弹分享面板
            showToast(head)
            return
        }

        // 转图是 CPU 活（几千万像素），**丢后台**，别把界面卡住。
        // 渲染只碰 CoreGraphics / UIImage，不碰 UI，所以放后台是安全的。
        showToast(head + "\n正在转图片…")
        let data = out.data
        let jpgURL = JobStore.file(named: "\(base)-\(stamp).jpg")
        // ★ 跨队列只传 let：`var` 被并发闭包捕获在 Swift 6 里是**错误**
        //   （run #125 的日志里为此报了两条警告，这里收干净）。
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PagePDF.rasterize(data)
            let jpg = img?.jpegData(compressionQuality: 0.9)
            let wrote: Bool
            if let jpg { wrote = (try? jpg.write(to: jpgURL, options: .atomic)) != nil }
            else { wrote = false }
            let px = Int(((img?.size.width ?? 0) * (img?.scale ?? 1)).rounded())
            let py = Int(((img?.size.height ?? 0) * (img?.scale ?? 1)).rounded())
            let kb = jpg.map { max(1, $0.count / 1024) } ?? 0
            let tail = wrote ? "\n图片 \(px)×\(py) 像素 · \(kb) KB"
                             : "\n图片没转出来（页面太大或太复杂），PDF 是好的"
            let urls = wrote ? [pdfURL, jpgURL] : [pdfURL]
            // ★ weak self 只挂在内层（主队列）这一层 —— 挂在外层同样会触发
            //   "captured var 'self'" 警告，而且外层的活根本不需要 self。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pagePDFResult = urls
                self.showToast(head + tail)
            }
        }
    }

    /// 网页标题 → 能当文件名用的短名（去掉路径分隔符这类；太长就截断）
    static func pdfName(from title: String) -> String {
        var n = title
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"] {
            n = n.replacingOccurrences(of: bad, with: "_")
        }
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count > 40 { n = String(n.prefix(40)) }
        return n.isEmpty ? "网页" : n
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
                            href: String, mse: Bool, raw: [[String: Any]],
                            imgs: [[String: Any]] = []) {
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

        // ★ v1.0.203：图片**先落到这个标签自己身上**（跟 items 完全同一个规矩）——
        //   以前只写 model，切标签时不换 → 面板显示上一个标签的图（串台）。
        //   合并的底子也要取自"这个标签自己的旧图"，不能取自 model（那可能是别的标签的）。
        var oldImgs: [String: SniffItem] = [:]
        for it in t.images { oldImgs[it.url] = it }
        t.images = Self.parseImageItems(imgs, href: href, merge: oldImgs)
        t.imageGroups = Self.makeGroups(t.images)

        guard isCurrent else { return }      // 后台标签：到此为止，不碰界面状态

        items = capped
        groups = t.groups
        images = t.images
        imageGroups = t.imageGroups
        lastUpdated = now
        mseSeen = mse
        hint = t.hint
        if address.isEmpty { address = href }
        refreshTabs()
    }

    /// 把 JS 上报的图片条目解析成 SniffItem。
    /// 字段处理与视频那条一致 —— 图片**同样要带 Referer / Cookie**，
    /// 否则防盗链的站直接给 403（这是 v1.0.106 在长按下载上踩过的同一个坑）。
    private static func parseImageItems(_ raw: [[String: Any]], href: String,
                                        merge old: [String: SniffItem]) -> [SniffItem] {
        var merged = old
        let now = Date()
        for d in raw {
            guard let url = d["url"] as? String, !url.isEmpty else { continue }
            let first = date(fromMs: d["first"]) ?? merged[url]?.first ?? now
            let last = date(fromMs: d["last"]) ?? merged[url]?.last ?? now
            var item = SniffItem(url: url,
                                 kind: (d["kind"] as? String) ?? "image",
                                 src: (d["src"] as? String) ?? "",
                                 page: (d["page"] as? String) ?? href,
                                 hits: (d["hits"] as? Int) ?? 1,
                                 first: first,
                                 last: last,
                                 playing: false)
            let ref = (d["ref"] as? String) ?? ""
            let uaStr = (d["ua"] as? String) ?? ""
            let ck = (d["ck"] as? String) ?? ""
            if !ref.isEmpty { item.referrer = ref }
            if !uaStr.isEmpty { item.ua = uaStr }
            if !ck.isEmpty { item.cookie = ck }
            if var o = merged[url] {
                o.hits = max(o.hits, item.hits)
                o.first = min(o.first, item.first)
                o.last = max(o.last, item.last)
                if !item.referrer.isEmpty { o.referrer = item.referrer }
                if !item.ua.isEmpty { o.ua = item.ua }
                if !item.cookie.isEmpty { o.cookie = item.cookie }
                merged[url] = o
            } else {
                merged[url] = item
            }
        }
        // 最近出现的排前面 —— 页面上刚显示出来的图最可能就是要找的那张
        return Array(merged.values).sorted { $0.last > $1.last }
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

    // MARK: - ★ v1.0.115 挑清晰度（懒解析）

    /// 某个条目（键 = `SniffItem.url`）**懒解析**出来的可选清晰度。
    /// 为什么不在嗅探时就解析：一个页面几十条嗅探事件，全解析等于把"浏览"的成本放大几十倍；
    /// 而且页面还在播时 token / CDN 调度未稳，早解析容易拿到过期地址。
    /// （这一条四家 AI 独立给出同一个结论。）
    @Published var variantChoices: [String: [M3U8Playlist.Variant]] = [:]
    /// 用户为某条选定的清晰度（没有键 = 自动，也就是现在这套：挑带宽最高的）
    @Published var variantPicked: [String: M3U8Playlist.Variant] = [:]
    /// 正在读清单的条目（界面转圈用）
    @Published var variantLoading: Set<String> = []
    /// 读清单失败的原因（界面一句话，绝不静默）
    @Published var variantError: [String: String] = [:]

    /// 候选怎么显示：**有分辨率才写分辨率**；只有码率就写码率。
    /// ★ 刻意**不猜**"1080P"：HEVC 低码率的可能是高清、AVC 高码率的可能只有 720P，
    ///   猜错比不标更糟（四家里三家都点了这一条）。带宽给的是"哪个大"的量级感。
    static func variantLabel(_ v: M3U8Playlist.Variant) -> String {
        if let r = v.resolution, !r.isEmpty {
            let parts = r.lowercased().split(separator: "x")
            if parts.count == 2, let h = Int(parts[1]), h > 0 { return "\(h)P" }
            return r
        }
        if let b = v.bandwidth, b > 0 {
            return String(format: "约 %.1f Mbps", Double(b) / 1_000_000)
        }
        return "线路"
    }

    /// 读一次这个清单，看看有哪些清晰度可选（用户点「清晰度」标签时才调）。
    /// 自己带 Referer/UA/Cookie —— 读清单和下载分片一样要过防盗链。
    ///
    /// ★ 取文本这一步刻意放到 `nonisolated static` 的异步函数里去做（见下面 fetchPlaylistText）：
    ///   `URLSession.dataTask` 的完成回调是 `@Sendable`，在这个回调里**再嵌**一个并发闭包
    ///   去碰 `weak self`，编译器报 `reference to captured var 'self' in concurrently-executing code`
    ///   （run #115 就挂在这）。用 `await` 走 async/await 就没这个形状，也就不踩这个坑。
    func loadVariants(for item: SniffItem) {
        loadVariants(url: item.url, referrer: item.referrer, ua: item.ua, cookie: item.cookie)
    }

    /// ★ v1.0.118：上下文改成**显式参数**（不再要求传一个 `SniffItem`）——
    ///   长按菜单那条路手里只有地址 + 页面上下文，没有嗅探条目。
    func loadVariants(url key: String,
                      referrer: String = "", ua: String = "", cookie: String = "") {
        guard !variantLoading.contains(key), let u = URL(string: key) else { return }
        variantError[key] = nil
        variantLoading.insert(key)

        var req = URLRequest(url: u, timeoutInterval: 20)
        if !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if !referrer.isEmpty { req.setValue(referrer, forHTTPHeaderField: "Referer") }
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }

        Task {                       // 继承本类的 @MainActor：await 回来就是主线程，可直接改状态
            let text = await Self.fetchPlaylistText(req)
            self.variantLoading.remove(key)
            guard let text else {
                self.variantError[key] = "读不到清单（可能是防盗链，或这条链接已经过期）"
                return
            }
            let pl = M3U8Playlist.parse(text: text, baseURL: u)
            if pl.variants.isEmpty {
                self.variantError[key] = "这条不是多清晰度清单（只有一档，直接下就行）"
            } else {
                // 带宽从大到小 —— 用户一眼看到的是"最高的那条多大"
                self.variantChoices[key] = pl.variants.sorted { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
            }
        }
    }

    /// 拉一个清单的纯文本。**不吃缓存**（清单常常带时效参数，拿旧的没用）。
    /// 写成 nonisolated：它只是网络与解码，不需要主线程，也就绕开了那条 Sendable 坑。
    nonisolated static func fetchPlaylistText(_ req: URLRequest) async -> String? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        do {
            let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard code == 0 || (200...299).contains(code) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
            return "还没嗅到东西。让视频先播几秒，然后下拉刷新一次。"
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
        // ★ v1.0.209：广告清理的诊断回传走另一条通道 —— 直接记档、**不进嗅探那套流程**
        //   （不然它会被当成嗅探结果喂给 ingest，把下载列表搞脏）。
        // ★ v1.0.236：站内换页（前端路由）→ 记一条浏览历史。
        //   它不是导航事件，是页面自己报上来的（这类跳转不触发任何原生回调）。
        //   报上来就算"记好了"，直接确认 —— 路由换页没有"加载失败"这一说，内容已经换完了。
        if message.name == "vgNav" {
            guard let d = message.body as? [String: Any],
                  let u = d["url"] as? String, !u.isEmpty else { return }
            let ti = (d["title"] as? String) ?? ""
            Task { @MainActor in
                self.onVisitBegan?(u, ti)
                self.onPageFinished?(u, ti)
            }
            return
        }
        if message.name == "vgClean" {
            AdClean.record(message.body)
            return
        }
        // ★ v1.0.214：页面视频清单 —— 只写进「这条 WebView 所属标签」的那份快照，
        //   当前标签才镜像到界面上（跟嗅探结果同一套多标签规矩，后台标签不会串上来）。
        if message.name == "vgVideos" {
            guard let d = message.body as? [String: Any] else { return }
            let list = PageVideo.parse(d)
            let src = message.webView
            Task { @MainActor in
                guard let wv = src, let t = self.tab(for: wv) else { return }
                // ★ v1.0.216：**空清单不覆盖非空清单**。
                //   播放器在 <iframe> 里的站（聚合站很常见）—— 子 frame 报的是"有视频"，
                //   主 frame 自己扫不到任何 <video>，只能报空。谁后到谁赢的话，主 frame 的
                //   一条空消息就能把按钮擦掉。换页时会先清空
                //   （见 didStartProvisionalNavigation），所以"视频没了按钮还在"最多残留到下次导航。
                if list.isEmpty && !t.pageVideos.isEmpty { return }
                t.pageVideos = list
                let isCur = (t === self.currentTab)
                if isCur { self.pageVideos = list }
                // ★ v1.0.226：顺手记进「视频历史」。
                //   用户要的是「**网页里出现过就记**，不是播过才记」→ 写入点就在这儿，
                //   不在播放入口（播放只负责给已记的那条补一个 played 标记）。
                //   `playable` 只在**当前标签**才敢算 —— `pageVideoPlayTarget` 读的是
                //   当前标签的嗅探结果，后台标签调它会把别的页的流算进来。
                // ★ v1.0.228：标题优先用 JS 给的**页面级标题**（og:title > h1 > document.title）——
                //   用户实测「大多显示站点名称」，就因为原来直接用 t.title（有些站它就是站名）。
                //   视频自己若带名字（vtitle），`WatchHistory.note` 里还会再优先一层。
                let page = t.address
                let ptitle = (d["ptitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t.title
                WatchHistory.shared.note(page: page, title: ptitle, videos: list) { v in
                    if isCur { return self.pageVideoPlayTarget(v)?.url }
                    return v.src.isEmpty ? nil : v.src
                }
            }
            return
        }
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
            let rawImgs = (body["images"] as? [[String: Any]]) ?? []
            self.ingest(tab: t, isCurrent: isCurrent, href: href, mse: mse,
                        raw: raw, imgs: rawImgs)
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {

    // MARK: - ★ v1.0.112：网页自己触发的「下载文件」

    /// 判定一个地址像不像"要下载的文件"（打包/安装包这类**显示不了**的类型）。
    /// 为什么不收 pdf / 图片 / 视频：那些 WKWebView **能**显示，用户点它多半是想看内容。
    ///
    /// ★ 必须写 `nonisolated`：这个类是 `@MainActor`，它的 static 方法**也**被主线程隔离，
    ///   而调用它的 `createWebViewWith` 是 `nonisolated` 的同步上下文 ——
    ///   不标就编不过（run #112 就挂在这：`call to main actor-isolated static method
    ///   'looksLikeFileDownload' in a synchronous nonisolated context`）。纯字符串判断，安全。
    nonisolated static func looksLikeFileDownload(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let e = u.pathExtension.lowercased()
        return ["exe", "msi", "zip", "rar", "7z", "tar", "gz", "xz", "dmg", "pkg",
                "apk", "ipa", "deb", "rpm", "iso", "bin", "jar", "whl", "crx", "msix"].contains(e)
    }

    /// 导航**响应**阶段：服务器回了「这是给你下载的」（`Content-Disposition: attachment`）
    /// 或者回了个 WebKit 显示不了的类型 → 取消导航，把地址交给下载中心。
    ///
    /// ★ 为什么必须自己接：WKWebView **默认不实现下载** —— 遇到这类响应
    ///   它既不下、也不报错，用户看到的就是「点了没反应」（用户实测 workdaddy.dev 即此）。
    nonisolated func webView(_ wv: WKWebView,
                             decidePolicyFor resp: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let r = resp.response
        let mime = (r.mimeType ?? "").lowercased()
        // HLS / DASH 清单不截胡：视频那条线有自己的入口（长按 / 嗅探面板），
        // 清单地址直接导航时保持原行为（交给 WebKit）
        if mime.contains("mpegurl") || mime.contains("dash+xml") {
            decisionHandler(.allow)
            return
        }
        let disposition = (r as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.contains("attachment")
        // ★ 只接管「明说了是附件」或「确实显示不了」的；
        //   正常网页、图片、PDF、能播的视频一律放行（.allow）
        guard resp.isForMainFrame, isAttachment || !resp.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        let url = r.url?.absoluteString ?? ""
        let name = r.suggestedFilename ?? ""
        decisionHandler(.cancel)
        Task { @MainActor in
            self.handOffDownload(wv: wv, url: url, name: name)
        }
    }

    /// 导航**动作**阶段：链接带 `download` 属性（含 JS 的 `a.download` + `click()`）——
    /// 此时 WebKit 只是在 action 上标了 `shouldPerformDownload`，**不会替我们落盘**。
    nonisolated func webView(_ wv: WKWebView,
                             decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // ★ v1.0.225：网页黑名单 —— **只拦主文档**（子资源不拦：那是广告拦截的活，别越界）。
        //   放在最前面：被拉黑的站，连"下载"那条路也不该走通。
        //   `targetFrame == nil` 的那种（`target="_blank"`）单独在 createWebViewWith 里管。
        if action.targetFrame?.isMainFrame == true,
           let u = action.request.url,
           let rule = BlockList.hit(u.host ?? "") {
            decisionHandler(.cancel)
            Task { @MainActor in
                self.showBlocked(wv, url: u, rule: rule)
            }
            return
        }
        // ★★ v1.0.238：**这里不再问"链接怎么打开"**。
        //   原来（v1.0.236）是"手点跨站链接 → 弹在本页/新标签"，用户实测后判定
        //   **不是他要的东西** —— 他要的是「**网页自己开弹窗**」时那个菜单
        //   （"当前网页触发了弹出式窗口"），那条走的是**另一条路**：
        //   `createWebViewWith`（`target="_blank"` / `window.open`）。
        //   所以这里恢复成最朴素的行为：**放行**，页内正常跳转、不打扰。
        guard action.shouldPerformDownload else {
            decisionHandler(.allow)
            return
        }
        let url = action.request.url
        let s = url?.absoluteString ?? ""
        // blob: / data: 是**页面里临时生成**的，URLSession 根本抓不到 →
        // 这一版给一句明确提示：下不了也要让用户知道为什么，别静悄悄没反应
        if s.hasPrefix("blob:") || s.hasPrefix("data:") {
            decisionHandler(.cancel)
            Task { @MainActor in
                self.showToast("这个是网页临时生成的文件（blob），当前版本还下不了")
            }
            return
        }
        decisionHandler(.cancel)
        Task { @MainActor in
            self.handOffDownload(wv: wv, url: s, name: url?.lastPathComponent ?? "")
        }
    }

    /// 把一次「网页要下载」的请求交给上层（ContentView 接到下载中心）。
    /// 上下文在这里补齐 —— 对齐 v1.0.106 的教训：
    /// **Referer 用当前页面地址**（防盗链校验的是"从哪个页面发的"），不是 `document.referrer`。
    private func handOffDownload(wv: WKWebView, url: String, name: String) {
        guard !url.isEmpty else { return }
        let page = tab(for: wv)?.address ?? wv.url?.absoluteString ?? ""
        let referrer = (page.isEmpty || page == "about:blank") ? "" : page
        let ua = wv.customUserAgent ?? ""
        // Cookie 走 WebKit 自己的仓（**含 HttpOnly** —— document.cookie 拿不到那些）
        let host = URL(string: url)?.host ?? ""
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let line = cookies.filter { c in
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return !host.isEmpty && !d.isEmpty && (host == d || host.hasSuffix("." + d))
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
            Task { @MainActor in
                guard let cb = self.onFileDownload else {
                    self.showToast("这个文件没接上保存通道，先没下")
                    return
                }
                cb(FileDownloadRequest(url: url, name: name, referrer: referrer,
                                       ua: ua, cookie: line))
                self.showToast("已加入下载")
            }
        }
    }

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
            // ★ v1.0.216：换页了 —— 上一页的页面视频清单立刻作废（配合 vgVideos 那条
            //   "空清单不覆盖非空清单"：不然视频没了按钮会一直留着）。
            t.pageVideos = []
            if t === self.currentTab {
                self.pageVideos = []
                self.isLoading = true
            }
            self.clearLoadError(t)      // 又开始加载了 → 上一页的错误页收掉
            self.startLoadTimeout(t)
        }
    }

    /// 内容开始到达（比 didFinish 早得多）—— 地址和前进后退状态**这时候就更新**，
    /// 对齐 Safari 的做法：地址先变，页面慢慢来。
    nonisolated func webView(_ wv: WKWebView, didCommit n: WKNavigation!) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            // ★ v1.0.242：换页了 → "这一页已经问过几次弹窗"的额度归零（每页各算各的）
            self.popupAskCount = 0
            if let u = wv.url?.absoluteString, !u.isEmpty {
                t.address = u
                if t === self.currentTab { self.address = u }
            }
            self.clearLoadError(t)      // 内容开始到达 → 确实打开了
            // ★ v1.0.236：历史从这一刻就记（"开始加载就记"）——
            //   地址此时一定已经是新的，而且比 didFinish 早得多：
            //   永远加载不完的页（长轮询 / 流媒体）也能记上，不再整类漏。
            //   ★ 先把同一个标签上一条"没等到结果"的撤掉：标签内导航是串行的，
            //     新的开始 ⇒ 上一条要么已完成要么被替换 —— 重定向链因此只留最后一跳。
            let vkey = ObjectIdentifier(wv)
            if let old = self.pendingVisit[vkey], old != t.address {
                self.onVisitFailed?(old)
            }
            self.pendingVisit[vkey] = t.address
            self.onVisitBegan?(t.address, t.title)
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

            // 崩太多次了 → 不再自动重载（摆错误页，由用户决定要不要再来）
            if t.crashCount >= TabLimits.maxCrashReloads {
                if t.crashCount == TabLimits.maxCrashReloads {
                    t.crashCount += 1
                    t.isLoading = false
                    t.loadError = PageError.crashGaveUp(url: t.address,
                                                        attempts: TabLimits.maxCrashReloads)
                    if t === self.currentTab {
                        self.isLoading = false
                        self.progressActive = false
                        self.progress = 0
                        self.loadError = t.loadError
                        self.showToast("这页总是崩，先不自动恢复了 —— 点「重试」再试一次")
                    }
                }
                return
            }

            t.crashCount += 1

            // ★ 没有地址可恢复（空白标签）：**不能一声不吭** —— 那用户看到的就是"点了没反应"
            guard recoverable else {
                t.isLoading = false
                if t === self.currentTab {
                    self.isLoading = false
                    self.showToast("页面出了点问题，已回到起始页")
                    self.openStartPage()
                }
                return
            }

            // ★★ v1.0.205：**静默恢复**。
            //   以前每次自动重载都会弹一句提示（大意是"页面被回收、正在恢复"）——
            //   用户看到的是"页面自己白了一下又好了，还附一句看不懂的话"。
            //   现在：只把"在加载"标出来（底栏自动显示「停止」、进度条自己走），
            //   页面重载回来就完事，**不弹任何提示**；只有上面"崩到放弃"才出声。
            //   顺手清掉上一次的错误页（不然重载期间它还盖在页面上）。
            t.loadError = nil
            t.isLoading = true
            if t === self.currentTab {
                self.isLoading = true
                self.loadError = nil
            }
            wv.reload()
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
            // ★ v1.0.236：**所有标签**都要"确认"这次访问（历史那一笔留着不撤）。
            //   原来这一句在下面的 `if t === currentTab` 里 —— 那会让后台标签的
            //   待确认记录一直挂着，等它下次导航时被当成"上次没成的"撤掉，等于白记。
            self.pendingVisit[ObjectIdentifier(wv)] = nil
            self.onPageFinished?(t.address, t.title)
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
            }
            // ★ v1.0.104：这里原来会「加载完补扫一次」（上面那条注释说得对：
            //   有些地址是 DOM 造好之后才有的）。但那是**自动**扫，跟默认关矛盾 ——
            //   改由用户打开嗅探面板时扫，一样能拿到（见 scanQuietly）。
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

    /// ★★ v1.0.241：**问一句"这个弹出窗口怎么打开"**。
    ///
    /// 触发：**网页自己开了一个弹窗**（`target="_blank"` / `window.open`），见 `createWebViewWith`。
    /// 所以手点普通链接**不走这儿**；也**不需要站点名单** —— 不开弹窗的站天然看不到它。
    ///
    /// ══ 为什么从 UIAlertController 改成 SwiftUI 弹层（v1.0.241，用户实测反馈）══
    ///   老写法是「找宿主控制器 → `present(UIAlertController)`」，**在这个 App 里根本弹不出来**：
    ///     · `dialogHost()` 的条件是"必须是当前标签 **且** 没在弹别的"；
    ///     · 顶层控制器上已经有我们自己的 sheet（设置 / 嗅探面板 / 下载页 / 分享都是 sheet），
    ///       这时 `present` 会**静默失败**；
    ///     · 一旦失败，那个 `UIAlertController` 里几个 action 的回调**永远不会执行** →
    ///       `dialogBusy` 永久卡在 `true` → **之后所有弹窗都走静默分支**（悄悄开个后台标签）。
    ///   结果：这个菜单从做出来（v1.0.237）到 v1.0.240，**一次都没显示过**
    ///   —— 用户只看到过 toast（「已阻止…」），从没见过菜单。
    ///   → 现在改成**发一个状态出去**（`popupAsk`），由界面用 SwiftUI 的 `.alert` 显示
    ///      （见 `ContentView`）。这条路不依赖 UIKit 的 present 链路，界面在就一定能弹。
    @MainActor
    private func askPopup(_ wv: WKWebView, url: URL, req: URLRequest) {
        // 已经有一个在问 → 后面来的自己吞掉（不刷屏，也避免一次点击开出一串标签）
        guard popupAsk == nil else { return }
        // ★★ v1.0.242：**同一次页面加载最多问 3 次**。脏站会连环弹广告，问到第 4 个
        //   基本可以确定不是你要的了 → 静默忽略（不提示，免得又变成"刷屏"）。
        //   ★ 这是"防刷屏"，**不是"阻止网页弹窗"** —— 用户明确要求把"阻止"去掉，
        //     所以别把它写回成"拦掉 + 提示"。
        guard popupAskCount < 3 else { return }
        popupAskCount += 1
        pendingPopupWebView = wv
        pendingPopupRequest = req
        pendingPopupURL = url
        popupAsk = PopupAskInfo(url: url.absoluteString)
    }

    /// 用户在菜单上选了哪一个（由 `ContentView` 的弹层调回来）。
    ///
    /// ★ 幂等：弹层那边（点按钮 / 点取消 / `isPresented` 回落）可能**重复调**，
    ///   所以一进来就把现场清空 —— 第二次调用什么都不做。
    @MainActor
    func answerPopup(_ a: PopupAnswer) {
        let wv = pendingPopupWebView
        let req = pendingPopupRequest
        let url = pendingPopupURL
        pendingPopupWebView = nil
        pendingPopupRequest = nil
        pendingPopupURL = nil
        popupAsk = nil
        guard let wv, let url else { return }
        switch a {
        case .inPlace:
            // ★ 复用原 request（自带 Referer / UA）：自己拼 `URLRequest(url:)` 是没有
            //   Referer 的，有些站会直接拒、或者跳回首页。实在没有才退回裸地址。
            // ★ 这条路跟 `decidePolicyFor` 无关（弹窗走的是 `createWebViewWith`），
            //   所以不需要任何"放行一次"的标记。
            wv.load(req ?? URLRequest(url: url))
        case .newTab:
            _ = newTab(load: url.absoluteString)
        case .background:
            _ = newTab(load: url.absoluteString, background: true)
            showToast("已在后台打开")
        case .cancel:
            break
        }
    }

    // ★★ v1.0.242：原来这里有 `decidePopup`（判"该问还是该拦"）和 `noticePopupBlocked`
    //   （拦掉 + 提示「已阻止…」）。**两个都删了**，因为：
    //     ① 那个判据（网页侧的"这个页面被碰过没有"）**在 iframe 里传不出来** ——
    //        聚合站的视频卡片正好常在 iframe 里，于是"手点"也被判成"没碰过" →
    //        弹窗被拦 → 用户只看到「已阻止…」、点了进不去（2026-10-09 第二次实测，白烧一版）；
    //     ② 用户明确要求"**关掉这个阻止弹窗**"。
    //   → 现在**所有网页弹窗一律弹菜单**（见 `createWebViewWith` → `askPopup`）：
    //     要不要打开由他自己定（选"取消"就等于不打开，"阻止"这件事交给他）。
    //     防刷屏改在 `askPopup` 里做（同一次页面加载最多问 3 次），**不再有"阻止"这个行为**。

    /// ★ v1.0.236：把这个标签"还没等到结果的那次访问"撤掉 ——
    ///   历史里刚记的那一笔（见 `onVisitBegan`）不该留在一个没打开的页面上。
    private func dropPendingVisit(_ wv: WKWebView) {
        let key = ObjectIdentifier(wv)
        guard let url = pendingVisit.removeValue(forKey: key) else { return }
        onVisitFailed?(url)
    }

    nonisolated func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            // ★ v1.0.236：这一页没打开成 → 撤掉刚记的那一笔。
            //   **"被取消"不撤** —— 那多半是他又点了别的、或被新导航打断，
            //   下一条的 didCommit 已经接管（pending 已换成新的），
            //   在这儿无脑撤会把新那条也一起撤掉。
            if !Self.isCancelled(e) { self.dropPendingVisit(wv) }
            self.handleLoadFailure(t, error: e)
        }
    }

    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        Task { @MainActor in
            guard let t = self.tab(for: wv), n !== t.warmupNav else { return }
            if !Self.isCancelled(e) { self.dropPendingVisit(wv) }
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

    /// 网页要求「开新窗口」的链接（`target="_blank"` / `window.open`）。
    ///
    /// ★★ v1.0.238：**这里改成"问一句"**（用户 2026-10-09 拍板，照他给的截图）：
    ///   菜单 = 「当前网页触发了弹出式窗口」+ 地址 + 三个选项
    ///   （当前窗口加载 / 新窗口打开 / 后台窗口打开）。
    ///
    /// ★ 跟 v1.0.236 那套（"手点跨站链接问在本页还是新标签"）**不是一回事** ——
    ///   那套问的是"**你点的那个链接**去哪打开"，已经在 `decidePolicyFor` 里撤掉了；
    ///   这一套问的是"**网页自己要弹的那个窗**怎么办"。触发者不同，所以也别混在一起。
    ///
    /// 两类分开处理（判据用 WebKit 自己给的 `navigationType`）：
    ///   · **有用户手势**（`.linkActivated`）→ **弹菜单**让他选；
    ///   · **没有手势**（广告自己弹的 `window.open`）→ **拦掉** + 提示"已阻止"
    ///     （用户选的处理方式），同一次页面加载只提示一句。
    ///
    /// 返回 `nil` = 不把这个 WebView 交给 WebKit —— 开不开标签、在不在本页加载，我们自己说了算。
    nonisolated func webView(_ wv: WKWebView,
                             createWebViewWith cfg: WKWebViewConfiguration,
                             for action: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        // ★ v1.0.225：黑名单在"新窗口"这条路上同样要拦 ——
        //   否则点一个指向黑名单站的链接，照样会开个新标签进去（拦了主文档却漏了这条路）。
        if action.navigationType == .linkActivated, BlockList.blocks(url.absoluteString) {
            Task { @MainActor in
                self.showBlocked(wv, url: url, rule: BlockList.hit(url.host ?? "") ?? "")
            }
            return nil
        }
        // ★ v1.0.112：这个"新窗口"其实是要下文件 → 不开标签，直接交给下载器。
        //   不这么做的话：新标签会去加载附件 → 被响应阶段取消 → **白留一个空标签**。
        if action.shouldPerformDownload || Self.looksLikeFileDownload(url.absoluteString) {
            Task { @MainActor in
                self.handOffDownload(wv: wv, url: url.absoluteString,
                                     name: url.lastPathComponent)
            }
            return nil
        }
        // ★★ v1.0.242：**不问任何东西，直接弹菜单**。
        //   走过的弯路（都实测翻过车，别再回去）：
        //     · v1.0.238 拿 `navigationType == .linkActivated` 判"手点" → 手点视频卡片时
        //       WebKit **根本不给**这个标记 → 正常跳转被拦；
        //     · v1.0.240 改用网页侧的"这个页面被碰过没有" → 那个标记**在 iframe 里传不出来**
        //       （视频卡片正好常在 iframe 里）→ 照样被判成"没碰过" → 照样拦。
        //   → 结论：**在原生侧没法可靠区分"手点弹窗"和"广告弹窗"，别再造判据了。**
        //     一律问用户：要不要开由他定，选"取消"就等于不打开（"阻止"交给他）。
        //     脏站连环弹的刷屏由 `askPopup` 里的**次数上限**挡，不靠"阻止"。
        //   传整个 `action.request`（不是只传 URL）：选"当前窗口加载"时要**原样重发**，
        //   原 request 自带 Referer / UA，自己拼会被防盗链的站拒掉。
        let req = action.request
        Task { @MainActor in
            self.askPopup(wv, url: url, req: req)
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

        // ★ v1.0.106：页面上下文（Referer / UA / Cookie）—— 探测时脚本顺手取回来的。
        //   防盗链站就靠它；没有它服务器不给内容（正是「地址获取不到内容」的真因）。
        let ctx = (d["ctx"] as? [String: Any]) ?? [:]
        let cRef = (ctx["ref"] as? String) ?? ""
        let cUA = (ctx["ua"] as? String) ?? ""
        let cCk = (ctx["ck"] as? String) ?? ""
        out.append("上下文  Referer \(cRef.isEmpty ? "无" : "有")   Cookie \(cCk.isEmpty ? "无" : "有")")

        // ★ v1.0.105：长按拿到的不一定是能下的地址 —— MSE 播放器的 currentSrc 是
        //   `blob:` 临时地址，只在页面里有效，交给下载器必然「拿不到内容」。
        //   抓请求那一半一直在记（不受自动嗅探开关影响），所以脚本会给一个备选地址。
        var finalURL = url
        var hint: String? = nil
        if !BrowserModel.directlyDownloadable(url) {
            let alt = (d["alt"] as? String) ?? ""
            if !alt.isEmpty {
                finalURL = alt
                hint = "这个播放器用的是临时地址，已改用抓到的真实地址"
                out.append("改用备选地址  \(BrowserModel.briefURL(alt))")
            } else {
                hint = "这个地址不能直接下载（多半是临时地址），让它播几秒再长按一次"
                out.append("地址不能直接下，而且暂时没有备选")
            }
        }
        out.append("弹菜单  域名=\(host)  标题=\(title.prefix(24))")
        finishLPDebug(out)

        lpMenu = LongPressMenuInfo(point: point, url: finalURL,
                                   title: title.isEmpty ? pageTitle : title,
                                   host: host, hint: hint,
                                   referrer: cRef, ua: cUA, cookie: cCk)
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

    /// 这个地址能直接交给下载器吗？
    ///
    /// ★ v1.0.105：`blob:` / `data:` 这类**只在页面里有效**，网络层取不到内容 ——
    ///   而长按恰好很容易拿到它们（MSE 播放器的 `currentSrc` 就是 `blob:`）。
    ///   所以换地址之前先问一句。
    static func directlyDownloadable(_ s: String) -> Bool {
        guard let u = URL(string: s), let sc = u.scheme?.lowercased() else { return false }
        return sc == "http" || sc == "https"
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
        // ★ v1.0.106：带上上下文走新回调（老回调只收地址，拿不到页面上下文）
        if let f = onLongPressDownload {
            f(m)
        } else {
            onDownloadRequest?(m.url)
        }
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
