import UIKit
import WebKit

/// 网页「导出 PDF」—— 把整页交给 WebKit 自己的排版渲染器，输出**矢量** PDF。
///
/// ══ 为什么跟「截长图」是两条路、谁也替不了谁 ══
/// 截长图 = 逐屏截位图再拼接（好处：所见即所得；坏处：接缝、固定栏要钉住、慢）。
/// 导出 PDF = `WKWebView.createPDF`（iOS 14+）直接按文档流渲染整页：
///   · **矢量** —— 文字可选中、可搜索、放大不糊（图片仍是原分辨率位图）；
///   · **一次成型** —— 没有接缝，fixed/sticky 元素也不会重复出现 N 条；
///   · **不分页** —— 官方行为就是"一整页超长 PDF"（苹果文档/社区都确认），
///     这正好符合"整页"语义；代价是超长页面在有些阅读器里缩得很小。
///
/// ══ 两个已知坑（都有实测出处，别删这两段处理）══
/// ① **背景色丢失**：iOS 16.6 / 17 上 createPDF 会把 CSS 背景丢掉
///    （Apple 开发者论坛 #734881 / SO 72507453 实测），深色主题页面导出后一片白。
///    修法：注入 `-webkit-print-color-adjust: exact`（@media print 里 + 全局各一条，双保险）。
/// ② **SVG 黑底 / 不渲染**（SO 79658118）：WebKit 的 PDF 渲染对部分 SVG
///    （比如 Hacker News 的箭头）会画成黑块 —— **没有公开解法**，
///    这是走 PDF 这条路的天花板，遇到就只能用「截长图」。
///
/// ══ 尺寸怎么定 ══
/// rect 显式设为 JS 量出的整页尺寸（document scrollWidth/scrollHeight，点）。
/// 不用默认 nil：社区实测（digitalbunker / SO 70337689）默认行为有的系统只给视口。
/// JS 量不出来时退回 scrollView.contentSize，再不行才用默认。
///
/// ══ 已知局限（跟长图同源，先说清）══
/// · 懒加载图片：只做"预填 data-src + 解除 lazy"并等一小会儿，没等到就没图（空白块）；
/// · 无限滚动页面：导出的是**当前** DOM 高度，没有"底"就到这儿为止；
/// · 视频 / WebGL / Canvas 这类合成内容有时抓不到（那一块空着）。
@MainActor
enum PagePDF {

    struct Output {
        var data: Data
        var pages: Int
        var widthPts: Int
        var heightPts: Int
        /// 页面很长（提示里说明"是一整页的大 PDF"，但不阻止）
        var veryLong: Bool
    }

