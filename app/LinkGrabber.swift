import Foundation
import WebKit

/// 工具箱「粘贴链接」的总调度：**认链接 → 走对应那条路 → 落到下载中心**。
///
/// 三条路（按"要不要自己算签名"分）：
///   · **磁力** `magnet:` → BT 引擎（另做）
///   · **B站** → 自己算 wbi 签名，取 DASH 音视频两条流 → 下 → 合并（本文件）
///   · **抖音 / 小红书 / 快手 / 其它** → **不算签名**，直接把网页打开，
///     让页面自己的 JS 带上正确的签名和 Cookie 去请求，**我们已有的嗅探器把真实地址接住**。
///     ★ 这条路是刻意的：这几个平台的签名（抖音 a_bogus、小红书 x-s）是"写一次、
///       过几天失效要重写"的那类；而"让网页自己去要"一次都不用写，且不会过期。
@MainActor
final class LinkGrabber: ObservableObject {

    /// 认出来的链接类型。
    /// 认出来的链接类型 —— **定义在 `LinkText` 里**。
    /// 为什么挪过去：识别逻辑要进云端单测（这工程只有"纯逻辑白名单"里的文件够得着），
    /// 而这个类 import 了 WebKit，进不去。这里留个别名方便引用，行为一个字没改。
    typealias Kind = LinkText.Kind

    /// 输入框里的内容
    @Published var text = ""
    /// 正在干活（解析 / 下载 / 合并）
    @Published var busy = false
    /// 当前在做什么（一行字，给用户看）
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var done = false

    // ★ v1.0.254：B站解析完先停在"选清晰度"（用户实测要求"各个清晰度让我选"）。
    /// 非空 = 等待用户选档（界面据此显示选择区）。
    @Published var qualityOptions: [BiliParse.Quality] = []
    /// 当前选中的档位码（默认最高档）。
    @Published var selectedQuality: Int = 0
    /// "登录解锁更高画质"的提示（空 = 不显示）。
    @Published var qualityHint: String = ""
    /// 解析成功的完整结果（用户点「下载」后拿它 + 选中档去下载）。
    private var pendingResolved: BiliParse.Resolved?
    /// ★ v1.0.258：本次解析的**原始链接** —— B站 选完档下载时，要把链接一起带进任务记录
    ///   （`originLink`），这样文件万一丢失，任务上还留着"重新下载"的线索。
    private var pendingLink: String?

    // MARK: - 认链接（实现全在 LinkText，这里只是转发）

    /// ★ `nonisolated`：这几个是**纯函数**，不碰任何界面状态。
    ///   标了之后别的隔离域（比如视图里的计算属性）也能直接调，
    ///   否则 `@MainActor` 会把类里的 static 成员一起隔离掉（这工程栽过同类）。
    /// ★★ 真正的实现在 `LinkText`（纯逻辑、能进单测）。这里**只转发**，
    ///   别把逻辑又写一份回来 —— 两份实现迟早会分叉。
    nonisolated static func kind(of link: String) -> Kind? {
        LinkText.kind(of: link)
    }

    /// 给用户看的一行说明。（界面里不写长篇解释，靠这行字点明接下来会发生什么。）
    nonisolated static func hint(for kind: Kind) -> String {
        LinkText.hint(for: kind)
    }

    // MARK: - 干活

    func reset() {
        busy = false
        stage = ""
        progress = 0
        error = nil
        done = false
        // ★ v1.0.254：选档状态一并清（换链接 / 重开卡片时不许残留上一条的档位）
        qualityOptions = []
        selectedQuality = 0
        qualityHint = ""
        pendingResolved = nil
        pendingLink = nil          // ★ v1.0.258
    }

