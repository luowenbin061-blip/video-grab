import Foundation
import WebKit

/// 无图模式 —— **真把图片请求掐掉**，不是把图藏起来。
///
/// 为什么不用 CSS（`img{display:none}`）：那样图**照样下载**，只是不显示，
/// 对"省流量"一点用都没有。要省流量只能在网络层拦 → 用 WebKit 的内容拦截规则
/// （`WKContentRuleList`，系统级、不加载图片就真的不占流量）。
///
/// ★ 编译是**异步**的，而建 WebView 是同步的 —— 所以：
///   · App 启动时先 `warmUp()` 把规则编译好（几毫秒到几十毫秒，放启动做最划算）；
///   · `makeRawWebView` 里同步取（`readyRuleList`），没编译好就先不加（下一次加载生效）；
///   · 用户拨开关时若还没好，会等它好了再挂 + 重载。
///
/// 规则只编译一次，`WKContentRuleListStore` 自己也有磁盘缓存（按 identifier）。
@MainActor
enum NoImageMode {

    /// UserDefaults 的键（设置/工具箱/首页都用它，只写一处）
    static let key = "noImageMode"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    private static var cached: WKContentRuleList?
    private static var compiling = false
    private static var waiters: [(WKContentRuleList?) -> Void] = []

    private static let identifier = "vg-noimage-v1"

    /// 拦掉所有 image 类型的请求（一条规则，够用）
    private static let rules = """
    [{"trigger":{"url-filter":".*","resource-type":["image"]},
      "action":{"type":"block"}}]
    """

    /// 同步取（建 WebView 时用）。没编译好返回 nil —— 那次加载就先不拦。
    static var readyRuleList: WKContentRuleList? { cached }

    /// 预热：启动时调一次
    static func warmUp() {
        guard cached == nil, !compiling else { return }
        compiling = true
        let target = WKContentRuleListStore.default()
        target?.compileContentRuleList(forIdentifier: identifier,
                                       encodedContentRuleList: rules) { list, _ in
            // 回调不保证在主线程 → 跳回主线程再改状态（@MainActor 类型）
            DispatchQueue.main.async {
                compiling = false
                cached = list
                let ws = waiters
                waiters = []
                for w in ws { w(list) }
            }
        }
    }

    /// 要规则：好了立刻给，没好就排队等编译
    static func ruleList(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let cached { done(cached); return }
        waiters.append(done)
        warmUp()
    }

    /// 把规则挂到一个 WebView 上（or 摘掉）。**改完必须重载页面才生效。**
    static func apply(to wv: WKWebView, on: Bool) {
        let ucc = wv.configuration.userContentController
        ucc.removeAllContentRuleLists()
        guard on, let list = cached else { return }
        ucc.add(list)
    }
}
