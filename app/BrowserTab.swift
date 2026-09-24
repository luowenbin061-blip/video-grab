import Foundation
import WebKit

/// 一个标签（一个浏览窗口）。
///
/// ★ 为什么要有这个类：原来 BrowserModel 直接持有一个 webView，而且它是 `weak` ——
///   靠界面上的 BrowserView 撑着。多标签之后，后台标签没有任何视图持有它，
///   弱引用会立刻被回收（页面被销毁、嗅探全丢）→ 所以这里必须**强引用**自己的 WebView。
///
/// ★ 每个标签各自存一份嗅探快照：后台标签的页面还在跑 JS、还在往上报告，
///   那些报告不能直接写进界面状态 —— 否则你在 A 页面上会看到 B 页面
///   （后台正在跑的那个）嗅出来的地址。
@MainActor
final class BrowserTab {

    let webView: WKWebView

    /// 建这个标签时立刻加载的那次空白页导航。它的回调整段忽略 ——
    /// 否则启动瞬间会闪一下加载态，还会把 about:blank 写进标题和地址栏。
    var warmupNav: WKNavigation?

    // MARK: - 后台快照（切回来时原样恢复）

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

    init(webView: WKWebView) {
        self.webView = webView
    }

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