    func handle(link: String, center: DownloadCenter, model: BrowserModel) {
        // ★★ 必须先"从文案里抠出链接"再走后面：
        //   用户点"粘贴"拿到的是**整段分享文案**（「【标题】 https://b23.tv/xxxx」），
        //   不是干净的网址。v1.0.245 就是漏了这一步 → 粘 B站 分享一律"认不出"。
        guard let kind = Self.kind(of: link),
              let url = LinkText.normalized(link) else {
            error = "认不出这条链接（现在认：磁力、B站、抖音、小红书、快手）"
            return
        }
        reset()
        switch kind {
        case .bili:
            runBili(link: url, center: center)
        case .web(let p):
            // ★ v1.0.257：这三家改成"直解"主路 —— 贴链接直接解析出直链下载（对齐 B站 体验）；
            //   解析不通自动回落"开网页 + 嗅探"（旧路变兜底，体验不倒退）。见 runShortVideo。
            runShortVideo(platform: p, link: url, center: center, model: model)
        case .magnet:
            // ★ 磁力交给 BT 引擎（**单例**，关掉卡片下载也不会断；状态由卡片上的
            //   `MagnetCard` 显示）。引擎自己会：拉元数据 → 列文件 → **等用户点开始** →
            //   下完自动登记进下载中心（引擎内兜底，卡片没开着也算数）。
            MagnetEngine.shared.center = center          // ★ v1.0.250：完成登记要用它
            if MagnetEngine.shared.start(magnet: url) {
                done = true
                stage = "已交给 BT 引擎"
                center.keepUsedSpaceFreshWhileBusy()   // ★ v1.0.250：磁力下载也要刷"占用"
            } else {
                error = MagnetEngine.shared.error ?? "BT 引擎起不来"
            }
        }
    }

    // MARK: - 抖音 / 小红书 / 快手（直解主路，失败回落嗅探）

    /// ★ v1.0.257：三家的"直解" —— 贴链接直接解析出直链下载；解析/下载失败**自动回落**
    ///   "开网页 + 嗅探"（旧路保留当兜底，体验不倒退）。
    ///   机制细节见 `ShortVideoParse` 文件头（全部 PC 实测过；DP 复核收据
    ///   ac-6ac8ecf1f8c66794d2addcf5）。失败口径：
    ///   · 解析失败 → 重试**一次**（在 ShortVideoParse 里就是"抓两遍"）→ 再失败回落；
    ///   · 直解成功但**下载失败**（直链带签名会过期）→ 重新解析一次换新链 → 再失败回落。
    private func runShortVideo(platform: LinkText.Kind.Platform, link: String,
                               center: DownloadCenter, model: BrowserModel) {
        busy = true
        stage = "解析中…"
        Task {
            do {
                var r = try await ShortVideoParse.resolve(link: link, platform: platform)
                do {
                    try await downloadDirect(r, center: center, originLink: link)
                } catch {
                    // 没下动（签名过期 / CDN 抖动）→ 重新解析一次换新链，不行才认输
                    stage = "下载没起来，重新解析一次…"
                    r = try await ShortVideoParse.resolve(link: link, platform: platform)
                    try await downloadDirect(r, center: center, originLink: link)
                }
                busy = false
                done = true
                stage = "已加入下载：\(r.title)"
            } catch {
                // 兜底：开网页 + 嗅探（原体验保留）
                busy = false
                let why = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                _ = model.newTab(load: link)
                done = true
                stage = "直解没成功（\(why)）。已改用网页方式打开：播放后去嗅探面板下载"
            }
        }
    }

    /// 下载直解出来的单个 mp4（复用断点下载器；UA/Referer 与解析保持一致）。
    /// 候选直链（多 CDN）**逐个试** —— 抖音给多条、快手给双镜像。
    private func downloadDirect(_ r: ShortVideoParse.Resolved,
                                center: DownloadCenter,
                                originLink: String? = nil) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("svgrab", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let name = Self.safeFileName(r.title)
        let out = tmp.appendingPathComponent(name + ".mp4")
        var lastError: Error = ShortVideoParse.SVError.noData("下载失败")

        for (i, u) in r.videoURLs.enumerated() {
            do {
                stage = r.videoURLs.count > 1
                    ? "下载中…（线路 \(i + 1)/\(r.videoURLs.count)）" : "下载中…"
                progress = 0
                _ = try await fetch(u, to: out, part: tmp.appendingPathComponent("v.part"),
                                    referer: r.referer, cookie: nil,
                                    userAgent: r.userAgent) { [weak self] d, t in
                    guard let self, t > 0 else { return }
                    self.progress = min(0.95, 0.95 * Double(d) / Double(t))
                }
                stage = "收尾…"
                progress = 0.98
                // 登记进下载中心（它会自己把文件挪进程序目录并做缩略图/体检）
                _ = center.adoptCompressed(out, title: r.title, kind: .video,
                                           originLink: originLink)   // ★ v1.0.258
                progress = 1
                return
            } catch {
                lastError = error
                try? fm.removeItem(at: out)   // 换下一条线前先清掉上一份
            }
        }
        throw lastError
    }

    // MARK: - B站

