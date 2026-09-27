import SwiftUI
import UIKit

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
