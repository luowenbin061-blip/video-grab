import AVFoundation
import Foundation

/// 一个下载任务的全部状态。
///
/// 产物落点：`JobStore.dir`（App 私有的 Application Support），
/// **不再往「文件」App 里塞** —— 需求是视频留在程序内，
/// 存到相册还是存到文件夹由用户在界面上自己点。
@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    let id: UUID
    let title: String
    let sourceURL: String
    let createdAt: Date
    /// 嗅探那一刻的页面上下文 —— 下载分片、取 AES key 都要带上。
    /// 不落盘：中断的任务不能续（下面 start 有守卫），用户会从嗅探面板重新点一次。
    let referrer: String
    let ua: String
    let cookie: String

    @Published var phase: String
    @Published var done = 0
    @Published var total = 0
    @Published var finished: Bool
    @Published var failed: String?
    /// 能直接播的那个产物（转成功是 .mp4；没转成是 .ts）
    @Published var outputName: String?
    @Published var mp4Ready: Bool
    /// 没转成 mp4 时，本地 .ts 要靠本机 HTTP 包成 HLS 才能播，这是清单文件名
    @Published var playlistName: String?
    @Published var remuxError: String?

    /// 文件大小 / 时长 / 分辨率 —— 列表上直接给用户看
    @Published var fileSize: Int64
    @Published var duration: Double
    @Published var resolution: String?

    /// 每一步的诊断记录
    @Published var notes: [String]

    /// 磁盘上的文件不在了（被系统清理或被用户删掉）
    @Published var fileMissing = false
    /// 存相册成功过
    @Published var savedToPhotos = false
    /// 界面上的一句话反馈（"已存到相册"这类）
    @Published var notice: String?

    /// 记录有变化时通知外层落盘
    var onUpdate: (() -> Void)?

    private var task: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var isActive: Bool { !finished && failed == nil }

    // MARK: - 构造

    init(title: String, sourceURL: String,
         referrer: String = "", ua: String = "", cookie: String = "") {
        id = UUID()
        self.title = title
        self.sourceURL = sourceURL
        self.referrer = referrer
        self.ua = ua
        self.cookie = cookie
        createdAt = Date()
        phase = "排队中"
        finished = false
        mp4Ready = false
        fileSize = 0
        duration = 0
        notes = []
    }

    /// 从磁盘上的记录恢复
    init(record: JobRecord) {
        id = record.id
        title = record.title
        sourceURL = record.sourceURL
        createdAt = record.createdAt
        // 恢复的历史记录没有（也不需要）请求上下文
        referrer = ""
        ua = ""
        cookie = ""
        phase = record.phaseText
        finished = true
        failed = record.failed
        outputName = record.outputName
        mp4Ready = record.mp4Ready
        playlistName = record.playlistName
        fileSize = record.fileSize
        duration = record.duration
        resolution = record.resolution
        notes = record.notes

        // 上次是下到一半被关掉的
        if !record.finished, record.failed == nil {
            failed = "上次运行中被中断（没下完）"
            phase = "中断"
        }
        if !JobStore.exists(named: record.outputName) {
            fileMissing = true
            if record.outputName != nil {
                phase = "文件已不在"
            }
        }
    }

    /// 存盘用的快照
    func snapshot() -> JobRecord {
        JobRecord(id: id,
                  title: title,
                  sourceURL: sourceURL,
                  createdAt: createdAt,
                  finishedAt: finished ? Date() : nil,
                  finished: finished,
                  failed: failed,
                  outputName: outputName,
                  mp4Ready: mp4Ready,
                  playlistName: playlistName,
                  fileSize: fileSize,
                  duration: duration,
                  resolution: resolution,
                  phaseText: phase,
                  notes: notes)
    }

    // MARK: - 控制

    func start() {
        guard task == nil, !finished else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !finished {
            phase = "已取消（已下的分片保留，可再点继续）"
        }
    }

    // MARK: - 播放 / 导出 / 删除

    /// 能在 App 内播的地址。**每次现算，不缓存** ——
    /// 本机 HTTP 服务的端口每次启动都可能变，存旧地址就会白屏。
    func localPlaybackURL() -> URL? {
        guard !fileMissing, let n = outputName else { return nil }

        // 转成 mp4 的直接播本地文件 —— 最稳，不需要任何服务
        if mp4Ready, JobStore.exists(named: n) {
            return JobStore.file(named: n)
        }
        // 没转成 mp4：本地 .ts 只能靠本机 HTTP 包成 HLS 才能被播放器读
        guard let pl = playlistName, JobStore.exists(named: n) else { return nil }
        guard LocalHTTPServer.shared.start(root: JobStore.dir) != nil else { return nil }
        return LocalHTTPServer.shared.url(pl)
    }

    /// 能导出的文件（优先 mp4）
    func exportURL() -> URL? {
        guard let n = outputName, JobStore.exists(named: n) else { return nil }
        return JobStore.file(named: n)
    }

    var canSaveToPhotos: Bool { mp4Ready && JobStore.exists(named: outputName) }

    func saveToPhotos() async {
        guard let u = exportURL() else {
            show("文件不在了"); return
        }
        do {
            try await Saver.toPhotos(u)
            savedToPhotos = true
            show("已存到相册")
            notes.append("✓ 已存到系统相册")
            onUpdate?()
        } catch {
            show(error.localizedDescription)
            notes.append("✗ 存相册失败：\(error.localizedDescription)")
        }
    }

    func show(_ s: String) {
        notice = s
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self?.notice == s { self?.notice = nil }
        }
    }

    /// 删掉任务的同时把文件也删掉
    func deleteFiles() {
        task?.cancel()
        task = nil
        JobStore.remove([outputName, playlistName, baseName + ".ts"])
    }

    var baseName: String { "\(Self.safeFileName(title))_\(Self.stamp(createdAt))" }

    // MARK: - 主流程

    private func run() async {
        guard let src = URL(string: sourceURL) else {
            failed = "地址不合法"; phase = "失败"; finished = true; onUpdate?(); return
        }

        let fm = FileManager.default
        let tsURL = JobStore.file(named: baseName + ".ts")
        let tempDir = JobStore.dir.appendingPathComponent("parts_\(id.uuidString)")

        // 优先用嗅探时抓到的真实页面上下文；抓不到才退到猜测值。
        // 之前 referer 只是 "https://源站域名/" 猜的 —— 防盗链站照样 403。
        let fallbackUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        var opt = HLSDownloader.Options(
            concurrency: 4,
            timeout: 20,
            retry: 2,
            userAgent: ua.isEmpty ? fallbackUA : ua,
            referer: referrer.isEmpty ? nil : referrer,
            tempDir: tempDir,
            outputURL: tsURL)
        opt.cookie = cookie.isEmpty ? nil : cookie
        if opt.referer == nil, let host = src.host { opt.referer = "https://\(host)/" }

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

            duration = result.duration
            fileSize = JobStore.size(of: tsURL.lastPathComponent)
            notes.append("✓ 下载完成 \(result.segmentCount) 个分片 · \(Int(result.duration)) 秒")

            // ── 写一条只含这个 .ts 的 m3u8 ──────────────────────────
            // 只在"转 mp4 失败"时才用得上（本地 .ts 必须靠本机 HTTP 包成 HLS 才能播）
            let playName = "play_\(id.uuidString.prefix(8)).m3u8"
            let wrotePlaylist = Self.writePlaylist(tsName: tsURL.lastPathComponent,
                                                   duration: result.duration,
                                                   folder: JobStore.dir,
                                                   name: playName) != nil

            // ── 自动转 MP4（留在程序内，不外发）────────────────────
            phase = "正在转成 MP4…"
            let mp4URL = JobStore.file(named: baseName + ".mp4")
            let (ok, log) = await Exporter.toMP4(
                ts: tsURL,
                hls: wrotePlaylist ? LocalHTTPServer.shared.url(playName) : nil,
                remote: src,
                mp4: mp4URL,
                onProgress: { [weak self] _, msg in
                    Task { @MainActor in
                        self?.phase = msg.isEmpty ? "正在转成 MP4…" : msg
                    }
                })

            if Task.isCancelled { return }
            notes.append(contentsOf: log.map(\.line))

            if ok {
                mp4Ready = true
                outputName = mp4URL.lastPathComponent
                playlistName = nil
                // 列表上只放短的那一段（"H.264 1920×1080 @25.00fps"），完整的在过程记录里
                let detail = log.first(where: { $0.ok })?.detail ?? ""
                resolution = detail.components(separatedBy: " · ").first ?? detail
                fileSize = JobStore.size(of: outputName)
                // 转成功了就把 .ts 和清单删掉 —— 留着只是白占一份空间
                JobStore.remove([tsURL.lastPathComponent, playName])
                phase = "完成 · MP4 已就绪"
                notes.append("✓ 已转成 MP4（程序内保存，需要的话点「存相册」或「存文件夹」）")
            } else {
                remuxError = log.last?.detail ?? "没成功"
                outputName = tsURL.lastPathComponent
                playlistName = wrotePlaylist ? playName : nil
                phase = "可以播放；MP4 没转出来（原因见过程记录）"
            }

            finished = true
            onUpdate?()

        } catch {
            if Task.isCancelled {
                finished = true
                onUpdate?()
                return
            }
            failed = error.localizedDescription
            phase = "失败"
            notes.append("✗ 下载失败：\(error.localizedDescription)")
            finished = true
            onUpdate?()
        }
    }

    /// 给拼好的 .ts 写一条「只有一个分片」的 m3u8（HLS 允许单分片、长度任意）
    private static func writePlaylist(tsName: String, duration: Double,
                                      folder: URL, name: String) -> URL? {
        let dur = max(1, duration)
        // 文件名可能有中文和空格，按 URL 路径规则转义，本机和播放器两边才都取得到
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
        let url = folder.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 文件名

    static func safeFileName(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { n = "video" }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        n = n.components(separatedBy: bad).joined(separator: "_")
        if n.count > 50 { n = String(n.prefix(50)) }
        return n
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// 给人看的尺寸
    static func sizeText(_ n: Int64) -> String {
        if n <= 0 { return "—" }
        let mb = Double(n) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(n) / 1024)
    }

    static func durationText(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
