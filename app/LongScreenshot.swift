import UIKit
import WebKit

/// 网页「截长图」—— 把整页（含滚动部分）拼成一张图。
///
/// ══ 为什么要自己拼 ══
/// iOS 15 / 16 **没有**"整页截图"的现成 API（17 才有 `WKWebView` 相关能力），
/// 所以只能：**逐屏滚动 + 每屏截一张 + 拼起来**。
///
/// ══ 两个必须处理的坑 ══
/// 1. **顶部/底部那条固定栏会重复出现**（每屏都画一次）。
///    做法：截图前用 JS 把所有 `position: fixed / sticky` 的元素**临时改成 absolute**，
///    截完再改回去（`pinFixed` / `unpinFixed`）。不这么做，拼出来就是"导航条隔一屏来一条"。
/// 2. **超长页面会把内存打爆**。两道闸：
///    · 总高超过 `maxPoints` → **直接报错**（明确告诉用户），不给半张残缺图；
///    · 拼图按像素上限自动降采样（40MP 封顶）。
///
/// ══ 已知局限（如实写在这里，别让用户以为是 bug）══
/// · 懒加载的图片：滚动过程中才开始下载，可能来不及渲染就被截了 → 图上有空白块。
///   缓解：每屏之间留 0.15 秒。想彻底解决得"先滚到底预热一遍再回来截"，这一版不做。
/// · 视差/动画元素：截图时处于什么状态就是什么状态，可能不是最好看的那一帧。
///
/// ★ 全程**回调式**（不用 async/await）：这类"连续多步 + 每步都依赖 UI"
///   的流程，用回调推进比 async 好读，也绕开了并发隔离那堆坑（项目里已踩过两次）。
@MainActor
enum LongShot {

    enum ShotError: LocalizedError {
        case noPage
        case tooLong(Double)
        case failed

        var errorDescription: String? {
            switch self {
            case .noPage:          return "现在没有打开的网页。"
            case .tooLong(let h):  return "这个页面太长了（约 \(Int(h)) 点高），超出能拼的上限。"
            case .failed:          return "网页截图没成功，稍后再试一次。"
            }
        }
    }

    /// 允许拼的最大高度（点）。12000 点已经很长（约 10 屏），再高不只是慢，是会爆内存。
    static let maxPoints: Double = 12000
    /// 最多截多少屏（兜底，防止极端页面把循环拖死）
    private static let maxShots = 40
    /// 每屏之间的等待：给重排 + 懒加载图留下时间
    private static let settle: Double = 0.15

    private static let sizeJS = """
    (function(){
      var d = document.documentElement, b = document.body || d;
      var h = Math.max(d.scrollHeight, b.scrollHeight, d.offsetHeight, b.offsetHeight);
      return JSON.stringify({t: Math.ceil(h), v: Math.ceil(window.innerHeight),
                             w: Math.ceil(Math.max(d.clientWidth, window.innerWidth))});
    })()
    """

    private static let pinJS = """
    (function(){
      if (window.__vgPinned) { return window.__vgPinSaved ? window.__vgPinSaved.length : 0; }
      window.__vgPinned = true;
      window.__vgPinSaved = [];
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        var cs;
        try { cs = getComputedStyle(el); } catch (e) { continue; }
        if (cs.position === 'fixed' || cs.position === 'sticky') {
          window.__vgPinSaved.push([el, el.style.position, el.style.top, el.style.zIndex]);
          el.style.position = 'absolute';
        }
      }
      return window.__vgPinSaved.length;
    })()
    """

    private static let unpinJS = """
    (function(){
      if (!window.__vgPinSaved) { return 0; }
      for (var i = 0; i < window.__vgPinSaved.length; i++) {
        var s = window.__vgPinSaved[i];
        s[0].style.position = s[1];
        s[0].style.top = s[2];
        s[0].style.zIndex = s[3];
      }
      window.__vgPinSaved = [];
      window.__vgPinned = false;
      return 1;
    })()
    """

    /// 截当前网页 → 回调给整页长图。
    static func capture(_ wv: WKWebView, done: @escaping (Result<UIImage, Error>) -> Void) {
        let scroll = wv.scrollView
        let savedOffset = scroll.contentOffset
        let savedZoom = scroll.zoomScale

        wv.evaluateJavaScript(sizeJS) { raw, _ in
            guard let s = raw as? String, let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let total = (o["t"] as? NSNumber)?.doubleValue,
                  let viewport = (o["v"] as? NSNumber)?.doubleValue,
                  let width = (o["w"] as? NSNumber)?.doubleValue,
                  total > 1, viewport > 1, width > 1 else {
                done(.failure(ShotError.failed))
                return
            }
            guard total <= maxPoints else {
                done(.failure(ShotError.tooLong(total)))
                return
            }

            // 钉住固定元素 → 逐屏截 → 恢复 → 拼接（每一步都保证能回到原状）
            wv.evaluateJavaScript(pinJS) { _, _ in
                scroll.setZoomScale(1, animated: false)     // 缩放状态下截图尺寸会乱
                shoot(wv, total: total, viewport: viewport, width: width, shots: []) { shots in
                    wv.evaluateJavaScript(unpinJS) { _, _ in
                        scroll.setZoomScale(savedZoom, animated: false)
                        scroll.setContentOffset(savedOffset, animated: false)
                        if let img = stitch(shots, total: total) {
                            done(.success(img))
                        } else {
                            done(.failure(ShotError.failed))
                        }
                    }
                }
            }
        }
    }

    /// 逐屏截图。递归推进（每屏都要等上一屏拍完才能滚下一屏）。
    private static func shoot(_ wv: WKWebView, total: Double, viewport: Double, width: Double,
                              shots: [UIImage], done: @escaping ([UIImage]) -> Void) {
        let y = Double(shots.count) * viewport
        if y >= total || shots.count >= maxShots {
            done(shots)
            return
        }
        wv.scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)

        // 滚完立刻截会拿到"上一屏"的画面 —— 等它重排一帧
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: width, height: min(viewport, total - y))
            wv.takeSnapshot(with: cfg) { img, _ in
                var next = shots
                if let img { next.append(img) }
                shoot(wv, total: total, viewport: viewport, width: width, shots: next, done: done)
            }
        }
    }

    /// 把一叠截图按顺序竖着拼起来。
    /// 像素上限 40MP：超了按比例降采样（宁可分辨率低一点，也不能被系统杀掉）。
    private static func stitch(_ shots: [UIImage], total: Double) -> UIImage? {
        guard let first = shots.first else { return nil }
        let w = first.size.width
        let rawH = shots.reduce(CGFloat(0)) { $0 + $1.size.height }
        let size = CGSize(width: w, height: min(rawH, CGFloat(total)))
        guard size.width > 1, size.height > 1 else { return nil }

        let maxPixels: CGFloat = 40_000_000
        let px = size.width * size.height
        let scale: CGFloat = px > maxPixels ? max(0.3, sqrt(maxPixels / px)) : 1

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { _ in
            var y: CGFloat = 0
            for s in shots {
                if y >= size.height { break }
                s.draw(in: CGRect(x: 0, y: y, width: w, height: s.size.height))
                y += s.size.height
            }
        }
    }
}
