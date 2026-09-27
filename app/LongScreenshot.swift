import UIKit
import WebKit

/// 网页「截长图」—— 把整页（含滚动部分）拼成一张图。
///
/// ══ 为什么要自己拼 ══
/// iOS 15 / 16 **没有**"整页截图"的现成 API（17 才有），只能：
/// **逐屏滚动 + 每屏截一张 + 拼起来**。
///
/// ══ 画质（★ v1.0.120 修的就是这个）══
/// 第一版糊，是因为拼接时把输出倍率设成了 **1** ——
/// 而 `takeSnapshot` 每屏给的图是**屏幕倍率**（iPhone 上 3x，1170×2532 像素），
/// 按 1x 输出 = **分辨率砍到三分之一**（390 宽），所以又小又糊。
/// 现在：
///   · 画布直接按**屏幕倍率**建，逐屏原样画进去 → 输出跟屏幕一样清晰；
///   · 只在**总像素真的过大**时才等比降采样（上限 28MP ≈ 112MB 位图，是"还能稳住"的量级），
///     并设下限（低于 `minScale` 宁可不截，也不给一张糊图）。
///
/// ══ 内存：边截边画，不攒一叠图 ══
/// 10 屏的 3x 截图每张就十几 MB，全攒着再拼（第一版做法）峰值能到两三百 MB，容易被系统杀掉。
/// 现在自己开一个位图上下文，**每截一屏就画进去**，峰值 ≈ 画布 + 一张截图。
/// 用 `CGContext` 而不是 `UIGraphicsBeginImageContext`：截图是**异步多步**的，
/// 全局绘图栈容易被别的东西插进来；自己拿着上下文更稳（也不用担心忘关栈）。
///
/// ══ 两个必须处理的坑 ══
/// 1. **固定栏重复出现**：截图前用 JS 把 `position: fixed / sticky` 临时改 absolute，
///    截完改回去（`pinJS` / `unpinJS`）。
/// 2. **最后一屏会被系统"夹住"**：滚到底时 `contentOffset` 到不了理论值，
///    所以每屏都读**实际** offset 来定位；否则拼接处会出现重复或错位的一段。
///
/// ══ 已知局限（如实写在这里，别让用户以为是 bug）══
/// · 懒加载的图片：滚动过程中才开始下载，可能来不及渲染 → 图上有空白块；
/// · 视差/动画元素：截到的是当下那一帧。
@MainActor
enum LongShot {

    enum ShotError: LocalizedError {
        case noPage
        case tooLong(Double)
        case failed

        var errorDescription: String? {
            switch self {
            case .noPage:          return "现在没有打开的网页。"
            case .tooLong(let h):  return "这个页面太长了（约 \(Int(h)) 点高），再拼就糊得没法看了。"
            case .failed:          return "网页截图没成功，稍后再试一次。"
            }
        }
    }

    /// 允许拼的最大高度（点）。12000 点约 14 屏，再高就不只是慢的问题了。
    static let maxPoints: Double = 12000
    /// 输出像素上限（约 28MP ≈ 112MB 位图）
    private static let maxPixels: Double = 28_000_000
    /// 输出倍率下限：低于这个就明确报错，不给糊图
    private static let minScale: Double = 1.2
    /// 最多截多少屏（兜底）
    private static let maxShots = 40
    /// 每屏之间的等待：给重排 + 懒加载图留时间
    private static let settle: Double = 0.16

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

    /// 截当前网页 → 回调给整页长图
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

            // 输出倍率：跟屏幕一致（3x）；总像素超上限才等比降
            let base = Double(wv.window?.screen.scale ?? UIScreen.main.scale)
            let rawPixels = width * total * base * base
            let outScale = rawPixels > maxPixels ? base * sqrt(maxPixels / rawPixels) : base
            guard outScale >= minScale else {
                done(.failure(ShotError.tooLong(total)))
                return
            }

            wv.evaluateJavaScript(pinJS) { _, _ in
                scroll.setZoomScale(1, animated: false)      // 缩放状态下截图尺寸会乱
                let pxW = max(1, Int((width * outScale).rounded()))
                let pxH = max(1, Int((total * outScale).rounded()))
                guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    restore(wv, offset: savedOffset, zoom: savedZoom)
                    done(.failure(ShotError.failed))
                    return
                }
                // 不透明底：先铺白，避免没画到的区域是黑的
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

                shoot(ctx: ctx, wv: wv, total: total, viewport: viewport, width: width,
                      index: 0) { ok in
                    restore(wv, offset: savedOffset, zoom: savedZoom)
                    guard ok, let cg = ctx.makeImage() else {
                        done(.failure(ShotError.failed))
                        return
                    }
                    done(.success(UIImage(cgImage: cg,
                                          scale: CGFloat(outScale),
                                          orientation: .up)))
                }
            }
        }
    }

    /// 恢复现场：把钉住的 fixed 元素改回去 + 缩放和滚动位置还原
    private static func restore(_ wv: WKWebView, offset: CGPoint, zoom: CGFloat) {
        wv.evaluateJavaScript(unpinJS) { _, _ in
            wv.scrollView.setZoomScale(zoom, animated: false)
            wv.scrollView.setContentOffset(offset, animated: false)
        }
    }

    /// 逐屏截图并**直接画进位图上下文**（不攒图，省内存）。
    /// ★ 每一屏都用**实际** contentOffset 定位 —— 最后一屏会被系统夹住，
    ///   若按 `index * viewport` 画，拼接处就会重复一段。
    private static func shoot(ctx: CGContext, wv: WKWebView, total: Double, viewport: Double,
                              width: Double, index: Int, done: @escaping (Bool) -> Void) {
        if index >= maxShots { done(true); return }
        let targetY = Double(index) * viewport
        if targetY >= total - 1 { done(true); return }

        wv.scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)

        // 滚完立刻截会拿到"上一屏"的画面 —— 等它重排一帧
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            let actualY = Double(wv.scrollView.contentOffset.y)
            wv.takeSnapshot(with: WKSnapshotConfiguration()) { img, _ in
                guard let img, let cg = img.cgImage else {
                    done(false)
                    return
                }
                // 这一屏实际有多少内容（到底了就少于一个视口）
                let avail = max(1, min(Double(img.size.height), total - actualY))
                let piece = crop(cg, toHeight: avail, ofHeight: Double(img.size.height))
                // CGContext 的 y 轴向上：这一屏的左下角 = total - actualY - avail
                let yCG = CGFloat(total - actualY - avail)
                ctx.draw(piece, in: CGRect(x: 0, y: yCG, width: width, height: avail))

                if actualY + viewport >= total - 1 {      // 已经到底
                    done(true)
                } else {
                    shoot(ctx: ctx, wv: wv, total: total, viewport: viewport, width: width,
                          index: index + 1, done: done)
                }
            }
        }
    }

    /// 把一张截图的位图裁到指定高度（点）。
    /// 最后一屏内容不足一个视口时，不裁就会在拼图底部多出一条空白。
    private static func crop(_ cg: CGImage, toHeight h: Double, ofHeight full: Double) -> CGImage {
        guard full - h > 0.5 else { return cg }
        let ratio = max(0.001, h / full)
        let rect = CGRect(x: 0, y: 0,
                          width: Double(cg.width),
                          height: max(1, (Double(cg.height) * ratio).rounded()))
        return cg.cropping(to: rect) ?? cg
    }
}
