import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「压画质省空间」—— 把已下载的成品**重新编码**成更小的文件。
///
/// ══ ★ 和「转成 MP4」完全不是一回事（别混）══
///   · 转 MP4 = **换封装**（`-c copy`）：无损、秒级（实测 21 分钟的片子 9.5 秒）
///   · 压缩   = **重新编码**：有损、分钟级
///   所以它是工具箱里一个**独立**的功能，不是"转 MP4"的一个选项 —— 混在一起会误导预期。
///
/// ══ 档位与算账全在 `CompressPlan` 里（纯逻辑，能被离线回归集验）══
///   这个文件只负责"真的动手"：拼 ffmpeg 参数、盯进度、体检、收尾。
///
/// ══ 每个取舍的依据（都不是随手写的）══
///   · **走硬件编码器** `h264_videotoolbox`：实测内嵌 ffmpeg 的产物里有它（还有 `libx264` 兜底）。
///     硬件编码比软件快 5~10 倍，而且发热小得多 —— 这是"压缩"能不变成折磨的关键。
///   · **音频 `-c copy`**：源音频本来就已是有损编码，重编一次是白损音质、还省不了几十 KB；
///     顺带躲开"内置 aac 编码器是 experimental（要 `-strict -2`）"这个坑。
///   · ★★ **码率按源码率的比例算，不写死绝对值**：写死时遇到低码率片源等于"往上加码"，
///     真机上出现过"49.6MB 的片子预估能压到 122MB"。详见 `CompressPlan.Tier`。
///   · **`-maxrate` / `-bufsize`**：给码率加天花板，防复杂场景体积飙升。
///   · **进度走 `-progress <文件>`**：进程内跑 ffmpeg 拿不到它的 stdout，
///     所以让它把进度**写成文件**、我们在外面轮询（实测它会写 `out_time_us`、`speed`）。
///     `speed` 顺手算成"还要多久"给用户看。
///   · **先写 `.partial.mp4`、成功后原子改名**：中途失败/被杀不会留下一个"看着像成品"的坏文件。
///     ★ 后缀必须**以媒体后缀收尾**（`名字.partial.mp4`）—— `xxx.mp4.partial` 会让
///     ffmpeg 认不出输出格式，**秒退**（真机三档全秒失败那个事故）。
///   · **压完必须体检**：真的变小了（<95%）而且没小到离谱（>2%）、成品里有画面 ——
///     任意一条不过就当失败、删掉半成品。**这套体检是拿真事故换来的**：
///     以前"钥匙用错"时 ffmpeg 退出码照样是 0，只是内容少了 2/3。
///   · ★★ **读不到原片大小/时长 → 直接判失败**（v2 补的洞）：以前写的是
///     `if srcBytes > 0 { …体积比检查… }`，读不到就**整段静默跳过** ——
///     等于给"变大的成品"开了后门。现在连压都不压。
///   · **绝不自动删原片**：压缩不可逆，删不删由用户明确决定（这个文件不碰原片）。
enum Compressor {

    // MARK: - 失败原因（说人话）

    enum Fail: LocalizedError {
        case noInput
        case noVideoTrack
        case notAnImage
        case noSourceInfo
        case ffmpegFailed(Int32)
        case outputMissing
        case didNotShrink

        var errorDescription: String? {
            switch self {
            case .noInput:              "这个文件读不到（可能已经被删了）"
            case .noVideoTrack:         "这个文件里没有画面，压不了"
            case .notAnImage:           "这个文件不是图片，压不了"
            case .noSourceInfo:         "读不到原片的大小或时长，不敢下手压（怕压出个更占地方的成品）"
            case .ffmpegFailed(let c):  "压缩失败（ffmpeg 退出码 \(c)，0 才算成功）"
            case .outputMissing:        "压缩跑完了但没有产出文件"
            case .didNotShrink:         "压完没变小 —— 这个文件用这个档位不划算（已经是压过的图／低码率片很常见）。原片没动，半成品已删"
            }
        }
    }

    /// 界面上的体积（一位小数 MB）—— 统一走 CompressPlan，别在这里再写一份
    static func mb(_ bytes: Int64) -> String { CompressPlan.mb(bytes) }

