import UIKit
import WebKit

/// 网页「截长图」—— 把整页（含滚动部分）拼成一张图。
///
/// ══ 为什么要自己拼 ══
/// iOS 15 / 16 **没有**"整页截图"的现成 API（17 才有），只能：
/// **逐屏滚动 + 每屏截一张 + 拼起来**。
///
/// ══ v1.0.121 这一轮修的是"有些网页截不成功" ══
/// 上一版（v1.0.120）为了保画质加了两道硬闸门：**超过 12000 点直接报错**、
/// **倍率低于 1.2 直接报错** —— 结果"画质上去了，但本来能截的页面变成截不了"。
/// 现在改成「**能截就截，宁可降清晰度也别报错**」，并补上三个真实缺口：
///
///   ① **闸门放宽**：总高上限 12000 → **30000 点**；倍率下限 1.2 → **1.0**；
///      像素上限 28MP → **20MP**（更省内存）。降了清晰度会在提示里**说清楚**，不静默。
///   ② **内部滚动容器**（很多站点 body 锁死、真正滚的是里面某个 div）：
///      原来滚的是 `scrollView`，对这种页面等于没滚 → 拼出来是**同一屏重复 N 次**。
///      现在先用 JS 找出"真正在滚的元素"（`document.scrollingElement`，
///      否则遍历 `overflowY: auto/scroll` 且内容超高的最大元素），**用 JS 滚它**，
///      并读它**实际**的滚动位置来定位。
///   ③ **单屏截不到不再整张失败**：`takeSnapshot` 失败先重试 2 次，
///      再降级用 `drawHierarchy`；仍拿不到就**跳过这一屏继续**，最后告诉用户"有 N 屏没截到"。
///
/// 另外顺手做的三件小事：量高度**连量 3 次取最大**（懒加载页面会一边加载一边变高）、
/// 截图期间**隐藏滚动条**（不然每屏都带一条，拼起来是重复的竖线）、
/// 把 `img[data-src]` 之类的**懒加载图片预填**上（让它先开始加载）。
///
/// ══ 画质（v1.0.120 修的，别退回去）══
/// `takeSnapshot` 每屏给的图是**屏幕倍率**（iPhone 3x）。画布也按 3x 建、逐屏原样画进去，
/// 输出就跟屏幕一样清晰；只有总像素超上限时才等比降。**拼接时绝不能把倍率写死成 1**
/// （第一版就是这么糊的：分辨率被砍到三分之一）。
///
/// ══ 内存：边截边画 ══
/// 自己开一个 `CGContext`（不用 `UIGraphicsBeginImageContext` —— 那是全局栈，
/// 而截图是"滚一屏→等→截→再滚"的**异步多步**流程，全局栈容易被插进来），
/// 每截一屏就画进去，峰值 ≈ 画布 + 一张截图。
///
/// ══ 已知局限（如实写在这里，别让用户以为是 bug）══
/// · 跨域 iframe 里的内容，公开 API 碰不到 → 那部分只会按它在主页面里的样子截；
/// · 无限滚动页面没有"底"，到 30000 点 / 60 屏就停；
/// · 视频 / WebGL / Canvas 这类合成内容，`takeSnapshot` 有时抓不到（会走降级路径）；
/// · 视差动画、字体在接缝处 1px 级错位，无法完全避免。
@MainActor
enum LongShot {

    /// 一次截图的产物
    struct Shot {
        var image: UIImage
        /// 因为页面太长而降过清晰度（要在提示里说清楚）
        var reducedQuality: Bool
        /// 有几屏实在没截到（图上会缺那部分）
        var missedScreens: Int
    }

    enum ShotError: LocalizedError {
        case noPage
        case tooLong(Double)
        case failed

        var errorDescription: String? {
            switch self {
            case .noPage:
                return "现在没有打开的网页。"
            case .tooLong(let h):
                return "这个页面太长了（约 \(Int(h)) 点高），超出能拼的上限。"
            case .failed:
                return "网页截图没成功，稍后再试一次。"
            }
        }
    }

    // MARK: - 阈值（v1.0.121 放宽：能截就截，宁可糊一点也别报错）

