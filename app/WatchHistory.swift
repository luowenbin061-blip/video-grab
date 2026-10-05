import AVFoundation
import Foundation
import UIKit

/// continuation 只许 resume 一次的小闸门 —— 多一次会直接崩。
/// （`DownloadJob` 里那个 `ResumeOnce` 是 private 的、跨文件用不了，这里自己来一个。）
private final class OnceFlag {
    var done = false
}

/// 一条「视频历史」。
///
/// ★★ 跟「浏览历史」（`BookmarkStore.history`）不是一回事，别混：
///   那条记的是**你打开过的网页**；这条记的是**网页里出现过的视频**。
///   一个页面可能有 0 个、也可能有好几个视频 → 一条视频一条记录。
struct WatchEntry: Codable, Identifiable, Equatable {

    /// 去重键 —— ★ v1.0.228 改成**只认视频本身**
    /// （旧键带页面地址，实测会刷出一堆重复，理由见 `WatchHistory.key`）：
    ///   · 有地址：`v|<地址去掉 query/fragment>`；
    ///   · 没地址（blob）：`b|<标题>|<时长>|<宽x高>`。
    /// ★ 用字符串而不是 UUID：同一个视频反复出现时，靠它**更新而不是新增**。
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

    /// ★ v1.0.229：**内容指纹** —— 收掉"换线路 / 换清晰度"造成的那批重复。
    ///   同一部片子的不同清晰度/线路，**标题和时长是一样的**，地址不一样。
    ///   所以拿「站点 + 归一化标题 + 时长（2 秒一档）」当"这是同一条"的判据。
    ///   ★★ 故意很保守（缺一条就不合并）：用户明确说了**两种错都不能接受** ——
    ///     · 标题必须非空、两边相同；
    ///     · 时长必须两边都 > 0 且落在同一个 2 秒档里。
    ///   这样"少一条"是不可能的：真正不同的片子，标题或时长至少有一条对不上。
    var mergeKey: String? { WatchHistory.mergeKey(title: title, dur: dur, page: page) }

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

    private init() {
        items = Self.readFromDisk()
        // ★ v1.0.228：读盘时做过一次迁移（旧键 → 新键 + 合并重复）。**立刻写回** ——
        //   不然每次启动都要重算，而且旧格式的文件会一直躺在那儿。
        if !items.isEmpty { flush() }
    }

    // MARK: - 位置

    private static var fileURL: URL { JobStore.dir.appendingPathComponent("watch_history.json") }

    /// 缩略图放在自己的子目录里，别跟下载任务的缩略图混在一起（`JobStore.dir` 根下全是任务产物）。
    static var thumbDir: URL { JobStore.dir.appendingPathComponent("watch_thumbs", isDirectory: true) }

    static func thumbURL(_ name: String) -> URL { thumbDir.appendingPathComponent(name) }

    // MARK: - 读写