    // MARK: - 跑一次视频压缩

    /// `onProgress` 的 progress 是 0~1（按 ffmpeg 报的已编码时长 ÷ 总时长算），
    /// 第二参是一句人话（百分比 + 用 `speed` 算出的剩余时间）。
    /// 返回：成品地址、字节数、一句人话的结果。
    static func run(input: URL, tier: CompressPlan.Tier,
                    onProgress: @escaping (Double, String) -> Void) async throws
        -> (url: URL, bytes: Int64, note: String) {

        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else { throw Fail.noInput }

        // ── 时长与**显示尺寸**：从素材里读 —— 算进度、算"要不要缩"都要用 ──
        let asset = AVURLAsset(url: input)
        let duration: Double
        let dispW: Int
        let dispH: Int
        do {
            duration = try await asset.load(.duration).seconds
            let vtracks = try await asset.loadTracks(withMediaType: .video)
            guard let first = vtracks.first else { throw Fail.noVideoTrack }
            // ★ 这两处**故意用同步读法**：`load(.naturalSize)` 这类异步属性加载在旧系统上
            //   不保证可用（我们的部署目标是 iOS 15），同步访问器一定有，最稳。
            let size = first.naturalSize
            let transform = first.preferredTransform
            // 竖屏片经常是"1920×1080 + 旋转 90°"存的 —— 要把 transform 算进去才是**显示**尺寸，
            // 也才是 ffmpeg 看到的样子（它默认自动旋转）。
            let disp = size.applying(transform)
            dispW = Int(abs(disp.width).rounded())
            dispH = Int(abs(disp.height).rounded())
        } catch let e as Fail {
            throw e
        } catch {
            throw Fail.noInput
        }

        // ── ★★ 算账：源码率 → 目标码率。读不到原片信息就**直接失败** ──
        //   （旧版这里跳过体检，是 v1.0.157 真机"122MB"事故之外另一个洞）
        let srcBytes = sizeOf(input)
        let bps = CompressPlan.targetVideoBps(
            tier: tier,
            sourceBps: CompressPlan.sourceBps(bytes: srcBytes, duration: duration))
        guard srcBytes > 0, bps > 0 else { throw Fail.noSourceInfo }

        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let outFinal = dir.appendingPathComponent(base + "_压缩.mp4")
        // ★★ 临时文件名**必须以媒体后缀结尾**（`partial` 放中间）。见文件头。
        let outTmp = dir.appendingPathComponent(base + "_压缩.partial.mp4")
        let progressFile = dir.appendingPathComponent(".compress_progress.txt")
        try? fm.removeItem(at: outTmp)
        try? fm.removeItem(at: outFinal)
        try? fm.removeItem(at: progressFile)

        var argList = ["-hide_banner", "-loglevel", "error", "-y",
                       "-i", input.path,
                       "-c:v", "h264_videotoolbox",
                       "-b:v", "\(bps)",
                       "-maxrate", "\(Int(Double(bps) * 1.5))",
                       "-bufsize", "\(bps * 2)"]
        // ★ 要缩就**自己算出确定的长宽**（不写 `-2` 让 ffmpeg 推）：
        //   短边口径对横屏/竖屏都对，而且尺寸是我们算的、能离线验（回归集里有考题）。
        if let f = CompressPlan.fit(width: dispW, height: dispH, shortSide: tier.shortSide) {
            argList += ["-vf", "scale=\(f.w):\(f.h)"]
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
                if let text = try? String(contentsOf: progressFile, encoding: .utf8) {
                    var doneSec = 0.0
                    var speed = 0.0
                    for line in text.split(separator: "\n") {
                        if line.hasPrefix("out_time_us="),
                           let us = Int64(line.dropFirst("out_time_us=".count)) {
                            // 早期会写 `out_time_us=N/A` → 解析失败 → 保持 0，不误报
                            doneSec = Double(us) / 1_000_000.0
                        } else if line.hasPrefix("speed=") {
                            // 形如 `speed=1.23x`；也会出现 `speed=N/A`（解析失败按 0）
                            speed = Double(line.dropFirst("speed=".count).dropLast()) ?? 0
                        }
                    }
                    let p = duration > 0 ? min(0.98, max(0, doneSec / duration)) : 0
                    var msg = "正在压缩… \(Int(p * 100))%"
                    if let eta = CompressPlan.etaText(doneSec: doneSec,
                                                      totalSec: duration, speed: speed) {
                        msg += " · 还要 \(eta)"
                    }
                    onProgress(p, msg)
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
        guard outBytes > 0 else {
            try? fm.removeItem(at: outTmp)
            try? fm.removeItem(at: progressFile)
            throw Fail.outputMissing
        }
        // ★ 源码率在函数开头已经 guard 过了 —— 这里 ratio 的分母**必然可用**，
        //   不再有"读不到就静默跳过体检"这种后门。
        let ratio = Double(outBytes) / Double(srcBytes)
        guard ratio < 0.95, ratio > 0.02 else {       // 真变小了；但没小到离谱
            try? fm.removeItem(at: outTmp)
            try? fm.removeItem(at: progressFile)
            throw Fail.didNotShrink
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

    // MARK: - 跑一次图片压缩（按质量重压 JPEG）

    /// 用系统自带的 ImageIO 重压 —— **不碰 ffmpeg**（图片这点活儿用不着它，
    /// 少了进程、少了失败面，也快得多）。
    ///
    /// 为什么要 `CGImageDestinationAddImageFromSource` 而不是"UIImage → jpegData"：
    ///   ① UIImage 那条路要把图**整张解码再重画**，EXIF 里的**方向**会丢 ——
    ///      相册里竖着拍的照片重压完可能躺倒，还得自己补 transform；
    ///   ② 从 source 直接写出去，方向、拍摄参数、色彩信息都原样留着；
    ///   ③ HEIC / PNG / TIFF / WebP 全都能进，统一输出 `.jpg`。
    /// ★ 代价（如实标出来）：透明通道会丢（JPEG 没有 alpha），并且
    ///   **已经是压过一遍的 JPEG 可能反而更大** —— 那种由体积体检拦下（判失败、删半成品）。
    /// ★ 写成 async（不是为等什么，而是为了**离开主线程**）：非隔离的 async 函数
    ///   在 SE-0338 之后跑在通用线程池上，重压一张大图不会卡住界面。
    static func runPhoto(input: URL, tier: CompressPlan.PhotoTier,
                         onProgress: @escaping (Double, String) -> Void) async throws
        -> (url: URL, bytes: Int64, note: String) {

        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else { throw Fail.noInput }
        let srcBytes = sizeOf(input)
        guard srcBytes > 0 else { throw Fail.noSourceInfo }
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { throw Fail.notAnImage }

        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let outFinal = dir.appendingPathComponent(base + "_压缩.jpg")
        // 临时名同样**以媒体后缀收尾**（规矩跟视频那条一致，别两套写法）
        let outTmp = dir.appendingPathComponent(base + "_压缩.partial.jpg")
        try? fm.removeItem(at: outTmp)
        try? fm.removeItem(at: outFinal)

        onProgress(0.3, "正在重压…")
        guard let dest = CGImageDestinationCreateWithURL(
            outTmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Fail.outputMissing }
        let opts = [kCGImageDestinationLossyCompressionQuality: tier.quality] as CFDictionary
        CGImageDestinationAddImageFromSource(dest, src, 0, opts)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: outTmp)
            throw Fail.outputMissing
        }

        let outBytes = sizeOf(outTmp)
        guard outBytes > 0 else {
            try? fm.removeItem(at: outTmp)
            throw Fail.outputMissing
        }
        // 体检：跟视频同一套判据（真变小了、又没小到离谱）
        let ratio = Double(outBytes) / Double(srcBytes)
        guard ratio < 0.95, ratio > 0.02 else {
            try? fm.removeItem(at: outTmp)
            throw Fail.didNotShrink
        }

        do {
            try fm.moveItem(at: outTmp, to: outFinal)
        } catch {
            try? fm.removeItem(at: outTmp)
            throw Fail.outputMissing
        }

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
