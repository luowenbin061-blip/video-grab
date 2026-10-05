import Foundation
import UIKit

/// 一条「视频历史」。
///
/// ★★ 跟「浏览历史」（`BookmarkStore.history`）不是一回事，别混：
///   那条记的是**你打开过的网页**；这条记的是**网页里出现过的视频**。
///   一个页面可能有 0 个、也可能有好几个视频 → 一条视频一条记录。
struct WatchEntry: Codable, Identifiable, Equatable {

    /// 去重键：`页面地址 | 视频地址`；拿不到视频地址的（blob 那种）用 `页面地址 | blob<下标>`。
    /// ★ 用字符串而不是 UUID：同一个视频在同页反复出现时，靠它**更新而不是新增**。
    var id: String
    /// 标题（记的是**当时的页面标题** —— 这类站基本都是"页面标题即片名"）。
    var title: String
    /// 原网页地址 —— 「打开原网页」用它。
    var page: String
    /// 能**直接播**的地址。★ 可能为空：`blob:` 那种页面自制流本来就没有可播 URL。
    var video: String
    /// 页面自己声明的封面图地址（下载到本地之前先记着，也是"重试拿图"的依据）。
    var poster: String
    /// **本地**缩略图文件名（抓帧或下载下来的封面都在这里）。没有就是 nil。
    var thumb: String?
    var dur: Int
    var w: Int
    var h: Int
    /// 用内置播放器播过 —— 列表上给个小标记（"直接播放"优先给这种）。
    var played: Bool
    /// 最近一次见到它的时间（列表按它倒序）。
    var at: Date

    /// 列表上显示的域名
    var host: String {
        guard let h = URL(string: page)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"        // ★ 建一次就够：每条都 new 一个 DateFormatter 很贵
        return f
    }()

    var timeText: String { Self.fmt.string(from: at) }

    /// 时长 / 分辨率那一行小字
    var specText: String {
        var p: [String] = []
        if dur > 0 {
            let m = dur / 60, s = dur % 60
            p.append(m > 0 ? "\(m) 分 \(s) 秒" : "\(s) 秒")
        }
        if w > 0 && h > 0 { p.append("\(w)×\(h)") }
        if video.isEmpty { p.append("地址待抓") }
        return p.joined(separator: " · ")
    }

    /// 缩略图该显示的文字占位（没图时）
    var initial: String { title.isEmpty ? "视频" : String(title.prefix(1)) }
}

/// 视频历史 —— 网页里出现过的视频都记一笔。
///
/// ★★ 用户的明确要求（2026-10-05）：「记录的视频**越全越好**，
///   最好每个网页都得记录，**并不一定非得内置播放器播放过的**，并且**有缩略图**」。
///   → 所以写入的时机是**页面视频清单上报时**（`sniffer.js` 的 `scanVideos`），
///   不是"播放时"。播放只是给这一条**补一个 `played` 标记**。
///
/// ★ 存哪儿：`JobStore.dir`（App 私有的 Application Support）。
///   **绝不进局域网共享目录** —— 那是项目定死的规矩（同 Wi-Fi 谁拿到地址都能看）。
///
/// ★ 结构照抄 `WatchProgress`：单例 + `@Published` + 原子写 + 节流落盘。
///   为什么必须是可观察单例：列表要跟着自己刷新（播放完回来能立刻看到标记）。
///
/// ★ 只在主线程调用（页面回调、列表、播放器都在主线程）。
final class WatchHistory: ObservableObject {

    static let shared = WatchHistory()

    /// 总开关的 UserDefaults 键（设置页 `@AppStorage` 绑同一个键）。
    static let enabledKey = "watchHistoryOn"

    /// 最多留多少条。★ 用户要"越全越好"，但也不能无限涨 ——
    ///   超过就丢**最旧的**（连带它的缩略图文件一起删，别留孤儿）。
    static let maxItems = 500

    private static var enabledCache: Bool?

    /// 默认**开**（这个功能本体就是"记录"，默认关等于没做）。
    static var isEnabled: Bool {
        if let c = enabledCache { return c }
        let v = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        enabledCache = v
        return v
    }