    /// 允许拼的最大高度（点）。30000 点 ≈ 35 屏，1.0 倍率下也才 11.7MP。
    static let maxPoints: Double = 30000
    /// 输出像素上限（20MP ≈ 80MB 位图，比上一版的 28MP 更稳）
    private static let maxPixels: Double = 20_000_000
    /// 输出倍率下限：1.0 = 视口的 CSS 像素（仍然能看清字），再低就真糊了
    private static let minScale: Double = 1.0
    /// 最多截多少屏（兜底）
    private static let maxShots = 60
    /// 每屏之间的等待：给重排 + 懒加载留时间
    private static let settle: Double = 0.2
    /// 量高度采样几次
    private static let samples = 3

    // MARK: - JS 片段

    /// ① 找"真正在滚的那个元素"（结果存进 window.__vgEl，后面滚动/恢复都用它）
    ///   ② 顺带把尺寸一起量了 —— 用内部容器时，"视口"就是那个容器的可视高
    ///   ③ 记录初始滚动位置（恢复现场要用）
    private static let findJS = """
    (function(){
      var cand = document.scrollingElement || document.documentElement;
      function scrollable(el){
        if (!el) { return false; }
        return el.scrollHeight > el.clientHeight + 8;
      }
      if (!scrollable(cand)) {
        var all = document.querySelectorAll('div,main,section,article,ul,body');
        var best = null, bestH = 0;
        for (var i = 0; i < all.length; i++) {
          var el = all[i], st;
          try { st = getComputedStyle(el); } catch (e) { continue; }
          var oy = st.overflowY;
          if (oy !== 'auto' && oy !== 'scroll' && oy !== 'overlay') { continue; }
          if (el.scrollHeight > el.clientHeight + 8 && el.scrollHeight > bestH) {
            best = el; bestH = el.scrollHeight;
          }
        }
        if (best) { cand = best; }
      }
      window.__vgEl = cand;
      var isDoc = (cand === document.scrollingElement
                   || cand === document.documentElement
                   || cand === document.body);
      window.__vgIsDoc = isDoc;
      var t = Math.max(cand.scrollHeight, document.documentElement.scrollHeight || 0);
      var v = isDoc ? window.innerHeight : cand.clientHeight;
      var w = isDoc ? Math.max(document.documentElement.clientWidth, window.innerWidth)
                    : cand.clientWidth;
      var s0 = isDoc ? (window.scrollY || cand.scrollTop || 0) : cand.scrollTop;
      return JSON.stringify({t: Math.ceil(t), v: Math.ceil(v), w: Math.ceil(w),
                             s: Math.ceil(s0), inner: !isDoc});
    })()
    """

    /// 滚到指定位置，**返回实际落点**（内部容器时 window 的 contentOffset 根本不反映它）
    private static func scrollJS(_ y: Double) -> String {
        """
        (function(y){
          if (window.__vgEl && !window.__vgIsDoc) {
            window.__vgEl.scrollTop = y;
            return Math.round(window.__vgEl.scrollTop);
          }
          window.scrollTo(0, y);
          return Math.round(window.scrollY || (document.scrollingElement
                   ? document.scrollingElement.scrollTop : 0) || 0);
        })(\(Int(y)))
        """
    }

    /// 钉住 fixed / sticky（不然固定导航栏每屏都被截一次，拼出来重复 N 条）
    private static let pinJS = """
    (function(){
      if (window.__vgPinned) { return window.__vgPinSaved ? window.__vgPinSaved.length : 0; }
      window.__vgPinned = true;
      window.__vgPinSaved = [];
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i], cs;
        try { cs = getComputedStyle(el); } catch (e) { continue; }
        if (cs.position === 'fixed' || cs.position === 'sticky') {
          window.__vgPinSaved.push([el, el.style.position, el.style.top, el.style.zIndex]);
          el.style.position = 'absolute';
        }
      }
      return window.__vgPinSaved.length;
    })()
    """

    /// 藏滚动条 + 统一字体平滑（滚动条每屏都带一条，拼起来是重复竖线）
    private static let styleJS = """
    (function(){
      if (document.getElementById('__vgShotStyle')) { return 1; }
      var s = document.createElement('style');
      s.id = '__vgShotStyle';
      s.textContent =
        '::-webkit-scrollbar{display:none!important;width:0!important;height:0!important}'
        + '*{-webkit-font-smoothing:antialiased!important}';
      (document.head || document.documentElement).appendChild(s);
      return 1;
    })()
    """