    private static func readFromDisk() -> [WatchEntry] {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WatchEntry].self, from: d) else { return [] }
        return migrate(list)
    }

    /// ★ v1.0.228：把**旧格式**的键（`页面|地址`）迁到新格式（`v|地址`）+ 顺便去重。
    ///
    /// ★★ 为什么非迁不可：光改新写入的规则不够 —— 他手机里已经躺着几十条旧记录，
    ///   键还是老样子，会跟新记的**并存** → 他看到的"重复"一点没少。
    ///   所以读盘时就把旧的收编到新键下，撞车的合并成一条。
    private static func migrate(_ list: [WatchEntry]) -> [WatchEntry] {
        var out: [WatchEntry] = []
        var seen: [String: Int] = [:]                    // 新键 → 在 out 里的下标
        // ★ v1.0.229：内容指纹 → 下标（收掉"换清晰度 / 换线路"留下的那批重复）
        var byMerge: [String: Int] = [:]

        /// 撞车了 → 合并：能补的都补上，时间取最近的
        func merge(_ i: Int, _ e: WatchEntry) {
            if out[i].thumb == nil, e.thumb != nil { out[i].thumb = e.thumb }
            if !out[i].played, e.played { out[i].played = true }
            if out[i].video.isEmpty, !e.video.isEmpty { out[i].video = e.video }
            if out[i].poster.isEmpty, !e.poster.isEmpty { out[i].poster = e.poster }
            if e.at > out[i].at { out[i].at = e.at }
            if out[i].title.isEmpty, !e.title.isEmpty { out[i].title = e.title }
            if !e.page.isEmpty { out[i].page = e.page }
        }

        for var e in list {
            if !e.id.hasPrefix("v|"), !e.id.hasPrefix("b|"), let bar = e.id.firstIndex(of: "|") {
                let url = String(e.id[e.id.index(after: bar)...])
                if url.hasPrefix("http") { e.id = videoKey(url) }
            }
            // ★ v1.0.229：除了"同一个地址"，**内容指纹相同**也算同一条。
            //   用户手机里那批"切清晰度留下的重复"就是靠这一条收掉的。
            var hit = seen[e.id]
            if hit == nil, let mk = mergeKey(title: e.title, dur: e.dur, page: e.page) {
                hit = byMerge[mk]
            }
            if let i = hit {
                merge(i, e)
                seen[e.id] = i                                   // 这个地址以后也指到这条
                if let mk = mergeKey(title: out[i].title, dur: out[i].dur, page: out[i].page) {
                    byMerge[mk] = i
                }
            } else {
                seen[e.id] = out.count
                if let mk = mergeKey(title: e.title, dur: e.dur, page: e.page) {
                    byMerge[mk] = out.count
                }
                out.append(e)
            }
        }
        return out.sorted { $0.at > $1.at }
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

    /// ★ v1.0.228：去重键 —— **不再带页面地址**。
    ///
    /// 用户实测「还是会刷出一堆重复」，根因就在旧键 `页面|视频地址`：
    ///   · 播放器在 `<iframe>` 里的站（聚合站很常见），子 frame 上报时 `location.href`
    ///     是**子页面地址** —— 跟主页面不同 → 同一个视频被算成两条；
    ///   · 有些地址带 `?token=...`，每次刷新都不一样 → 每次都当"新的"。
    /// 新键只认**视频本身**：
    ///   · 有 src → src **去掉 query / fragment**（token 基本都在 query 里）；
    ///   · 没有 src（`blob:` 那种页面自制流）→ 用「标题 + 时长 + 尺寸」当指纹。
    static func key(title: String, v: PageVideo) -> String {
        if !v.src.isEmpty { return videoKey(v.src) }
        let t = v.vtitle.isEmpty ? title : v.vtitle
        return "b|" + t + "|\(v.dur)|\(v.w)x\(v.h)"
    }

    /// 只有地址时的键（`markPlayed` 也要用 —— 那边拿不到 `PageVideo`）
    static func videoKey(_ url: String) -> String {
        var s = url
        if let i = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex..<i])
        }
        return "v|" + s
    }

    /// ★★ v1.0.229：**内容指纹** —— 同一部片子的"换线路 / 换清晰度"版本靠它认成一条。
    ///
    /// 用户实测：「在页面里切到更高/更低清晰度，历史里就又新增一条，本质是同一条」。
    /// 根因是身份判据**只看地址**（换清晰度 = 换地址 = 他以为是新视频），
    /// 而同一个播放器换源时**标题和时长都不变** —— 那就用它们当判据。
    ///
    /// ★ 保守到"缺一条就不合并"，因为用户明确说**两种错都不能接受**：
    ///   · 标题必须非空（≥2 字）且两边归一化后完全相同；
    ///   · 时长必须两边都 > 0，且落在同一个 2 秒档里（`dur / 2`）。
    ///   反过来说：真正不同的片子，标题或时长至少有一条对不上 → **不会误并成一条**。
    static func mergeKey(title: String, dur: Int, page: String) -> String? {
        let t = normTitle(title)
        guard t.count >= 2, dur > 0 else { return nil }
        let host = (URL(string: page)?.host ?? "").lowercased()
        guard !host.isEmpty else { return nil }
        return host + "|" + t + "|" + String(dur / 2)
    }

    /// 标题归一化：**只用于"是不是同一条"的判断**（不改显示）。
    /// 去掉空白 / 全角空格 / 常见的站名后缀，避免"同一部片子不同页面标题略有差异"漏合并。
    static func normTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let junk = [" - 在线观看", "-在线观看", "在线观看", " - 免费在线观看",
                    "免费在线观看", "高清在线观看", "- 高清在线观看", "在线播放"]
        for j in junk where t.hasSuffix(j) { t = String(t.dropLast(j.count)) }
        t = t.replacingOccurrences(of: " ", with: "")
        t = t.replacingOccurrences(of: "\u{3000}", with: "")
        return String(t.prefix(60))
    }

    /// 页面视频清单到了 → 逐条记一笔（已存在的**更新**，不重复新增）。
    ///
    /// ★★ v1.0.229 口径变了（用户实测定）：**只记"我点开过的"**。
    ///   上一版是"网页里出现过就记、越全越好"，结果站里那些 10 秒以内的小视频、
    ///   悬停自动播的预览片全被记了进去 —— 他实测反馈"没主动点开也被记了一堆"。
    ///   现在只收 `v.ever`（判据在 `sniffer.js`：**在播 且 不是静音**）那一批。
    ///
    /// - Parameters:
    ///   - page:  当前页面地址（"打开原网页"的目标，也是合并判据的一部分）
    ///   - title: 当时的页面标题
    ///   - videos: `sniffer.js` 上报的页面视频清单
    ///   - playable: 把某个 `<video>` 换成"能播的地址"（拿不到就返回 nil）。
    ///     由 `BrowserModel` 传进来 —— 它是**唯一**知道"这个 video 对上哪个嗅探到的流"的地方。
    func note(page: String, title: String, videos: [PageVideo],
              playable: (PageVideo) -> String?) {
        guard Self.isEnabled else { return }
        guard !page.isEmpty, !videos.isEmpty else { return }
        // ★ 只收"被点开过"的 —— 没播过的一条都不记（这就是"误统计"的根治）
        let wanted = videos.filter { $0.ever }
        guard !wanted.isEmpty else { return }

        var touched = false
        var fresh: [(PageVideo, String)] = []      // 新记的 → 循环外再去拿封面（别边遍历边改数组）

        for v in wanted {
            let key = Self.key(title: title, v: v)
            let vt = v.vtitle.isEmpty ? title : v.vtitle     // ★ 视频自己的名字优先

            // ① 同一条地址 → 就地更新（最准的一路）
            if let i = items.firstIndex(where: { $0.id == key }) {
                var e = items[i]
                if v.dur > 0 { e.dur = v.dur }               // 时长/分辨率是后到的，能补就补
                if v.w > 0 { e.w = v.w; e.h = v.h }
                if e.video.isEmpty, let u = playable(v) { e.video = u }
                if e.poster.isEmpty, !v.poster.isEmpty { e.poster = v.poster }
                // ★ v1.0.228：标题和页面**总是**用最新一次上报的 ——
                //   这样旧记录里那条"站点名"能自愈成 og:title（不然它永远是错的）。
                if !vt.isEmpty { e.title = vt }
                if !page.isEmpty { e.page = page }
                e.at = Date()
                items[i] = e
                touched = true
                if e.thumb == nil { grabThumb(v, for: key) }
                continue
            }

            // ② ★ v1.0.229：内容指纹撞上 → 认成**同一条**（"换清晰度 / 换线路"走的就是这条）。
            //   用户要求"只保留最后一次的结果"→ 地址换成最新这次，并把这条提到最前面。
            if let mk = Self.mergeKey(title: vt, dur: v.dur, page: page),
               let i = items.firstIndex(where: { $0.mergeKey == mk }) {
                var e = items[i]
                if v.dur > 0 { e.dur = v.dur }
                if v.w > 0 { e.w = v.w; e.h = v.h }
                if let u = playable(v) { e.video = u }        // ★ 换成最新那次的地址
                if !v.poster.isEmpty { e.poster = v.poster }
                if !vt.isEmpty { e.title = vt }
                if !page.isEmpty { e.page = page }
                e.id = key                                   // 键跟着新地址走
                e.at = Date()
                items[i] = e
                items.remove(at: i)
                items.insert(e, at: 0)
                touched = true
                if e.thumb == nil { grabThumb(v, for: key) }
                continue
            }

            // ③ 全新的一条
            let e = WatchEntry(id: key, title: vt, page: page,
                               video: playable(v) ?? v.src,
                               poster: v.poster, thumb: nil,
                               dur: v.dur, w: v.w, h: v.h,
                               played: false, at: Date())
            items.insert(e, at: 0)
            fresh.append((v, key))
            touched = true
        }

        guard touched else { return }
        trim()
        scheduleFlush()
        for (v, id) in fresh { grabThumb(v, for: id) }
    }

    /// 用内置播放器播了它 —— 打上标记；**没有记录时顺手建一条**。
    ///
    /// ★ v1.0.229 改了两点（跟着"只记点开过的"这个口径走）：
    ///   ① 老实现"找不到就什么都不做" ── 但按新口径，**从播放这条路进来的正是"点开过"**，
    ///      所以没有记录时要补记（不然从「窗口」/长按/预览进来的就漏了）；
    ///   ② 顺手把标题/封面/时长一起带上，比之后再靠页面清单补更准。
    func markPlayed(page: String, title: String = "", video: String,
                    poster: String = "", shot: String = "", dur: Int = 0) {
        guard Self.isEnabled else { return }
        guard !video.isEmpty else { return }
        let key = Self.videoKey(video)

        if let i = items.firstIndex(where: { $0.id == key }) {
            items[i].played = true
            items[i].at = Date()
            if !title.isEmpty { items[i].title = title }
            if !page.isEmpty { items[i].page = page }
            if dur > 0 { items[i].dur = dur }
            if items[i].poster.isEmpty, !poster.isEmpty { items[i].poster = poster }
            let needThumb = (items[i].thumb == nil)
            scheduleFlush()
            if needThumb, !poster.isEmpty { downloadPoster(poster, referer: page, for: key) }
            else if needThumb, let n = saveShot(shot) { setThumb(n, for: key, replace: false) }
            return
        }

        // 没记过 → 现在记（他确实点开播了）
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = URL(string: page)?.host ?? "视频" }
        let e = WatchEntry(id: key, title: t, page: page, video: video,
                           poster: poster, thumb: nil, dur: dur, w: 0, h: 0,
                           played: true, at: Date())
        items.insert(e, at: 0)
        trim()
        scheduleFlush()
        if !poster.isEmpty { downloadPoster(poster, referer: page, for: key) }
        else if let n = saveShot(shot) { setThumb(n, for: key, replace: false) }
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

    /// 这条记录对应的原网页（下载封面图时当 Referer 用）。
    /// ★ v1.0.228：键里已经不带页面地址了，所以从记录本身取。
    private func pageOf(_ id: String) -> String {
        items.first(where: { $0.id == id })?.page ?? ""
    }

    /// `data:image/jpeg;base64,...` → 落盘，返回文件名。
    private func saveShot(_ dataURL: String) -> String? {
        guard dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard let d = Data(base64Encoded: b64), d.count > 800, d.count < 400_000 else { return nil }
        return Self.storeThumb(d)
    }

    private func downloadPoster(_ urlString: String, referer: String, for id: String) {
        guard let u = URL(string: urlString), u.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        // 封面图同样受防盗链管 —— 带上来源页最稳
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        // ★★ 这个闭包是**并发执行**的，所以里面一个 `self` 都不能碰 ——
        //   写 `guard let self` 会直接编译失败：
        //   "reference to captured var 'self' in concurrently-executing code"（run #226 就这么挂的）。
        //   修法：落盘这一步本来就是纯静态的（不需要主线程）→ 做成 `Self.storeThumb`；
        //   只有"更新列表"丢回主线程，而那里走的是 `WatchHistory.shared`，同样不碰 self。
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            guard let d, d.count > 800, d.count < 2_000_000,
                  let http = resp as? HTTPURLResponse, http.statusCode < 400 else { return }
            guard let name = Self.storeThumb(d) else { return }
            Task { @MainActor in
                // ★ replace: true —— 官方封面比"抓的那一帧"好看，值得换掉
                WatchHistory.shared.setThumb(name, for: id, replace: true)
            }
        }.resume()
    }

    // MARK: - ★ v1.0.228 抽帧兜底

    /// 已经试过抽帧的条目 —— 抽不到**不再重试**（免得每次进历史页都重跑一遍慢活）
    private var thumbTried: Set<String> = []
    private var filling = false

    /// 给**还没有封面**的条目补图。
    ///
    /// ★ 用户实测「多数网站的视频都没有缩略图」→ 明确要求"想想办法尽可能拿到…抽帧图"。
    /// ★ 为什么做成**懒加载**：抽帧要真的去加载那段视频（走流量、也慢）——
    ///   每浏览一个页面就抽一次不可接受，等他真去翻历史页时再补才对。
    /// ★ 一次最多补 `limit` 张、**一条一条串行**：同时开一堆 AVAssetImageGenerator
    ///   会把网络和 CPU 一起抢光，反而谁都抽不出来。
    /// ★ v1.0.229：一次只补 **4** 张（原来 12 张）—— 用户实测"网页卡死"，而抽帧是这套里
    ///   最重的活（要真的加载一段视频）。少而慢，别跟网页抢资源。
    func fillMissingThumbs(limit: Int = 4) {
        guard Self.isEnabled, !filling else { return }
        let todo = items.filter {
            $0.thumb == nil && !$0.video.isEmpty && !thumbTried.contains($0.id)
        }
        guard !todo.isEmpty else { return }
        filling = true
        let batch = Array(todo.prefix(limit))
        Task { @MainActor in
            for e in batch {
                self.thumbTried.insert(e.id)              // 先记账 —— 失败的也不再重试
                if let name = await Self.grabFrame(e.video, page: e.page) {
                    self.setThumb(name, for: e.id, replace: false)
                }
            }
            self.filling = false
        }
    }

    /// 用系统播放器抽一帧。
    ///
    /// ★ 这件事**不需要**我们的播放器那套（本机代理）—— 直接把地址交给 `AVAssetImageGenerator`。
    ///   它对**直链 mp4 / ts 最稳**；m3u8 要看那个站认不认我们带的请求头，
    ///   认不出就失败、**不重试**，反正列表有占位图，不影响任何功能。
    /// ★ 超时 8 秒：m3u8 抽帧要先加载清单、再下那一小段，慢是正常的，但不能无限等。
    private static func grabFrame(_ urlString: String, page: String) async -> String? {
        guard let u = URL(string: urlString), u.scheme?.hasPrefix("http") == true else { return nil }
        var opt: [String: Any] = [:]
        if !page.isEmpty { opt["AVURLAssetHTTPHeaderFieldsKey"] = ["Referer": page] }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u, options: opt))
        gen.appliesPreferredTrackTransform = true          // 竖屏的别被转成横的
        gen.maximumSize = CGSize(width: 480, height: 480)
        // 容忍 ±5 秒 —— 让它就近取，不必非解到第 3 秒那一帧（能快不少）
        gen.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)

        let t = CMTime(seconds: 3, preferredTimescale: 600)
        let cg: CGImage? = await withCheckedContinuation { cont in
            let once = OnceFlag()                          // continuation 只能 resume 一次
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, img, _, result, _ in
                if once.done { return }
                once.done = true
                cont.resume(returning: result == .succeeded ? img : nil)
            }
            // ★ 超时兜底：8 秒还没回调就自己收掉（否则 m3u8 那种会把这条任务一直吊着）
            // ★ v1.0.229：**顺手把生成器也停掉** —— 只 resume 不 cancel 的话，
            //   那个加载还在后台跑（占网络和内存），12 条一起吊着就是"资源被抽干"。
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if once.done { return }
                once.done = true
                gen.cancelAllCGImageGeneration()
                cont.resume(returning: nil)
            }
        }
        guard let cg, let d = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) else { return nil }
        return storeThumb(d)
    }

    /// 把一张图落盘，返回文件名。
    /// ★ 做成 **static**：下载回调跑在后台线程，这样它就不用碰 `self`
    ///   （也就没有"并发闭包里引用 self"那类编译错 —— 见 `downloadPoster` 的注释）。
    private static func storeThumb(_ d: Data) -> String? {
        let dir = thumbDir
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
