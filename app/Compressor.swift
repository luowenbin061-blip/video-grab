import AVFoundation
import Foundation

/// 「压画质省空间」—— 把已下载的成品**重新编码**成更小的文件。
///
/// ══ ★ 和「转成 MP4」完全不是一回事（别混）══
///   · 转 MP4 = **换封装**（`-c copy`）：无损、秒级（实测 21 分钟的片子 9.5 秒）
///   · 压缩   = **重新编码**：有损、分钟级
///   所以它是工具箱里一个**独立**的功能，不是"转 MP4"的一个选项 —— 混在一起会误导预期。
///
/// ══ 每个取舍的依据（都不是随手写的）══
///   · **走硬件编码器** `h264_videotoolbox`：实测内嵌 ffmpeg 的产物里有它（还有 `libx264` 兜底）。
///     硬件编码比软件快 5~10 倍，而且发热小得多 —— 这是"压缩"能不变成折磨的关键。
///   · **音频 `-c copy`**：源音频本来就已是有损编码，重编一次是白损音质、还省不了几十 KB；
///     顺带躲开"内置 aac 编码器是 experimental（要 `-strict -2`）"这个坑。
///   · **用 `-b:v` 定码率，不用质量模式**：质量模式输出体积不可预测，
///     而界面上要显示"286MB → 约 142MB"，**必须可预测**。
///   · **`-maxrate` / `-bufsize`**：给码率加天花板，防复杂场景体积飙升。
///   · **进度走 `-progress <文件>`**：进程内跑 ffmpeg 拿不到它的 stdout，
///     所以让它把进度**写成文件**、我们在外面轮询（实测它会写 `out_time_us`、`speed`）。
///   · **先写 `.partial`、成功后原子改名**：中途失败/被杀不会留下一个"看着像成品"的坏文件。
///   · **压完必须体检**：真的变小了（<95%）而且没小到离谱（>2%）、成品里有画面 ——
///     任意一条不过就当失败、删掉半成品。**这套体检是拿真事故换来的**：
///     以前"钥匙用错"时 ffmpeg 退出码照样是 0，只是内容少了 2/3。
///   · **绝不自动删原片**：压缩不可逆，删不删由用户明确决定（这个文件不碰原片）。
enum Compressor {

    // MARK: - 档位

    /// 画质档位。
    /// ★ 预估体积按「(视频码率 + 音频码率) × 时长」算，音频按 **128 kbps** 估
    ///   （`-c copy` 后音频码率不变，源大多是 AAC 128k）。
    ///   **音轨也要占体积** —— 别只按视频码率估，那样会偏乐观 15~25%。
    enum Tier: String, CaseIterable, Identifiable {
        case light, standard, strong

        var id: String { rawValue }

        var title: String {
            switch self {
            case .light:    "轻压"
            case .standard: "标准"
            case .strong:   "激进"
            }
        }

        /// 视频码率（bps）—— 直接进 ffmpeg 的 `-b:v`
        var videoBitrate: Int {
            switch self {
            case .light:    1_400_000
            case .standard:   800_000
            case .strong:     450_000
            }
        }

        /// 目标**宽度**上限（不放大）。竖屏片就是它的"短边"。
        /// nil = 保持原分辨率，只降码率。
        var maxWidth: Int? {
            switch self {
            case .light:    nil
            case .standard: 854      // 竖屏 1280 → 854 宽（≈0.67 倍）
            case .strong:   640      // → 640 宽（0.5 倍）
            }
        }

        /// 界面上那句人话（说清"省多少"和"画面会怎样"）
        var blurb: String {
            switch self {
            case .light:    "保留原分辨率，只把码率降一点"
            case .standard: "手机上够清楚，体积大约省一半"
            case .strong:   "最省空间，画面会明显糊一些"
            }
        }
    }

    // MARK: - 失败原因（说人话）

    enum Fail: LocalizedError {
        case noInput
        case noVideoTrack
        case ffmpegFailed(Int32)
        case outputMissing
        case didNotShrink

        var errorDescription: String? {
            switch self {
            case .noInput:              "这个文件读不到（可能已经被删了）"
            case .noVideoTrack:         "这个文件里没有画面，压不了"
            case .ffmpegFailed(let c):  "压缩失败（ffmpeg 退出码 \(c)，0 才算成功）"
            case .outputMissing:        "压缩跑完了但没有产出文件"
            case .didNotShrink:         "压完没变小 —— 这条件子用这个档位不划算。原片没动，半成品已删"
            }
        }
    }