    /// 设置页拨开关时调。
    /// ★ 关掉**不清空**已有的（跟「记录播放进度」那个开关刻意不一样）——
    ///   那个是"续看位置"，留着会突然冒出一堆旧进度；这个是"历史"，用户关掉多半只是
    ///   不想再记新的，已经记下的多半还想留着看。要清有明确的「清空」按钮。
    static func setEnabled(_ on: Bool) { enabledCache = on }

    @Published private(set) var items: [WatchEntry] = []

    private var lastFlush = Date.distantPast
    private var flushTask: Task<Void, Never>?
    private var imageCache = NSCache<NSString, UIImage>()

    private init() { items = Self.readFromDisk() }

    // MARK: - 位置

    private static var fileURL: URL { JobStore.dir.appendingPathComponent("watch_history.json") }

    /// 缩略图放在自己的子目录里，别跟下载任务的缩略图混在一起（`JobStore.dir` 根下全是任务产物）。
    static var thumbDir: URL { JobStore.dir.appendingPathComponent("watch_thumbs", isDirectory: true) }

    static func thumbURL(_ name: String) -> URL { thumbDir.appendingPathComponent(name) }

    // MARK: - 读写

    private static func readFromDisk() -> [WatchEntry] {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WatchEntry].self, from: d) else { return [] }
        return list.sorted { $0.at > $1.at }
    }

    private func flush() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)   // 原子写：写一半被杀也不留坏文件
        lastFlush = Date()
    }

    /// 别每来一条就写一次盘（页面视频清单是 400ms 一节流上报的）。
    private func scheduleFlush() {
        if Date().timeIntervalSince(lastFlush) > 3 { flush(); return }
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    // MARK: - 写入（本功能的入口）

    /// 页面视频清单到了 → 逐条记一笔（已存在的**更新**，不重复新增）。
    ///
    /// - Parameters:
    ///   - page:  当前页面地址（去重键的一半，也是"打开原网页"的目标）
    ///   - title: 当时的页面标题
    ///   - videos: `sniffer.js` 上报的页面视频清单
    ///   - playable: 把某个 `<video>` 换成"能播的地址"（拿不到就返回 nil）。
    ///     由 `BrowserModel` 传进来 —— 它是**唯一**知道"这个 video 对上哪个嗅探到的流"的地方。
    func note(page: String, title: String, videos: [PageVideo],
              playable: (PageVideo) -> String?) {
        guard Self.isEnabled else { return }
        guard !page.isEmpty, !videos.isEmpty else { return }

        var touched = false
        for v in videos {
            let vid = v.src.isEmpty ? "blob\(v.i)" : v.src
            let key = page + "|" + vid

            if let i = items.firstIndex(where: { $0.id == key }) {
                var e = items[i]
                if v.dur > 0 { e.dur = v.dur }               // 时长/分辨率是后到的，能补就补
                if v.w > 0 { e.w = v.w; e.h = v.h }
                if e.video.isEmpty, let u = playable(v) { e.video = u }
                if e.poster.isEmpty, !v.poster.isEmpty { e.poster = v.poster }
                if e.title.isEmpty, !title.isEmpty { e.title = title }
                e.at = Date()
                items[i] = e
                touched = true
                if e.thumb == nil { grabThumb(v, for: key) }
            } else {
                let e = WatchEntry(id: key, title: title, page: page,
                                   video: playable(v) ?? v.src,
                                   poster: v.poster, thumb: nil,
                                   dur: v.dur, w: v.w, h: v.h,
                                   played: false, at: Date())
                items.insert(e, at: 0)
                touched = true
                grabThumb(v, for: key)
            }
        }

        guard touched else { return }
        trim()
        scheduleFlush()
    }

    /// 用内置播放器播了它 —— 给这一条打个标记。
    /// ★ 找不到就**什么都不做**（不新增）：播放过的按道理早被页面清单记下了；
    ///   真没记上说明当时开关关着或者页面没上报，那也不该在这儿凭空造一条。
    func markPlayed(page: String, video: String) {
        guard let i = items.firstIndex(where: { $0.id == page + "|" + video }) else { return }
        guard !items[i].played else { return }
        items[i].played = true
        items[i].at = Date()
        scheduleFlush()
    }

    /// 删一条（连同它的缩略图文件）
    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let t = items[i].thumb { Self.deleteThumb(t) }
        imageCache.removeObject(forKey: (items[i].thumb ?? "") as NSString)
        items.remove(at: i)
        flush()
    }

    /// 全清（记录 + 缩略图文件）
    func removeAll() {
        for e in items { if let t = e.thumb { Self.deleteThumb(t) } }
        items = []
        imageCache.removeAllObjects()
        try? FileManager.default.removeItem(at: Self.fileURL)
        try? FileManager.default.removeItem(at: Self.thumbDir)
        lastFlush = Date()
    }

    /// 超出上限就丢最旧的（连带缩略图）
    private func trim() {
        guard items.count > Self.maxItems else { return }
        let going = items[Self.maxItems...]
        for e in going { if let t = e.thumb { Self.deleteThumb(t) } }
        items = Array(items.prefix(Self.maxItems))
    }

    // MARK: - 缩略图

    /// 取一张封面。优先级：
    ///   ① `poster`（页面自己声明的封面图）→ **下载**它（好看、准，但要等网络）；
    ///   ② JS 从画面**抓的那一帧**（同源才有；跨域抓不到）→ 直接落盘（快）。
    /// 两条都没有 → 不存图，界面显示占位。
    private func grabThumb(_ v: PageVideo, for id: String) {
        if !v.poster.isEmpty {
            downloadPoster(v.poster, referer: pageOf(id), for: id)
            return
        }
        if let name = saveShot(v.shot) { setThumb(name, for: id, replace: false) }
    }

    private func pageOf(_ id: String) -> String {
        guard let bar = id.firstIndex(of: "|") else { return "" }
        return String(id[id.startIndex..<bar])
    }

    /// `data:image/jpeg;base64,...` → 落盘，返回文件名。
    private func saveShot(_ dataURL: String) -> String? {
        guard dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard let d = Data(base64Encoded: b64), d.count > 800, d.count < 400_000 else { return nil }
        return writeThumb(d)
    }

    private func downloadPoster(_ urlString: String, referer: String, for id: String) {
        guard let u = URL(string: urlString), u.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        // 封面图同样受防盗链管 —— 带上来源页最稳
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] d, resp, _ in
            guard let d, d.count > 800, d.count < 2_000_000,
                  let http = resp as? HTTPURLResponse, http.statusCode < 400 else { return }
            Task { @MainActor in
                guard let self, let name = self.writeThumb(d) else { return }
                // ★ replace: true —— 官方封面比"抓的那一帧"好看，值得换掉
                self.setThumb(name, for: id, replace: true)
            }
        }.resume()
    }

    private func writeThumb(_ d: Data) -> String? {
        let dir = Self.thumbDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "wh_\(UUID().uuidString.prefix(12)).jpg"
        do {
            try d.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    private func setThumb(_ name: String, for id: String, replace: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            Self.deleteThumb(name)                 // 这条已经不在了（被删/被清）→ 别留孤儿图
            return
        }
        if items[i].thumb != nil {
            guard replace else { Self.deleteThumb(name); return }
            if let old = items[i].thumb {
                Self.deleteThumb(old)
                imageCache.removeObject(forKey: old as NSString)
            }
        }
        items[i].thumb = name
        scheduleFlush()
    }

    private static func deleteThumb(_ name: String) {
        try? FileManager.default.removeItem(at: thumbURL(name))
    }

    /// 缩略图（带内存缓存）。10KB 上下的小图，直接读+解码就够快，不必走异步。
    func image(for name: String) -> UIImage? {
        if let c = imageCache.object(forKey: name as NSString) { return c }
        guard let d = try? Data(contentsOf: Self.thumbURL(name)),
              let img = UIImage(data: d) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
        return img
    }

    /// 封面图请求用的 UA（跟 WebView 里那串保持一致，尽量别被防盗链挑出来）
    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
}
