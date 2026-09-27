import SwiftUI
import UIKit
import ImageIO

/// 嗅探列表里的图片缩略图加载器。
///
/// **为什么不能用 AsyncImage**：图床/CDN 大多校验 Referer，而 AsyncImage 走的是
/// 系统默认请求、一个自定义头都不带 → 防盗链的图**一律空白**。
/// 不解决这一步，缩略图做出来也看不见东西。
///
/// **为什么要降采样**：一张 4000×3000 的图解码后约 48MB；列表里二三十张就是内存爆炸
/// （这正是"卡死/闪退"最经典的原因）。所以一律先按缩略图尺寸解，绝不整张读进内存。
enum ThumbLoader {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 24 * 1024 * 1024      // 24MB，超了自动淘汰最久没用的
        return c
    }()

    static func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    static func load(_ item: SniffItem) async -> UIImage? {
        let key = item.url as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let u = URL(string: item.url) else { return nil }

        var r = URLRequest(url: u, timeoutInterval: 20)
        // ★ 这三个头是能不能显示出来的关键 —— 跟下载走同一套页面上下文
        if !item.ua.isEmpty { r.setValue(item.ua, forHTTPHeaderField: "User-Agent") }
        if !item.referrer.isEmpty { r.setValue(item.referrer, forHTTPHeaderField: "Referer") }
        if !item.cookie.isEmpty { r.setValue(item.cookie, forHTTPHeaderField: "Cookie") }

        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let h = resp as? HTTPURLResponse, (200...299).contains(h.statusCode) else { return nil }
            guard let img = downsample(data, maxPx: 160) else { return nil }
            cache.setObject(img, forKey: key, cost: data.count)
            return img
        } catch {
            return nil
        }
    }

    /// ★ v1.0.111：本地文件（下好的图片）也走同一套降采样 —— 缩略图和大图都用它。
    /// 为什么不用 `UIImage(contentsOfFile:)`：那是**整张解码**，一张 4000×3000 的图
    /// 直接吃掉约 48MB，列表里几张就够把 App 顶到被系统杀。
    /// 这里用 CGImageSourceCreateWithURL，只解到要的尺寸。
    static func loadLocal(_ url: URL, maxPx: CGFloat = 160) async -> UIImage? {
        let key = "file:\(url.path)|\(Int(maxPx))" as NSString
        if let img = cache.object(forKey: key) { return img }
        // 解码放到后台队列 —— 一行图几十毫秒，放在主线程上滚动就会一顿一顿的
        let img: UIImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: downsampleFile(url, maxPx: maxPx))
            }
        }
        guard let img else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: key, cost: cost)
        return img
    }

    /// 从**文件 URL** 解出指定尺寸的位图（不整张读进内存）
    private static func downsampleFile(_ url: URL, maxPx: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx * UIScreen.main.scale
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 只解出缩略图尺寸的位图（原图整张不进内存）
    private static func downsample(_ data: Data, maxPx: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx * UIScreen.main.scale
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 列表行首的小缩略图（56×56）。
/// 只在进入视野时加载 —— List 本身是懒加载的，所以一屏只会请求能看到的那几张。
struct ThumbView: View {
    let item: SniffItem
    @State private var img: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.tertiarySystemFill))
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().scaleEffect(0.55)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color(.separator), lineWidth: 0.5))
        .task(id: item.url) {
            if let c = ThumbLoader.cached(item.url) {
                img = c
                return
            }
            failed = false
            let got = await ThumbLoader.load(item)
            if let got { img = got } else { failed = true }
        }
    }
}