    /// 预估体积（字节）。用来在档位上直接显示"286MB → 约 142MB"。
    static func estimateBytes(tier: Tier, duration: Double) -> Int64 {
        let audioBps = 128_000.0
        return Int64((Double(tier.videoBitrate) + audioBps) * max(0, duration) / 8.0)
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    // MARK: - 跑一次

    /// `onProgress` 的 progress 是 0~1（按 ffmpeg 报的已编码时长 ÷ 总时长算）。
    /// 返回：成品地址、字节数、一句人话的结果。
    static func run(input: URL, tier: Tier,
                    onProgress: @escaping (Double, String) -> Void) async throws
        -> (url: URL, bytes: Int64, note: String) {

        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else { throw Fail.noInput }

        // 时长与画面宽度：从素材里读 —— 算进度和"要不要缩放"都要用
        let asset = AVURLAsset(url: input)
        let duration: Double
        let sourceWidth: Int
        do {
            duration = try await asset.load(.duration).seconds
            let vtracks = try await asset.loadTracks(withMediaType: .video)
            guard let first = vtracks.first else { throw Fail.noVideoTrack }
            // ★ 这两处**故意用同步读法**：`load(.naturalSize)` 这类异步属性加载在旧系统上
            //   不保证可用（我们的部署目标是 iOS 15），同步访问器一定有，最稳。
            let size = first.naturalSize
            let transform = first.preferredTransform
            sourceWidth = Int(abs(size.applying(transform).width).rounded())
        } catch let e as Fail {
            throw e
        } catch {
            throw Fail.noInput
        }

        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let outFinal = dir.appendingPathComponent(base + "_压缩.mp4")
        // ★★ 临时文件名**必须以媒体后缀结尾**（这里以 `.mp4` 收尾，`partial` 放在中间）。
        //   真机 2026-09-28 的事故：一开始写成 `xxx_压缩.mp4.partial` —— ffmpeg 认不出输出格式，
        //   报 "Unable to choose an output format ... use a standard extension for the filename"，
        //   **秒退**（三个档位全都秒失败）。
        //   ★ 同一个坑**同一天踩了两次**：上午是"输入"名用了 `.part` 被 ffmpeg 白名单拒，
        //     这次是"输出"名。**交给 ffmpeg 的文件名，两端都必须是它认识的媒体后缀。**
        let outTmp = dir.appendingPathComponent(base + "_压缩.partial.mp4")
        let progressFile = dir.appendingPathComponent(".compress_progress.txt")
        try? fm.removeItem(at: outTmp)
        try? fm.removeItem(at: outFinal)
        try? fm.removeItem(at: progressFile)

        var argList = ["-hide_banner", "-loglevel", "error", "-y",
                       "-i", input.path,
                       "-c:v", "h264_videotoolbox",
                       "-b:v", "\(tier.videoBitrate)",
                       "-maxrate", "\(Int(Double(tier.videoBitrate) * 1.5))",
                       "-bufsize", "\(tier.videoBitrate * 2)"]
        if let cap = tier.maxWidth, sourceWidth > cap {
            // 只缩不放：源比目标还窄就保持原样（`-2` = 高度按比例取偶数）
            argList += ["-vf", "scale=\(cap):-2"]
        }
        argList += ["-c:a", "copy",                 // 音频原样搬，见文件头
                    "-progress", progressFile.path, "-nostats",
                    outTmp.path]

        // ★ 要进并发闭包的集合，先在外面拼完再绑成 let（run #138 的坑）
        let args = argList
        onProgress(0, "正在压缩…")

        // ffmpeg 把进度写进文件，我们每 500ms 读一次
        let poller = Task { () -> Void in
            while !Task.isCancelled {
                if let text = try? String(contentsOf: progressFile, encoding: .utf8),
                   let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
                   let us = Int64(line.dropFirst("out_time_us=".count)) {
                    let doneSec = Double(us) / 1_000_000.0
                    let p = duration > 0 ? min(0.98, doneSec / duration) : 0
                    onProgress(p, "正在压缩… \(Int(p * 100))%")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // ffmpeg 的 CLI main 是阻塞调用 → 丢后台线程（优先级跟转换那条保持一致）
        let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var argv = args.map { strdup($0) }
            let c = HookFFmpeg(Int32(args.count), &argv)
            for p in argv { free(p) }               // 必须释放（每次调用累积一份）
            return c
        }.value
        poller.cancel()
        onProgress(0.98, "正在收尾…")

        guard code == 0 else {
            try? fm.removeItem(at: outTmp)
            try? fm.removeItem(at: progressFile)
            throw Fail.ffmpegFailed(code)
        }

        // ── 体检（三条全过才算成功）──
        let outBytes = sizeOf(outTmp)
        let srcBytes = sizeOf(input)
        guard outBytes > 0 else {
            try? fm.removeItem(at: outTmp)
            try? fm.removeItem(at: progressFile)
            throw Fail.outputMissing
        }
        if srcBytes > 0 {
            let ratio = Double(outBytes) / Double(srcBytes)
            guard ratio < 0.95, ratio > 0.02 else {       // 真变小了；但没小到离谱
                try? fm.removeItem(at: outTmp)
                try? fm.removeItem(at: progressFile)
                throw Fail.didNotShrink
            }
        }
        let outTracks = (try? await AVURLAsset(url: outTmp).loadTracks(withMediaType: .video)) ?? []
        guard !outTracks.isEmpty else {
            try? fm.removeItem(at: outTmp)
            try? fm.removeItem(at: progressFile)
            throw Fail.noVideoTrack
        }

        // 原子改名：到这一步才让最终文件名出现
        do {
            try fm.moveItem(at: outTmp, to: outFinal)
        } catch {
            try? fm.removeItem(at: outTmp)
            throw Fail.outputMissing
        }
        try? fm.removeItem(at: progressFile)

        let saved = max(0, srcBytes - outBytes)
        onProgress(1, "压缩完成")
        return (outFinal, outBytes,
                "✔ 已压缩：\(mb(srcBytes))MB → \(mb(outBytes))MB（省了 \(mb(saved))MB）")
    }

    /// 文件字节数（读不到算 0）
    private static func sizeOf(_ url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }
}