    private func runBili(link: String, center: DownloadCenter) {
        busy = true
        stage = "解析中…"
        Task {
            do {
                // ★ 顺手把 App 浏览器里登录过的 B站 Cookie 带上 ——
                //   不登也能解析，但只能拿到 480P；带上 SESSDATA 才有 1080P。
                //   这样用户**不用手抄 Cookie**，在浏览器里登一次就行。
                let cookie = await Self.biliCookie()
                let r = try await BiliParse.resolve(link: link, cookie: cookie)
                // ★★ v1.0.254：解析成功**先停在"选清晰度"**（不直接开下）——
                //   用户实测要求："各个清晰度让我选我要下载的画质"。
                //   界面据此显示档位选择区 + 「下载」按钮（见 PasteLinkSheet.qualityPicker）。
                pendingResolved = r
                pendingLink = link          // ★ v1.0.258：记下原始链接（下载时带进任务记录）
                qualityOptions = r.qualities
                selectedQuality = r.qualities.first?.value ?? 0
                qualityHint = Self.qualityHintText(for: r)
                busy = false
                stage = "选择清晰度"
            } catch {
                busy = false
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// ★ v1.0.254：用户点「下载」—— 用挑中的档位开始下载。
    /// （下载的是**解析时已经拿到的流地址**，不再重新请求 —— 快、且避免二次风控。）
    func downloadSelected(center: DownloadCenter) {
        guard !busy, let r = pendingResolved, !qualityOptions.isEmpty else { return }
        let q = qualityOptions.first { $0.value == selectedQuality } ?? qualityOptions[0]
        var rr = r
        rr.videoURL = q.videoURL
        rr.quality = q.value
        rr.qualityText = q.name
        busy = true
        stage = "准备下载…"
        Task {
            do {
                try await downloadAndMerge(rr, center: center, originLink: pendingLink)
                busy = false
                done = true
                stage = "已加入下载：\(rr.title)"
            } catch {
                busy = false
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// ★ v1.0.254：「为什么没有更高画质 / 怎么解锁」的提示文案（空 = 不提示）。
    ///   规则：把 `accept_quality` 里**高于实际下发最高档**的档名列出来 ——
    ///   未登录 → 引导去 App 浏览器登录（一次即可）；已登录 → 说明那是大会员档。
    nonisolated static func qualityHintText(for r: BiliParse.Resolved) -> String {
        guard let top = r.qualities.first?.value else { return "" }
        let higher = r.allowedQualities.filter { $0 > top }.sorted(by: >)
        guard !higher.isEmpty else { return "" }
        let names = higher.prefix(3).map { BiliParse.qualityName($0) }.joined(separator: " / ")
        if r.loggedIn {
            return "更高的 \(names) 需要大会员。"
        }
        return "当前未登录，平台只下发到 \(BiliParse.qualityName(top))；"
            + "在 App 浏览器里登录 B站 后可下载 \(names)。"
    }

    private func downloadAndMerge(_ r: BiliParse.Resolved,
                                  center: DownloadCenter,
                                  originLink: String? = nil) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pastegrab", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 收尾一定要清 —— 不然每解析一次就往临时目录里留一份几百兆
        defer { try? fm.removeItem(at: tmp) }

        let safeName = Self.safeFileName(r.title)
        let vOut = tmp.appendingPathComponent("v.m4s")
        let aOut = tmp.appendingPathComponent("a.m4s")
        let merged = tmp.appendingPathComponent(safeName + ".mp4")

        // ① 视频流
        stage = "下载画面（\(r.qualityText)）…"
        progress = 0
        let vBytes = try await fetch(r.videoURL, to: vOut, part: tmp.appendingPathComponent("v.part"),
                                     referer: BiliParse.mediaReferer, cookie: nil) { [weak self] d, t in
            guard let self, t > 0 else { return }
            self.progress = min(0.6, 0.6 * Double(d) / Double(t))
        }

        // ② 音频流（B站 DASH 一定是分开的两条；没有就说明是 durl 退路 → 直接就是完整文件）
        var finalMP4 = vOut
        if let aURL = r.audioURL {
            stage = "下载声音…"
            let aBytes = try await fetch(aURL, to: aOut, part: tmp.appendingPathComponent("a.part"),
                                         referer: BiliParse.mediaReferer, cookie: nil) { [weak self] d, t in
                guard let self, t > 0 else { return }
                self.progress = 0.6 + min(0.25, 0.25 * Double(d) / Double(t))
            }
            // ③ 合并（-c copy，不重编码 → 画质不掉）
            stage = "合并画面和声音…"
            progress = 0.88
            _ = try await AVRemux.merge(video: vOut, audio: aOut, out: merged,
                                        faststart: AVRemux.shouldFaststart(videoBytes: vBytes,
                                                                           audioBytes: aBytes))
            finalMP4 = merged
        } else {
            // durl 退路：本来就是一整个 mp4，改个名就行
            let direct = tmp.appendingPathComponent(safeName + ".mp4")
            try? fm.removeItem(at: direct)
            try fm.moveItem(at: vOut, to: direct)
            finalMP4 = direct
        }

        stage = "收尾…"
        progress = 0.95
        // ④ 登记进下载中心（它会自己把文件挪进程序目录并做缩略图/体检）
        _ = center.adoptCompressed(finalMP4, title: r.title, kind: .video,
                                   originLink: originLink)   // ★ v1.0.258
        progress = 1
    }

    /// 断点续传的单个文件下载（复用工程里那套 FileDownloader）。
    /// ★ v1.0.257：`userAgent` 参数化 —— 短链直解下载要用手机 UA（与解析保持一致）；
    ///   B站 那条路不传就还是原来的默认值，行为不变。
    private func fetch(_ url: URL, to out: URL, part: URL,
                       referer: String, cookie: String?,
                       userAgent: String = BiliParse.defaultUA,
                       onProgress: @escaping (Int64, Int64) -> Void) async throws -> Int64 {
        var opt = FileDownloader.Options(userAgent: userAgent,
                                         referer: referer,
                                         cookie: cookie,
                                         outputURL: out,
                                         partURL: part)
        opt.acceptsRange = true
        var fd = FileDownloader(options: opt)
        fd.onProgress = onProgress
        return try await fd.run(url: url)
    }

    /// 从 App 自己的浏览器里取 B站 的 Cookie（用户在浏览器里登过一次就够了）。
    /// ★ 取不到就返回空串 —— **空串照样能解析**，只是清晰度被平台限到 480P。
    static func biliCookie() async -> String {
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { list in
                cont.resume(returning: list)
            }
        }
        let mine = cookies.filter { $0.domain.lowercased().contains("bilibili.com") }
        guard !mine.isEmpty else { return "" }
        return mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 标题当文件名用之前先洗一遍（平台标题里带 `/` `:` 这种字符会让写文件直接失败）。
    nonisolated static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var out = ""
        for ch in s.unicodeScalars {
            out.append(bad.contains(ch) ? "_" : Character(ch))
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = "B站视频" }
        return String(out.prefix(60))
    }

    // MARK: - 重新下载（文件丢失后的出路）

    /// ★ v1.0.258：「重新下载」—— B站 / 短链直解的任务文件丢了之后，
    ///   靠任务里留的原始链接（`originLink`）重新解析、下载一遍。
    ///   自动选**最高可用档**（找回文件优先，不再停在"选清晰度"那一步）。
    ///   成败通过 `onDone(成功?, 说明)` 回给调用方 —— 列表层据此删老卡 / 写提示。
    static func redownload(link: String, center: DownloadCenter,
                           onDone: @escaping (Bool, String) -> Void) {
        let g = LinkGrabber()
        g.runRedownload(link: link, center: center, onDone: onDone)
    }

    private func runRedownload(link: String, center: DownloadCenter,
                               onDone: @escaping (Bool, String) -> Void) {
        Task {
            do {
                guard let kind = Self.kind(of: link),
                      let url = LinkText.normalized(link) else {
                    onDone(false, "这条原始链接现在认不出来了")
                    return
                }
                switch kind {
                case .bili:
                    let cookie = await Self.biliCookie()
                    let r = try await BiliParse.resolve(link: url, cookie: cookie)
                    // 自动挑最高可用档（跟手动选档时"默认最高"一个口径）
                    var rr = r
                    if let top = r.qualities.first {
                        rr.videoURL = top.videoURL
                        rr.quality = top.value
                        rr.qualityText = top.name
                    }
                    try await downloadAndMerge(rr, center: center, originLink: url)
                    onDone(true, rr.title)
                case .web(let p):
                    let r = try await ShortVideoParse.resolve(link: url, platform: p)
                    try await downloadDirect(r, center: center, originLink: url)
                    onDone(true, r.title)
                default:
                    onDone(false, "这类链接不支持重新下载")
                }
            } catch {
                onDone(false, (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
            }
        }
    }
}
