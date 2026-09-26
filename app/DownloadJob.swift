import AVFoundation
import Darwin
import Foundation
import UIKit

/// 一次性闸门：continuation 只允许 resume 一次（多一次就崩），
/// 抽帧回调理论上只来一次，但防一下更省心。
private final class ResumeOnce {
    var done = false
}

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
    /// 暂停（用户点的，或被系统中断）—— 分片都留在磁盘上，点「继续」从断点接着下
    @Published var paused = false
    /// 当前阶段 + 本阶段计数 + 累计字节 —— 总百分比和 MB/s 都从这来
    @Published private(set) var stage: HLSDownloader.Stage = .prepare
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var convertProgress: Double = 0
    @Published private(set) var speedBytesPerSec: Int64 = 0
    @Published var finished: Bool
    @Published var failed: String?
    /// 能直接播的那个产物（转成功是 .mp4；没转成是 .ts）
    @Published var outputName: String?
    /// 列表缩略图的文件名（转码成功后抽一帧存的）。
    /// 抽不出来（.ts 没转成 / 抽帧失败）时是 nil —— 界面显示占位图，不影响功能。
    @Published var thumbName: String?
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
    /// 自动重试只用一次（每次 start 重置）—— 无限自动重试会一直烧流量
    private var autoRetried = false

    // MARK: - 诊断埋点（v1.0.89）

    /// ★ 为什么必须有（用户原话：「卡死或者闪退才是让一个 app 背负着一个超大炸弹」）：
    ///   只读代码锁不死根因 —— 内存压力、主线程被堵、引擎内部，三者静态上都排不掉。
    ///   所以在每次运行的**阶段边界**记三样东西，全部写进「过程记录」：
    ///     · **各阶段耗时** → 卡在哪一步
    ///     · **内存峰值** → 是不是内存压力（卡死 + 被系统杀）
    ///     · **主线程最长失联** → 是不是主线程被堵（那才是"界面卡死"）
    ///   下次再出问题，过程记录里直接有数据，不用再猜。
    private var stageMark: [String: Date] = [:]
    private var memPeak: Int64 = 0
    private var mainStallMs: Int = 0
    private var heartbeat: Task<Void, Never>?

    private static func stageName(_ s: HLSDownloader.Stage) -> String? {
        switch s {
        case .prepare:  return nil
        case .download: return "下载"
        case .join:     return "拼接"
        case .convert:  return "转码"
        case .finished: return nil
        }
    }

    private func stageBegin(_ name: String) {
        stageMark[name] = Date()
        memPeak = 0
        mainStallMs = 0
        startHeartbeat()
        notes.append("▶ \(name) 开始")
    }

    private func stageEnd(_ name: String) {
        stopHeartbeat()
        guard let t = stageMark[name] else { return }
        let sec = Date().timeIntervalSince(t)
        notes.append(String(format: "■ %@ 用时 %.1f 秒 · 内存峰值 %.0f MB · 主线程最长失联 %d 毫秒",
                            name, sec, Double(memPeak) / 1_048_576, mainStallMs))
        stageMark[name] = nil
        // 立刻落盘：万一下一步就崩了，这条记录必须已经在磁盘上
        onUpdate?()
    }

    /// 主线程心跳：每秒一次。
    /// ★ 关键点 —— 如果主线程被堵，**这个 Task 自己就会被推迟**，测出来的间隔就会变大。
    ///   这才是"界面卡死"的直接证据（内存压力导致的卡顿不会让它变这么大）。
    private func startHeartbeat() {
        stopHeartbeat()
        let target = self
        heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                target.memPeak = max(target.memPeak, Self.residentMemory())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = Date()
                let gap = Int(now.timeIntervalSince(last) * 1000)
                if gap > 2000 { target.mainStallMs = max(target.mainStallMs, gap) }
                last = now
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// 当前进程实际占用（resident size）
    nonisolated static func residentMemory() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// 本阶段内的进度（下载/拼接共用分片计数）
    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// 整条流程（下载 → 拼接 → 转码）的总百分比。
    /// 权重：下载 0.85 / 拼接 0.07 / 转码 0.08。转码是 -c copy 只换壳（秒级），
    /// 真正耗时的是下载 —— 给转码大头的话，条子会长时间停在高位不动，那是在骗人。
    var overall: Double {
        switch stage {
        case .prepare:  return 0
        case .download: return progress * 0.85
        case .join:     return 0.85 + progress * 0.07
        case .convert:  return 0.92 + convertProgress * 0.08
        case .finished: return 1
        }
    }

    var isActive: Bool { !finished && failed == nil && !paused }

    // MARK: - 速度（MB/s）

    /// 字节采样（近 6 秒的滑动平均 —— 单点跳动太大没法看）
    private var speedSamples: [(t: Date, b: Int64)] = []

    private func markSpeedSample() {
        let now = Date()
        speedSamples.append((now, bytesDone))
        while speedSamples.count > 2, now.timeIntervalSince(speedSamples[0].t) > 6 {
            speedSamples.removeFirst()
        }
        guard let first = speedSamples.first, speedSamples.count >= 2 else { return }
        let dt = now.timeIntervalSince(first.t)
        guard dt > 0.5 else { return }          // 间隔太短算出来会跳
        speedBytesPerSec = Int64(Double(bytesDone - first.b) / dt)
    }

    /// 给人看的速度；没在动的时候是空串
    var speedText: String {
        guard speedBytesPerSec > 0 else { return "" }
        let mb = Double(speedBytesPerSec) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB/s", mb)
                       : String(format: "%.0f KB/s", Double(speedBytesPerSec) / 1024)
    }

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
        // 请求上下文：Referer/UA 现在落盘 —— 跨重启续传要靠它们过防盗链；
        // Cookie 仍然不存（登录凭据写磁盘的代价大于收益，续传失败大不了
        // 从嗅探面板重开一次）。
        referrer = record.referrer ?? ""
        ua = record.ua ?? ""
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
        //
        // ★ v1.0.89 改：以前这里写 `failed = "上次运行中被中断（没下完）"` ——
        //   而列表的红字判据正是 `failed != nil`（ContentView.swift:1114）→
        //   **每次崩溃/被杀后台之后重启，任务都顶着一条假的"失败"红字**，
        //   用户以为下载失败了。其实它只是被中断、分片还在、可以直接继续。
        //   现在只标 paused（按钮自动变「继续」），不给 failed —— 不再谎报失败。
        if !record.finished, record.failed == nil {
            phase = "已中断（分片还在，可直接继续）"
            paused = true
        }
        let t = Self.thumbName(for: record.id)
        thumbName = JobStore.exists(named: t) ? t : nil

        // ★ v1.0.89 改：以前是 `!JobStore.exists(named: record.outputName)` ——
        //   outputName 还是 nil（只是"还没产出"）时 exists 返回 false →
        //   **fileMissing 被误判成 true**，界面会说"文件已不在"。
        //   现在只有"记录里写了产物名、但文件真的没了"才算 fileMissing。
        if let out = record.outputName, !out.isEmpty, !JobStore.exists(named: out) {
            fileMissing = true
            phase = "文件已不在"
        }
    }

    /// 存盘用的快照
    func snapshot() -> JobRecord {
        JobRecord(id: id,
                  title: title,
                  sourceURL: sourceURL,
                  referrer: referrer,
                  ua: ua,
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
        guard task == nil, !finished, !paused else { return }
        autoRetried = false
        task = Task { [weak self] in await self?.run() }
    }

    /// 用户点「暂停」。已下的分片都留在磁盘上，「继续」时从断点接着下。
    func pause() {
        guard task != nil else { return }
        paused = true                 // 先置标志：run() 的取消分支看到它就不会标成完成
        task?.cancel()
        task = nil
        phase = "已暂停（已下的分片保留）"
        onUpdate?()
    }

    /// 「继续 / 重试」是同一个动作：从已下的分片接着下（下过的不会重下）。
    /// 按钮文案分开（暂停→继续、失败→重试）只是给用户看的语义，底层没有区别。
    func resumeDownload() {
        guard task == nil, !isActive else { return }
        notes.append("· 继续下载（已下的 \(done) 个分片保留）")
        paused = false
        failed = nil
        finished = false
        phase = "继续下载…"
        start()
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

    /// 缩略图路径（文件还在才有值）
    var thumbURL: URL? {
        guard let n = thumbName, JobStore.exists(named: n) else { return nil }
        return JobStore.file(named: n)
    }

    /// 缩略图按任务 id 命名 —— 跟标题无关，以后改标题也不会错位
    static func thumbName(for id: UUID) -> String { "thumb_\(id.uuidString).jpg" }

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
        JobStore.remove([outputName, playlistName, baseName + ".ts", thumbName])
    }

    var baseName: String { "\(Self.safeFileName(title))_\(Self.stamp(createdAt))" }

    // MARK: - 小工具

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1024.0 / 1024.0)
    }

    /// 造一个能直接显示给人看的错误
    static func fail(_ msg: String) -> NSError {
        NSError(domain: "VideoGrab", code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// 直链下载落盘用什么扩展名：先看地址后缀，再看 Content-Type
    static func preferExtension(url: URL, contentType: String) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        switch contentType {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-matroska": return "mkv"
        case "video/mp2t": return "ts"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        default: return "mp4"
        }
    }

    /// 直链单文件（mp4 这类）：拉下来 → 能直接播就用它；不能播就试着转成 MP4。
    private func runDirectFile(src: URL, probe: SourceProbe, tempDir: URL,
                               ua: String, referer: String?, cookie: String?) async throws {
        let ext = Self.preferExtension(url: src, contentType: probe.contentType)
        let outURL = JobStore.file(named: baseName + "." + ext)

        var fopt = FileDownloader.Options(
            userAgent: ua,
            referer: referer,
            cookie: cookie,
            outputURL: outURL,
            partURL: tempDir.appendingPathComponent("direct.part"),
            expectedLength: probe.contentLength,
            acceptsRange: probe.acceptsRange)
        fopt.timeout = 30

        var fd = FileDownloader(options: fopt)
        fd.onProgress = { [weak self] got, tot in
            Task { @MainActor in
                guard let self else { return }
                self.stage = .download
                self.bytesDone = got
                self.done = Int(got / 262144)
                self.total = tot > 0 ? Int(tot / 262144) : 0
                var msg = "下载文件 \(Self.mb(got))MB"
                if tot > 0 { msg += " / \(Self.mb(tot))MB" }
                self.phase = msg
                self.markSpeedSample()
            }
        }

        let got = try await fd.run(url: src)
        if Task.isCancelled { paused = true; onUpdate?(); return }

        fileSize = got
        notes.append("✓ 直链下载完成 \(Self.mb(got))MB（.\(ext)）")

        if ["mp4", "m4v", "mov"].contains(ext) {
            mp4Ready = true
            outputName = outURL.lastPathComponent
            phase = "完成"
            finished = true
            onUpdate?()
            await makeThumbnail(from: outURL)
            return
        }

        // 不是 iOS 能直接播的格式（webm/mkv…）→ 试着转成 MP4
        phase = "正在转成 MP4…"
        let mp4URL = JobStore.file(named: baseName + ".mp4")
        let (convOK, log) = await Exporter.toMP4(
            ts: outURL, hls: nil, remote: src, mp4: mp4URL,
            onProgress: { [weak self] p, msg in
                Task { @MainActor in
                    guard let self else { return }
                    self.stage = .convert
                    self.convertProgress = p
                    self.phase = msg.isEmpty ? "正在转成 MP4…" : msg
                }
            })
        if Task.isCancelled { paused = true; onUpdate?(); return }
        notes.append(contentsOf: log.map(\.line))

        if convOK {
            mp4Ready = true
            outputName = mp4URL.lastPathComponent
            let detail = log.first(where: { $0.ok })?.detail ?? ""
            resolution = detail.components(separatedBy: " · ").first ?? detail
            fileSize = JobStore.size(of: mp4URL.lastPathComponent)
            JobStore.remove([outURL.lastPathComponent])
            phase = "完成 · MP4 已就绪"
            notes.append("✓ 已转成 MP4（程序内保存）")
            finished = true
            onUpdate?()
            await makeThumbnail(from: mp4URL)
        } else {
            remuxError = log.last?.detail ?? "没成功"
            outputName = outURL.lastPathComponent
            phase = "下载完成；MP4 没转出来（原因见过程记录）"
            notes.append("· 没转成 MP4，原文件留着（.\(ext)）—— 可以「存文件夹」后在电脑上处理")
            finished = true
            onUpdate?()
        }
    }

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
        dl.onProgress = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                // ★ 阶段切换就是埋点的落点（下载 → 拼接 → 转码）
                if p.stage != self.stage {
                    if let cur = Self.stageName(self.stage) { self.stageEnd(cur) }
                    if let nxt = Self.stageName(p.stage) { self.stageBegin(nxt) }
                }
                self.stage = p.stage
                self.done = p.done
                self.total = p.total
                self.bytesDone = p.bytes
                self.phase = p.message
                self.markSpeedSample()
            }
        }

        phase = "开始…"
        do {

            // ★ 先探一下这个地址到底是什么 —— 详见 SourceProbe 里的注释。
            //   嗅探只按地址字符串猜类型：mp4 直链、跳转页也会被当成 m3u8，
            //   统一塞给 m3u8 解析器的结果就是「一个分片都没解析出来」，
            //   而用户只看到一句失败、不知道卡在哪。探完才知道该走哪条路。
            //   探测结果同时写进过程记录 —— 以后出问题一眼看出原因。
            phase = "探测地址…"
            stageBegin("探测")
            let probe = await SourceProbe.fetch(url: src,
                                                ua: opt.userAgent,
                                                referer: opt.referer,
                                                cookie: opt.cookie,
                                                timeout: opt.timeout)
            notes.append("· 探测：\(probe.summary)")
            guard (200...299).contains(probe.httpStatus) else {
                throw Self.fail("地址取不到内容 —— \(probe.summary)")
            }
            if probe.kind == .unknown {
                throw Self.fail("这个地址认不出是什么（不是 HLS 清单，也不像视频文件）—— \(probe.summary)")
            }

            if probe.kind == .file {
                try await runDirectFile(src: src, probe: probe, tempDir: tempDir,
                                        ua: opt.userAgent, referer: opt.referer, cookie: opt.cookie)
                return
            }

            let result = try await dl.run(sourceURL: src)
            if Task.isCancelled { paused = true; onUpdate?(); return }

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
            if let cur = Self.stageName(stage) { stageEnd(cur) }
            stageBegin("转码")
            phase = "正在转成 MP4…"
            let mp4URL = JobStore.file(named: baseName + ".mp4")
            let (ok, log) = await Exporter.toMP4(
                ts: tsURL,
                hls: wrotePlaylist ? LocalHTTPServer.shared.url(playName) : nil,
                remote: src,
                mp4: mp4URL,
                onProgress: { [weak self] p, msg in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stage = .convert
                        self.convertProgress = p
                        self.phase = msg.isEmpty ? "正在转成 MP4…" : msg
                    }
                })

            if Task.isCancelled { paused = true; onUpdate?(); return }
            notes.append(contentsOf: log.map(\.line))

            var thumbSource: URL?          // 转成功了才有片子可抽
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
                thumbSource = mp4URL
            } else {
                remuxError = log.last?.detail ?? "没成功"
                outputName = tsURL.lastPathComponent
                playlistName = wrotePlaylist ? playName : nil
                phase = "可以播放；MP4 没转出来（原因见过程记录）"
            }

            // ★ v1.0.89 三件事一起补（以前全漏了）：
            //   ① `failed = nil` —— 成功块原来**只设 finished/mp4Ready，不清 failed**，
            //      而红字判据是 failed != nil → 成功也可能顶着红字。
            //   ② 转码也成功了，现在才清临时目录（分片留到这里就是为了崩了能续）。
            //   ③ 收尾埋点。
            failed = nil
            if let cur = Self.stageName(stage) { stageEnd(cur) }
            stageEnd("探测")
            try? FileManager.default.removeItem(at: tempDir)
            finished = true
            onUpdate?()
            // 缩略图放在「完成」之后抽：界面立刻变成完成态，图晚一两秒自己出现。
            // 抽不出来也没关系 —— 列表显示占位图，功能一点不受影响。
            if let s = thumbSource { await makeThumbnail(from: s) }

        } catch {
            if Task.isCancelled {
                // 暂停 / 外部取消：已下分片都在，点「继续」从断点接着下。
                // 老代码在这里置 finished = true —— 界面写着「可再点继续」、
                // 点了却被 start() 的守卫拒绝，那个矛盾就是这么来的。
                paused = true
                onUpdate?()
                return
            }
            // 自动重试一次：网络抖动占失败的大头，隔 1.5 秒再试能救回一大半。
            // 只自动试一次 —— 无限重试会一直烧流量，剩下的交给人工点「重试」。
            if !autoRetried {
                autoRetried = true
                notes.append("· 自动重试（第 1 次）—— 上次失败：\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled {
                    await run()
                    return
                }
            }
            if let cur = Self.stageName(stage) { stageEnd(cur) }
            stageEnd("探测")
            failed = error.localizedDescription
            phase = "失败"
            notes.append("✗ 下载失败：\(error.localizedDescription)")
            finished = true
            onUpdate?()
        }
    }

    /// 从成片里抽一帧当列表缩略图。
    ///
    /// 只用系统自带的 AVAssetImageGenerator：mp4 本来就是原生支持的格式，零依赖。
    /// 没转成 mp4 的任务（原样 .ts）抽不了 —— iOS 不认 TS，这恰好也是我们当初
    /// 非要转 mp4 的原因；那种情况列表显示占位图，不影响任何功能。
    private func makeThumbnail(from video: URL) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true      // 竖屏视频别被转成横的
        gen.maximumSize = CGSize(width: 480, height: 480)

        // 取「10% 处」那一帧 —— 比第 0 帧好看：开场往往是黑屏、台标或片头
        let d = duration > 0 ? duration : 1
        let t = CMTime(seconds: min(2.0, d * 0.1), preferredTimescale: 600)

        let cg: CGImage? = await withCheckedContinuation { cont in
            let once = ResumeOnce()
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, img, _, result, _ in
                // continuation 只能 resume 一次，多来一次会直接崩。
                // 这个回调理论上只会来一次，但值得防。
                if once.done { return }
                once.done = true
                cont.resume(returning: result == .succeeded ? img : nil)
            }
        }
        guard let cg, let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.72) else {
            notes.append("· 缩略图没抽出来（不影响播放和保存）")
            return
        }
        let n = Self.thumbName(for: id)
        try? data.write(to: JobStore.file(named: n), options: .atomic)
        thumbName = n
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

    // MARK: - 本地导入（工具箱「导入视频」）

    /// 从相册/「文件」导入的任务卡。跟下载不同：没有网络阶段，
    /// 直接进入「拷进程序内 → 探测能不能播 → 播不了才转码」。
    static func makeImported(originalName: String) -> DownloadJob {
        // 去扩展名用 NSString 的现成方法 —— 正则写在 Swift 字符串里
        // 反斜杠转义是个坑（\.\w 会直接编译不过）
        let name = (originalName as NSString).deletingPathExtension
        let j = DownloadJob(title: name.isEmpty ? "导入的视频" : name,
                            sourceURL: "local://import")
        j.phase = "正在导入…"
        return j
    }

    /// 导入流程。产物字段（outputName / mp4Ready / notes）跟下载共用 ——
    /// 列表卡片、播放、存相册/存文件夹全都不用改。
    func runImport(from tempURL: URL) async {
        let ext = tempURL.pathExtension
        let dest = JobStore.file(named: baseName + "." + (ext.isEmpty ? "mov" : ext))

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: tempURL, to: dest)
            try? FileManager.default.removeItem(at: tempURL)      // 临时副本使命完成
        } catch {
            failed = "导入失败：\(error.localizedDescription)"
            phase = "失败"
            notes.append("✗ 拷不进程序内：\(error.localizedDescription)")
            finished = true
            onUpdate?()
            return
        }
        notes.append("✓ 已复制进程序内（\(DownloadJob.sizeText(JobStore.size(of: dest.lastPathComponent)))）")

        // ── 探测：系统认不认这个文件（比看扩展名准 —— 扩展名会骗人，
        //    有的 .mp4 其实是系统不认的编码，有的 .mkv 里装的是认的）──
        phase = "正在识别视频…"
        let asset = AVURLAsset(url: dest)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let playable = (tracks?.isEmpty == false)

        if playable {
            // 按「mp4 不转、能播的也不折腾」的约定原样留着
            outputName = dest.lastPathComponent
            mp4Ready = true
            duration = (try? await asset.load(.duration).seconds) ?? 0
            fileSize = JobStore.size(of: outputName)
            if let t = tracks?.first, let size = try? await t.load(.naturalSize) {
                resolution = "\(Int(abs(size.width)))×\(Int(abs(size.height)))"
            }
            phase = "完成 · 本地导入"
            notes.append("✓ 系统能直接播，无需转码")
            finished = true
            onUpdate?()
            await makeThumbnail(from: dest)
            return
        }

        // 播不了 → 转成 MP4（-c copy 只换壳，秒级；
        // 除非里面装的是 iOS 不认的编码 —— 那种确实会慢，界面上写清楚）
        notes.append("· 系统播不了这个格式，试着转成 MP4…")
        phase = "正在转成 MP4…"
        let mp4URL = JobStore.file(named: baseName + ".mp4")
        let (ok, log) = await Exporter.toMP4(ts: dest, hls: nil, remote: nil,
                                             mp4: mp4URL,
                                             onProgress: { [weak self] p, msg in
                                                 Task { @MainActor in
                                                     guard let self else { return }
                                                     self.stage = .convert
                                                     self.convertProgress = p
                                                     self.phase = msg.isEmpty ? "正在转成 MP4…" : msg
                                                 }
                                             })
        notes.append(contentsOf: log.map(\.line))
        if ok {
            outputName = mp4URL.lastPathComponent
            mp4Ready = true
            fileSize = JobStore.size(of: outputName)
            JobStore.remove([dest.lastPathComponent])     // 换壳成功，原文件就多余了
            duration = (try? await AVURLAsset(url: mp4URL).load(.duration).seconds) ?? 0
            let detail = log.first(where: { $0.ok })?.detail ?? ""
            resolution = detail.components(separatedBy: " · ").first ?? detail
            phase = "完成 · 本地导入（已转成 MP4）"
            finished = true
            onUpdate?()
            await makeThumbnail(from: mp4URL)
        } else {
            // 转码失败：原文件留着（系统播不了但文件是好的），可以存出去用别的软件处理
            remuxError = log.last?.detail ?? "没成功"
            outputName = dest.lastPathComponent
            phase = "导入完成；这个格式系统播不了，转码也没成"
            finished = true
            onUpdate?()
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