    enum PDFError: LocalizedError {
        case noPage
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noPage:          return "现在没有打开的网页。"
            case .empty:           return "这个页面没有内容，导不出 PDF。"
            case .failed(let s):   return "导出 PDF 没成功：\(s)"
            }
        }
    }

    /// 超过这个高度（点）就在提示里说明"很长"（不阻止 —— 矢量没有像素上限的压力）
    private static let longPoints: Double = 30000
    /// 给懒加载图片留的加载窗口（秒）
    private static let lazyWait: Double = 0.6

    // MARK: - JS 片段

    /// ① 背景色保真（见类注释坑①；两条都注入 —— createPDF 会应用 print 媒体查询，
    ///    但全局那条兜底，防个别系统只走 screen 媒体）
    private static let colorJS = """
    (function(){
      if (document.getElementById('__vgPrintStyle')) { return 1; }
      var s = document.createElement('style');
      s.id = '__vgPrintStyle';
      s.textContent =
        '@media print{*,*::before,*::after{-webkit-print-color-adjust:exact!important;'
        + 'print-color-adjust:exact!important}}'
        + '*,*::before,*::after{-webkit-print-color-adjust:exact!important;'
        + 'print-color-adjust:exact!important}';
      (document.head || document.documentElement).appendChild(s);
      return 1;
    })()
    """

    /// ② 懒加载解堵：`loading=lazy` 改成立即加载 + 把 data-src 挪进 src
    ///    （改了就不恢复了 —— 图提前加载对页面无害，恢复反而又变回缺图）
    private static let lazyJS = """
    (function(){
      var n = 0;
      var imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        var el = imgs[i];
        if (el.getAttribute('loading') === 'lazy') { el.setAttribute('loading', 'eager'); n++; }
        var u = el.getAttribute('data-src') || el.getAttribute('data-original')
                || el.getAttribute('data-lazy-src');
        if (u && !el.getAttribute('src')) { el.setAttribute('src', u); n++; }
      }
      return n;
    })()
    """

    /// ③ 量整页尺寸（点）
    private static let sizeJS = """
    (function(){
      var d = document.documentElement, b = document.body || d;
      var w = Math.max(d.scrollWidth || 0, b.scrollWidth || 0, d.clientWidth || 0);
      var h = Math.max(d.scrollHeight || 0, b.scrollHeight || 0, d.clientHeight || 0);
      return JSON.stringify({w: Math.ceil(w), h: Math.ceil(h)});
    })()
    """

    /// 收工：去掉注入的样式（页面还接着用）
    private static let unstyleJS = """
    (function(){
      var s = document.getElementById('__vgPrintStyle');
      if (s && s.parentNode) { s.parentNode.removeChild(s); }
      return 1;
    })()
    """

    // MARK: - 主流程

    static func capture(_ wv: WKWebView, done: @escaping (Result<Output, Error>) -> Void) {
        wv.evaluateJavaScript(colorJS) { _, _ in
            wv.evaluateJavaScript(lazyJS) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + lazyWait) {
                    wv.evaluateJavaScript(sizeJS) { raw, _ in
                        // 宽高：JS 量的优先（整页真实值），量不到退回 scrollView
                        var w = Double(wv.scrollView.contentSize.width)
                        var h = Double(wv.scrollView.contentSize.height)
                        if let s = raw as? String, let d = s.data(using: .utf8),
                           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                           let jw = (o["w"] as? NSNumber)?.doubleValue,
                           let jh = (o["h"] as? NSNumber)?.doubleValue,
                           jw > 1, jh > 1 {
                            w = max(w, jw)
                            h = max(h, jh)
                        }
                        guard w > 1, h > 1 else {
                            wv.evaluateJavaScript(unstyleJS) { _, _ in
                                done(.failure(PDFError.empty))
                            }
                            return
                        }

                        let cfg = WKPDFConfiguration()
                        cfg.rect = CGRect(x: 0, y: 0, width: w, height: h)
                        wv.createPDF(configuration: cfg) { res in
                            // 无论成败都把注入的样式收掉（页面还得接着用）
                            wv.evaluateJavaScript(unstyleJS) { _, _ in }
                            switch res {
                            case .success(let data):
                                guard !data.isEmpty else {
                                    done(.failure(PDFError.empty))
                                    return
                                }
                                let (pages, box) = readInfo(data)
                                guard pages >= 1, box.width > 1, box.height > 1 else {
                                    // 数据拿到了但解不开 —— 当成 WebKit 出了怪东西，如实报
                                    done(.failure(PDFError.failed("生成的文件不是有效 PDF")))
                                    return
                                }
                                done(.success(Output(
                                    data: data,
                                    pages: pages,
                                    widthPts: Int(box.width.rounded()),
                                    heightPts: Int(box.height.rounded()),
                                    veryLong: h > longPoints)))
                            case .failure(let e):
                                done(.failure(PDFError.failed(readable(e))))
                            }
                        }
                    }
                }
            }
        }
    }

    /// 把一份 PDF 渲染成一张**长图**（给"想发微信 / 存相册"的场景）。
    ///
    /// ★ 它替代了原来那个「截长图」（逐屏截图再拼）——
    ///   因为 PDF 是**一次排版成型**的，渲染出来没有接缝、固定导航栏不重复、
    ///   也不受"页面真正在滚的是哪个元素"影响 —— 那些恰好就是截图拼接拼不干净的地方。
    ///
    /// 用 CoreGraphics 自己画（不引 PDFKit）：新建位图上下文 → 逐页
    /// `drawPDFPage` 到各自的纵向位置。CGContext 与 PDF 都是**左下原点、y 向上**，
    /// 所以不用翻转，只要把每页平移到"从顶部数第 N 段"的位置。
    /// ★ 标 nonisolated：转图是几千万像素的 CPU 活，调用方会把它丢到后台队列去，
    ///   在主线程隔离的类型里不标就调不了（只碰 CoreGraphics，不碰 UI，所以安全）。
    nonisolated static func rasterize(_ data: Data, targetScale: Double = 2.0,
                                      maxPixels: Double = 20_000_000) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider), doc.numberOfPages >= 1 else { return nil }

        // ① 量总尺寸（多页就按顺序竖着排）
        var boxes: [CGRect] = []
        var totalH: Double = 0
        var maxW: Double = 0
        for i in 1...doc.numberOfPages {
            guard let pg = doc.page(at: i) else { continue }
            let r = pg.getBoxRect(.mediaBox)
            guard r.width > 1, r.height > 1 else { continue }
            boxes.append(r)
            totalH += Double(r.height)
            maxW = max(maxW, Double(r.width))
        }
        guard !boxes.isEmpty, totalH > 1, maxW > 1 else { return nil }

        // ② 输出倍率：默认 2 倍（视网膜下字能看清）；超像素上限就等比降，最低 1 倍
        //    （1 倍 = PDF 自己的点数，仍然能看清字；再低就真糊了）
        var s = targetScale
        if maxW * totalH * s * s > maxPixels {
            s = max(1.0, sqrt(maxPixels / (maxW * totalH)))
        }
        let pxW = max(1, Int((maxW * s).rounded()))
        let pxH = max(1, Int((totalH * s).rounded()))

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // ③ 逐页画。某页的**底边** y = 总高 − 它上面所有页的高度和 − 它自己的高
        var above: Double = 0
        for (idx, box) in boxes.enumerated() {
            guard let pg = doc.page(at: idx + 1) else { continue }
            let h = Double(box.height)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat((totalH - above - h) * s))
            ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)   // 页面可能带原点偏移
            ctx.drawPDFPage(pg)
            ctx.restoreGState()
            above += h
        }

        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// 读 PDF 的页数和第一页尺寸 —— 用 CoreGraphics，不引 PDFKit（少一个依赖）
    private static func readInfo(_ data: Data) -> (Int, CGSize) {
        guard let p = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(p) else { return (0, .zero) }
        let box = doc.page(at: 1)?.getBoxRect(.mediaBox).size ?? .zero
        return (doc.numberOfPages, box)
    }

    /// 把 WebKit 的报错变成一句人话
    private static func readable(_ e: Error) -> String {
        // ★ WKError.webContentProcessTerminated 的类型是 WKError.Code（不是 WKError），
        //   不能用 case 匹配 —— 用 rawValue 比对（run #122 就是栽在这一行）
        if (e as NSError).code == WKError.webContentProcessTerminated.rawValue {
            return "网页渲染进程没响应（页面可能太重）"
        }
        let ns = e as NSError
        let m = ns.localizedDescription
        return m.isEmpty ? "未知原因（\(ns.domain) \(ns.code)）" : m
    }
}
