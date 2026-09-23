import SwiftUI
import WebKit

/// 把 WKWebView 塞进 SwiftUI。
struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
