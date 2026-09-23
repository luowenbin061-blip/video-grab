import Foundation

/// 一个下载任务的前端状态。
///
/// 产物落点：App 自己的 Documents 目录。因为 Info.plist 里开了
/// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace，
/// 所以文件会直接出现在系统「文件」App → 我的 iPhone → 视频抓取 里，
/// 不需要任何额外权限、也不需要「导出」这一步。
@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    let id = UUID()
    let title: String
    let sourceURL: String

    @Published var phase = "排队中"
    @Published var done = 0
    @Published var total = 0
    @Published var finished = false
    @Published var failed: String?
    @Published var outputName: String?
    /// 转成 mp4 成功了吗（.ts 在 iOS 上系统播放器和微信都不认，所以要转）
    @Published var mp4Ready = false
    /// 转封装失败的原因（失败不算整体失败，.ts 还在）
    @Published var remuxError: String?
    /// 本地文件，用来播放（.ts 或 .mp4）
    @Published var localURL: URL?
    /// 播放用的地址。优先是「本机 HTTP 上的 m3u8」——
    /// 因为 iOS 读不了本地 .ts，但能读 HTTP 上的 HLS。
    @Published var playURL: URL?

    private var task: Task<Void, Never>?

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }

    init(title: String, sourceURL: String) {
        self.title = title
        self.sourceURL = sourceURL
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !finished { phase = "已取消（已下的分片保留，可再点继续）" }
    }

    private func run() async {
        guard let src = URL(string: sourceURL) else {
            failed = "地址不合法"; phase = "失败"; return
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent(Self.safeFileName(title) + ".ts")
        let temp = fm.temporaryDirectory
            .appendingPathComponent("vg_\(id.uuidString)")

        var opt = HLSDownloader.Options(
            concurrency: 4,
            timeout: 20,
            retry: 2,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            referer: nil,          // 目标源不校验 Referer；需要时再补
            tempDir: temp,
            outputURL: out)

        // 有些源会校验 Referer，带上页面地址更保险
        if let host = src.host {
            opt.referer = "https://\(host)/"
        }

        var dl = HLSDownloader(options: opt)
        dl.onProgress = { [weak self] d, t, msg in
            Task { @MainActor in
                guard let self else { return }
                self.done = d
                self.total = t
                self.phase = msg
            }
        }

        phase = "开始…"
        do {
            let out = try await dl.run(sourceURL: src)
            if Task.isCancelled { return }
            localURL = out.fileURL
            outputName = out.fileURL.lastPathComponent

            // ── 关键一步 ──────────────────────────────────────────────
            // iOS 的 AVFoundation 读不了本地 .ts（Apple 官方：TS 不会被支持，
            // 必须用 fMP4）。但它能读「通过 HTTP 提供的 HLS」。
            // 所以这里给这个 .ts 生成一条单分片的 m3u8，用本机 HTTP 暴露出去，
            // AVPlayer 就能播了；同一通道也能让 AVAssetReader 读到轨道去转 mp4。
            let dir = out.fileURL.deletingLastPathComponent()
            // 注意：这里必须显式比 != nil。
            // 写成 `let _ = start(...)` 是不行的 —— guard 里的 `let _ =` 永远通过，
            // 起不到「服务没起来就退出」的作用。
            guard let m3u8 = Self.writePlaylist(tsName: out.fileURL.lastPathComponent,
                                                duration: out.duration,
                                                folder: dir) else {
                remuxError = "写 m3u8 失败"
                phase = "已保存为 .ts，但没法准备播放"
                finished = true
                return
            }
            guard LocalHTTPServer.shared.start(root: dir) != nil,
                  let hls = LocalHTTPServer.shared.url(m3u8.lastPathComponent) else {
                remuxError = "本机播放服务没起来"
                phase = "已保存为 .ts，但播放服务启动失败"
                finished = true
                return
            }
            playURL = hls

            // 再试一步：从这条 HTTP 通道把它重封装成 mp4
            phase = "正在转成 MP4…"
            let mp4URL = out.fileURL.deletingPathExtension().appendingPathExtension("mp4")
            do {
                try await Remuxer.toMP4(hls: hls, mp4: mp4URL)
                if Task.isCancelled { return }
                mp4Ready = true
                localURL = mp4URL
                outputName = mp4URL.lastPathComponent
                phase = "完成：\(mp4URL.lastPathComponent)"
            } catch {
                // 转不出来不影响播放 —— 走本机 HTTP 照样能看。
                remuxError = error.localizedDescription
                phase = "可以播放（点下面那个按钮）；MP4 未生成"
            }
            finished = true
        } catch {
            if Task.isCancelled { return }
            failed = error.localizedDescription
            phase = "失败"
        }
    }

    /// 给拼好的那个 .ts 写一条「只有一个分片」的 m3u8。
    ///
    /// 为什么要这么绕：iOS 的 AVFoundation 读不了本地 .ts 文件
    /// （Apple 官方："TS files are not and will not be supported on iOS"），
    /// 但它能读通过 HTTP 提供的 HLS。所以把这个 .ts 包装成一条只含它自己的
    /// m3u8、再走本机 HTTP 暴露出去，AVPlayer 就能播了。
    /// HLS 规范允许分片是单条、且长度任意。
    private static func writePlaylist(tsName: String, duration: Double, folder: URL) -> URL? {
        let dur = max(1, duration)
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:\(Int(ceil(dur)))
        #EXTINF:\(String(format: "%.3f", dur)),
        \(tsName)
        #EXT-X-ENDLIST

        """
        let url = folder.appendingPathComponent("play_\(UUID().uuidString.prefix(8)).m3u8")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func safeFileName(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { n = "video" }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        n = n.components(separatedBy: bad).joined(separator: "_")
        if n.count > 60 { n = String(n.prefix(60)) }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .prefix(19)
        return "\(n)_\(stamp)"
    }
}
