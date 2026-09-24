import SwiftUI
import WebKit

/// 把 WKWebView 塞进 SwiftUI。
struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        // 首次进来建第一个标签；切换标签时，这个视图因为带了
        // .id(model.currentTabIndex)（见 ContentView）会被整体重建 ——
        // 于是这里拿到的是新标签的 WebView。
        // WebView 在父视图之间搬家是允许的（它始终只属于一个父视图）；
        // 旧标签的 WebView 仍被它自己的 BrowserTab 强引用着，不会丢，
        // 只是暂时不显示 —— 切回去就能看到它原来停在哪。
        model.currentWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
