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
        case .web:
            // ★ 不算签名那条路：把网页打开就行，剩下交给已有的嗅探器
            _ = model.newTab(load: url)
            done = true
            stage = "已在浏览器打开，页面开始播放后去嗅探面板找它"
        case .magnet:
            error = "磁力这条还在打通 BT 引擎，先放一放"
        }
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
                try await downloadAndMerge(r, center: center)
                busy = false
                done = true
                stage = "已加入下载：\(r.title)"
            } catch {
                busy = false
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func downloadAndMerge(_ r: BiliParse.Resolved,
                                  center: DownloadCenter) async throws {
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
        _ = center.adoptCompressed(finalMP4, title: r.title, kind: .video)
        progress = 1
    }

    /// 断点续传的单个文件下载（复用工程里那套 FileDownloader）。
    private func fetch(_ url: URL, to out: URL, part: URL,
                       referer: String, cookie: String?,
                       onProgress: @escaping (Int64, Int64) -> Void) async throws -> Int64 {
        var opt = FileDownloader.Options(userAgent: BiliParse.defaultUA,
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
}