    /// 把 data-src 之类的懒加载图挪到 src（让它先开始加载，少点空白块）
    private static let preloadJS = """
    (function(){
      var n = 0;
      var imgs = document.querySelectorAll('img[data-src],img[data-original],img[data-lazy-src]');
      for (var i = 0; i < imgs.length; i++) {
        var el = imgs[i];
        var u = el.getAttribute('data-src') || el.getAttribute('data-original')
                || el.getAttribute('data-lazy-src');
        if (u && !el.getAttribute('src')) { el.setAttribute('src', u); n++; }
      }
      return n;
    })()
    """

    /// 恢复现场：fixed/sticky 改回去、去掉注入的样式、滚回原来的位置
    private static func restoreJS(_ y: Double) -> String {
        """
        (function(){
          if (window.__vgPinSaved) {
            for (var i = 0; i < window.__vgPinSaved.length; i++) {
              var s = window.__vgPinSaved[i];
              s[0].style.position = s[1];
              s[0].style.top = s[2];
              s[0].style.zIndex = s[3];
            }
            window.__vgPinSaved = [];
          }
          window.__vgPinned = false;
          var st = document.getElementById('__vgShotStyle');
          if (st && st.parentNode) { st.parentNode.removeChild(st); }
          if (window.__vgEl && !window.__vgIsDoc) {
            window.__vgEl.scrollTop = \(Int(y));
          } else {
            window.scrollTo(0, \(Int(y)));
          }
          return 1;
        })()
        """
    }

    // MARK: - 主流程

    private struct Geo {
        var total: Double
        var viewport: Double
        var width: Double
        var startY: Double
    }

