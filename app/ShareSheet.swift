import SwiftUI
import UIKit

/// 一次要分享的一组东西。
///
/// 为什么要包一层：`.sheet(item:)` 要求 Identifiable，而 `[Any]` 本身没有 id。
/// 为什么可能是好几件：导出「PDF + 图片」会同时产出两份文件，
/// 交给面板让用户自己挑（有些 App 只接第一件，所以调用方把图片排在前面）。
struct ShareBundle: Identifiable {
    let id = UUID()
    var items: [Any]

    init(_ items: [Any]) { self.items = items }
}

/// 系统分享面板（`UIActivityViewController` 的 SwiftUI 包装）。
///
/// 用系统的而不是自己画：分享目标（微信、存到文件、AirDrop…）是系统提供的，
/// 自己画等于把系统能力挡在外面。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// 分享成功/取消后回调（true = 真的分享出去了）
    var onFinish: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, ok, _, _ in
            DispatchQueue.main.async { onFinish?(ok) }
        }
        // iPad 上必须有锚点，否则 present 会直接崩。
        // （我们主要面向 iPhone，但既然图标里带了 iPad 那套，就别留这个雷。）
        _ = vc.view
        if let pop = vc.popoverPresentationController {
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
