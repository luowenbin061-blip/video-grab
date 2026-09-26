import Foundation
import UIKit
import WebKit

/// 一个标签的「档案」。
///
/// ★ v1.0.82 架构改造 —— 为什么长这样：
///   需求是「像 Safari 一样能开几十个标签」。但一个 WKWebView 光渲染进程就几十 MB，
///   几十个同时开着必然被系统杀掉。所以拆成两层：
///     · **档案**（就是这个类）：标题、地址、缩略图、嗅探快照、能不能前进后退……
///       没有 WebView 也完整存在。
///     · **活的 WebView**：最多只有 `TabLimits.maxLive` 个档案同时持有它。
///       其余档案处于「休眠」（webView == nil），点回去时现建一个、加载它的地址。
///   于是"开几十个标签"是真的能做到；代价是点回旧标签要重新加载一次页面
///   —— Safari 的「标签页卸载」也是这个行为，不是我们偷工减料。
@MainActor
final class BrowserTab {

    /// 稳定标识 —— 界面靠它认标签。
    /// ★ 不能再用下标：关掉一个之后后面所有下标集体前移，异步回调里拿到的旧下标会指错人。
    /// ★ 可注入（v1.0.83）：重启恢复时要用存档里那个 id，不能重新生成 ——
    ///   组里存的、缩略图文件名用的都是它。
    let id: UUID

    init(id: UUID = UUID()) { self.id = id }

    /// 当前挂在这个档案上的 WebView。**nil = 休眠**（网页没在跑，档案还在）。
    var webView: WKWebView?

    /// 建 WebView 时那次「预热空白页」的导航。它的回调整段忽略 ——
    /// 否则会闪一下加载态，还会把 about:blank 写进标题和地址栏。
    var warmupNav: WKNavigation?

    /// ★ KVO 观察（进度 / 地址 / 标题）。
    /// 为什么必须存起来：`observe(...)` 返回的 observation 一旦没人持有，观察立刻失效。
    /// 它是绑在**那个 WebView**上的 —— 所以休眠时 invalidate，唤醒时重建。
    var observations: [NSKeyValueObservation] = []

    // MARK: - 页面状态快照（切回来时原样恢复）

    var title = ""
    var address = ""
    var items: [SniffItem] = []
    var groups: [SniffGroup] = []
    var mseSeen = false
    var hint: String?
    var lastUpdated: Date?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// 这个窗口「打不开」的原因。非空 = 界面上该显示整页错误页。
    /// 存在标签里（而不只是全局状态）—— 后台窗口加载失败时切回去也要看得到。
    var loadError: PageError?

    // MARK: - 网格用的缩略图

    /// 缩略图。**只在它正显示着的时候截** —— 后台/休眠的 WebView 截出来是空白。
    var thumb: UIImage?
    /// 截图时间（用来做「最多留 N 张」的裁剪）
    var thumbAt: Date?

    /// 渲染进程崩了几次还没恢复（v1.0.86）。
    /// ★ 为什么要记：崩溃后我们会自动重载，但**原本没有上限** —— 遇到那种稳定把
    ///   内核搞崩的页面，就是"崩 → 重载 → 崩"的死循环，风扇起飞、电量狂掉。
    ///   页面正常加载完成（didFinish）会清零；用户手动点「重试」也会清零。
    var crashCount = 0

    /// 最近一次被用到的时间 —— 休眠谁、留谁，按这个排
    var lastActiveAt = Date()

    /// 网页是不是正在跑（有 WebView）
    var isAwake: Bool { webView != nil }

    /// 标签条上显示的名字：标题 → 域名 → 「新标签页」
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let h = URL(string: address)?.host, !h.isEmpty { return h }
        return "新标签页"
    }

    /// 「没用过的空窗口」—— 到上限要回收时，优先丢这种，别丢用户正在看的
    var isPristine: Bool {
        (address.isEmpty || address == "about:blank") && items.isEmpty
    }
}

/// 给界面看的标签快照（值类型）。
///
/// ★ 为什么不让界面直接读 BrowserTab：它是个 class、属性不是 @Published ——
///   标题或缩略图变了，SwiftUI 不会刷新。这里做成「值类型的镜像」，
///   有变化就整体换一份，界面自然跟着刷。
struct TabSnapshot: Identifiable {
    let id: UUID
    let title: String
    let address: String
    let thumb: UIImage?
    let isCurrent: Bool

    /// 网格卡片下面那行小字：域名（认不出就退到地址）
    var subtitle: String {
        if let h = URL(string: address)?.host, !h.isEmpty { return h }
        return address.isEmpty ? "空白页" : address
    }
}

/// 标签相关的三个上限，集中放一处方便调。
enum TabLimits {
    /// 标签总数上限。
    /// 不是「同时跑几个」，是「能存几个档案」—— 真正同时跑的上限看 maxLive。
    /// Safari 能开几百；30 对日常够用，再多网格也翻不动了。
    static let maxTabs = 30

    /// 同时「活着」（有 WebView）的标签上限。
    /// ★ 为什么是 3：一个 WebView 几十 MB。3 个是「够快切回最近用过的、又不至于被
    ///   系统连累着杀」的量。调大会更好切，但每个都在吃内存。
    static let maxLive = 3

    /// 最多留几张缩略图。每张约 0.5 MB（已经缩过），留太多照样吃内存。
    static let maxThumbs = 15
    /// 一个标签「崩了自动重载」最多试几次（v1.0.86）。
    ///
    /// ★ 为什么要有这个数：不设上限时，页面稳定把渲染进程搞崩 → 自动重载 → 又崩……
    ///   无限循环。Safari 也会自动重载，但它崩几次就放弃 —— 这里对齐（3 次）。
    static let maxCrashReloads = 3

    /// 一个标签最多记多少条嗅探结果（v1.0.85）。
    ///
    /// ★ 为什么要有这个上限：那份列表**只增不减** —— 去重是按 URL 做的，但不同 URL 会一直
    ///   往里加，而全项目只有「点刷新」会清它（切标签、切组、页面重新加载都不清）。
    ///   刷短视频那种「一滑一个新视频」的站点，挂一晚上能攒几千条。
    ///   排序已经保证「hls 优先、同类里最近的在前」，所以从头截断留下的正是最有用的那批。
    static let maxSniffItems = 300
}