    static func capture(_ wv: WKWebView, done: @escaping (Result<Shot, Error>) -> Void) {
        let scroll = wv.scrollView
        let savedOffset = scroll.contentOffset
        let savedZoom = scroll.zoomScale

        // ① 量尺寸（连量 3 次取最大 —— 懒加载页面一边加载一边变高）
        measure(wv, left: samples, best: nil) { geo in
            guard let geo else {
                done(.failure(ShotError.failed))
                return
            }
            guard geo.total <= maxPoints else {
                done(.failure(ShotError.tooLong(geo.total)))
                return
            }

            // ② 输出倍率：跟屏幕一致；超像素上限才等比降（并记下来，提示里要说明）
            let base = Double(wv.window?.screen.scale ?? UIScreen.main.scale)
            let rawPixels = geo.width * geo.total * base * base
            let outScale = rawPixels > maxPixels ? base * sqrt(maxPixels / rawPixels) : base
            guard outScale >= minScale else {
                done(.failure(ShotError.tooLong(geo.total)))
                return
            }
            let reduced = outScale < base - 0.05

            // ③ 注入 + 建画布 + 逐屏截
            wv.evaluateJavaScript(pinJS) { _, _ in
                wv.evaluateJavaScript(styleJS) { _, _ in
                    wv.evaluateJavaScript(preloadJS) { _, _ in
                        scroll.setZoomScale(1, animated: false)
                        let pxW = max(1, Int((geo.width * outScale).rounded()))
                        let pxH = max(1, Int((geo.total * outScale).rounded()))
                        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                            restoreAll(wv, y: geo.startY, offset: savedOffset, zoom: savedZoom)
                            done(.failure(ShotError.failed))
                            return
                        }
                        ctx.setFillColor(UIColor.white.cgColor)     // 不透明白底，别留黑块
                        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

                        shoot(ctx: ctx, wv: wv, geo: geo, index: 0, missed: 0) { ok, missed in
                            restoreAll(wv, y: geo.startY, offset: savedOffset, zoom: savedZoom)
                            guard ok, let cg = ctx.makeImage() else {
                                done(.failure(ShotError.failed))
                                return
                            }
                            let img = UIImage(cgImage: cg, scale: CGFloat(outScale), orientation: .up)
                            done(.success(Shot(image: img,
                                               reducedQuality: reduced,
                                               missedScreens: missed)))
                        }
                    }
                }
            }
        }
    }

    /// 连量几次取最大的 total（viewport / width 用第一次的，避免中途不一致）
    private static func measure(_ wv: WKWebView, left: Int, best: Geo?,
                                done: @escaping (Geo?) -> Void) {
        wv.evaluateJavaScript(findJS) { raw, _ in
            var cur = best
            if let s = raw as? String, let d = s.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let t = (o["t"] as? NSNumber)?.doubleValue,
               let v = (o["v"] as? NSNumber)?.doubleValue,
               let w = (o["w"] as? NSNumber)?.doubleValue,
               let y0 = (o["s"] as? NSNumber)?.doubleValue,
               t > 1, v > 1, w > 1 {
                if let b = cur {
                    cur = Geo(total: max(b.total, t), viewport: b.viewport,
                              width: b.width, startY: b.startY)
                } else {
                    cur = Geo(total: t, viewport: v, width: w, startY: y0)
                }
            }
            if left <= 1 {
                done(cur)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                measure(wv, left: left - 1, best: cur, done: done)
            }
        }
    }

    /// 逐屏：滚 → 等 → 截 → 画进画布。单屏失败**只跳过、不整张失败**。
    private static func shoot(ctx: CGContext, wv: WKWebView, geo: Geo,
                              index: Int, missed: Int,
                              done: @escaping (_ ok: Bool, _ missed: Int) -> Void) {
        if index >= maxShots {
            done(true, missed)
            return
        }
        let targetY = Double(index) * geo.viewport
        if targetY >= geo.total - 1 {
            done(true, missed)
            return
        }

        wv.evaluateJavaScript(scrollJS(targetY)) { raw, _ in
            // 用**实际**落点定位：滚到底时系统会夹住，内部容器也可能不听话
            let actualY = (raw as? NSNumber)?.doubleValue ?? targetY
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                snap(wv, retry: 2) { img in
                    guard let img, let cg = img.cgImage else {
                        // 这一屏实在拿不到 —— 记一笔继续（页面别的地方还是能截的）
                        shoot(ctx: ctx, wv: wv, geo: geo, index: index + 1,
                              missed: missed + 1, done: done)
                        return
                    }
                    let avail = max(1, min(Double(img.size.height), geo.total - actualY))
                    let piece = crop(cg, toHeight: avail, ofHeight: Double(img.size.height))
                    // CGContext 的 y 轴向上：这一屏左下角 = total - actualY - avail
                    ctx.draw(piece, in: CGRect(x: 0, y: CGFloat(geo.total - actualY - avail),
                                               width: geo.width, height: avail))
                    if actualY + geo.viewport >= geo.total - 1 {
                        done(true, missed)
                    } else {
                        shoot(ctx: ctx, wv: wv, geo: geo, index: index + 1,
                              missed: missed, done: done)
                    }
                }
            }
        }
    }

    /// 截一屏：`takeSnapshot` → 失败重试 2 次 → 再失败降级 `drawHierarchy`
    private static func snap(_ wv: WKWebView, retry: Int, done: @escaping (UIImage?) -> Void) {
        wv.takeSnapshot(with: WKSnapshotConfiguration()) { img, _ in
            if let img {
                done(img)
                return
            }
            if retry > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    snap(wv, retry: retry - 1, done: done)
                }
                return
            }
            // 降级：把当前可视区直接画一遍（视频/WebGL 可能仍是空的，但比什么都没有强）
            let size = wv.bounds.size
            guard size.width > 1, size.height > 1 else {
                done(nil)
                return
            }
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = wv.window?.screen.scale ?? UIScreen.main.scale
            let r = UIGraphicsImageRenderer(size: size, format: fmt)
            done(r.image { _ in
                wv.drawHierarchy(in: wv.bounds, afterScreenUpdates: true)
            })
        }
    }

    /// 恢复一切：JS 侧（fixed/样式/滚动位置）+ 原生的缩放和 contentOffset
    private static func restoreAll(_ wv: WKWebView, y: Double,
                                   offset: CGPoint, zoom: CGFloat) {
        wv.evaluateJavaScript(restoreJS(y)) { _, _ in
            wv.scrollView.setZoomScale(zoom, animated: false)
            wv.scrollView.setContentOffset(offset, animated: false)
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
