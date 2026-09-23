import AVFoundation
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
    @Published var remuxError: String?

    /// 本地文件（.ts 或 .mp4），用来在「文件」App 里找
    @Published var localURL: URL?

    /// 播放地址。**只能是本机 HTTP 上的 m3u8** ——
    /// 本地 .ts 和本地 .m3u8 都不能交给 AVPlayer（见 Exporter 顶部的说明）。
    @Published var playURL: URL?

    /// 在线地址（原始远端 m3u8）。本机服务起不来时，至少还能在线看。
    @Published var onlineURL: URL?

    /// 每一步的诊断记录，直接显示到界面上。
    /// 上一版只显示一句笼统原因（「本机播放服务没起来」），看不出卡在哪一环，
    /// 结果白跑一轮 —— 这次每一步成没成、为什么不成，全都记下来。
    @Published var notes: [String] = []

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

    // MARK: - 主流程

    private func run() async {
        guard let src = URL(string: sourceURL) else {
            failed = "地址不合法"; phase = "失败"; return
        }
        onlineURL = src

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent(Self.safeFileName(title) + ".ts")
        let temp = fm.temporaryDirectory.appendingPathComponent("vg_\(id.uuidString)")

        var opt = HLSDownloader.Options(
            concurrency: 4,
            timeout: 20,
            retry: 2,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            referer: nil,
            tempDir: temp,
            outputURL: out)
        if let host = src.host { opt.referer = "https://\(host)/" }

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
            let result = try await dl.run(sourceURL: src)
            if Task.isCancelled { return }

            let tsURL = result.fileURL
            localURL = tsURL
            outputName = tsURL.lastPathComponent
            notes.append("✓ 下载完成 \(tsURL.lastPathComponent)（\(result.segmentCount) 个分片 · \(Int(result.duration)) 秒）")

            let dir = tsURL.deletingLastPathComponent()

            // ── 1. 写一条只含这个 .ts 的 m3u8 ─────────────────────────
            var hls: URL?
            if let m3u8 = Self.writePlaylist(tsName: tsURL.lastPathComponent,
                                             duration: result.duration,
                                             folder: dir) {
                notes.append("✓ 生成播放清单 \(m3u8.lastPathComponent)")

                // ── 2. 起本机 HTTP 服务 ───────────────────────────────
                // 这是**唯一**能让 AVPlayer / AVAssetExportSession 读到本地 TS 的办法：
                // 本地 .ts 直接读不了，本地 .m3u8 也不行，HLS 必须来自 http。
                if let port = LocalHTTPServer.shared.start(root: dir),
                   let u = LocalHTTPServer.shared.url(m3u8.lastPathComponent) {
                    hls = u
                    playURL = u
                    notes.append("✓ 本机播放服务已启动 127.0.0.1:\(port)")
                } else {
                    notes.append("✗ 本机播放服务起不来：\(LocalHTTPServer.shared.lastError ?? "未知原因")")
                }
            } else {
                notes.append("✗ 写播放清单失败（磁盘空间或权限？）")
            }

            if hls == nil {
                notes.append("· 本机服务没起来时，只能用在线地址播放")
                notes.append("· 已下载的 .ts 在「文件」App 里，可用 VLC / nPlayer 打开")
            }

            // ── 3. 转 MP4 ────────────────────────────────────────────
            // 注意：即便上面失败了也照样往下走 —— 上一版就是在这里
            // 用 guard 直接 return，导致一个环节挂掉把整条链路全废掉。
            phase = "正在转 MP4…"
            let mp4URL = tsURL.deletingPathExtension().appendingPathExtension("mp4")
            var candidates: [URL] = []
            if let hls { candidates.append(hls) }
            candidates.append(src)          // 兜底：直接从原始地址转

            let (ok, log) = await Exporter.toMP4(
                candidates: candidates,
                mp4: mp4URL,
                onProgress: { [weak self] _, msg in
                    Task { @MainActor in
                        self?.phase = msg.isEmpty ? "正在转 MP4…" : msg
                    }
                })

            if Task.isCancelled { return }
            notes.append(contentsOf: log.map(\.line))

            if ok {
                mp4Ready = true
                localURL = mp4URL
                outputName = mp4URL.lastPathComponent
                phase = "完成：\(mp4URL.lastPathComponent)"
            } else {
                remuxError = log.last?.detail ?? "没成功"
                phase = "可以播放；MP4 没转出来（原因见下方）"
            }
            finished = true

        } catch {
            if Task.isCancelled { return }
            failed = error.localizedDescription
            phase = "失败"
            notes.append("✗ 下载失败：\(error.localizedDescription)")
        }
    }

    /// 给拼好的那个 .ts 写一条「只有一个分片」的 m3u8。
    ///
    /// HLS 规范允许分片是单条、长度任意。有了这条清单，本机 HTTP 服务
    /// 才有东西可提供，AVPlayer 才能读。
    private static func writePlaylist(tsName: String, duration: Double, folder: URL) -> URL? {
        let dur = max(1, duration)
        // 文件名里可能有中文和空格，m3u8 里按 URL 路径规则转义 ——
        // 这样本机服务和播放器两边都能正确取到这个文件。
        let ref = tsName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tsName
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:\(Int(ceil(dur)))
        #EXTINF:\(String(format: "%.3f", dur)),
        \(ref)
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
