import Foundation

/// ★ v1.0.241：网页开了弹窗时那句"怎么打开"的询问 —— **界面用 SwiftUI 的 `.alert` 显示它**。
///
/// 为什么单独拆一个值类型：
///   · 它要跨"浏览器内核"（BrowserModel）和"界面"（ContentView）两边用；
///   · `.alert(presenting:)` 要求它 `Identifiable` —— 不能直接把 `URLRequest` 之类丢过去。
struct PopupAskInfo: Identifiable {
    let id = UUID()
    /// 完整地址（弹层里显示这一行）
    let url: String

    /// 认不出域名就退回整串地址
    var display: String {
        guard let h = URL(string: url)?.host, !h.isEmpty else { return url }
        return h
    }
}

/// 用户在菜单上选了什么。
enum PopupAnswer {
    case inPlace      // 当前窗口加载
    case newTab       // 新窗口打开
    case background   // 后台窗口打开
    case cancel
}
