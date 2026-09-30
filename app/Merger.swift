import AVFoundation
import CoreMedia
import Foundation

/// 把几条视频**合并成一条**（整部剧连着看、规格乱七八糟混着合都行）。
///
/// ══ 两条路 ══
///
/// · **直接搬**（`-c copy`）：各段参数**真的一模一样**时，一个像素都不动 —— 秒级、零损失。
/// · **重新编码**：参数不一样时躲不掉（要改画面尺寸），但**损失可以做到最小**。
///
/// ★★ **画质优先是硬要求**（用户 2026-09-30 原话「画质降低特别特别特别在意」）。三条原则：
///
///   1. **只放大、不缩小** —— 画布取"**面积最大**的那一档"。
///      缩小时信息**真的没了**；放大只是变虚、不丢信息。所以谁都不该被缩小。
///   2. **能不重编码就不重编码** —— 以前是**每一段都被压一遍**，这是白丢画质。
///      参数跟目标真一样的段**直接搬**（零损失），只转不一样的。
///   3. **码率取源里最高的**（不是平均）—— 平均会把高码率那几段压过头。
///
/// ══ 怎么判"参数真的一样" ══
///
/// **不能只看分辨率** —— 那是表面。H.264 真正决定"能不能直接拼"的是 **SPS/PPS 参数集那串字节**
/// （MP4 里只有一份，拼接时不会更新 → 不一样就"画面卡住、声音继续"，用户实测踩过）。
/// 所以用 `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 把那串字节取出来**逐字节比对**；
/// 不是 H.264 的（H.265 等）退回"编码名 + 宽高"当指纹 —— 保守，但**宁可多转一段也不漏判**。
///
/// ══ 参数怎么探 ══
///
/// 用 `AVURLAsset`，**不用 ffprobe** —— ffmpeg/ffprobe 在进程内跑，**拿不到它们的 stdout**。
enum Merger {

    /// 一条待合并的输入
    struct Source {
        let url: URL
        let title: String
    }

    /// 探到的一条素材信息
    struct Info {
        var width: Int
        var height: Int
        var videoCodec: String
        var audioChannels: Int
        var audioSampleRate: Int
        var seconds: Double
        var bytes: Int64
        var fps: Double
        /// ★ "能不能直接拼"的真指纹：H.264 用 **SPS/PPS 的字节**；其他编码退回"编码名+宽高"
        var paramKey: String

        /// 给人看的规格串 —— 提示里要**逐条列出来**（只说"规格不一样"等于没说）
        var describe: String {
            "\(width)×\(height) · \(videoCodec) · \(audioChannels) 声道"
        }

        var pixels: Int { width * height }
    }

    enum Fail: LocalizedError {
        case tooFew
        case unreadable(String)
        case mismatched(String)      // 参数有差异 —— 带回差异文本，让调用方决定
        case codecMix(String)        // 视频编码不同 —— 直接拼必然出问题
        case ffmpegFailed(Int32)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .tooFew:
                return "至少要选两条才能合并"
            case .unreadable(let n):
                return "读不出「\(n)」的画面信息，这条可能坏了"
            case .mismatched(let d):
                return d
            case .codecMix(let d):
                return d
            case .ffmpegFailed(let c):
                return "合并失败（ffmpeg 退出码 \(c)）"
            case .emptyOutput:
                return "合并完没生成文件，可能这几条的格式对不上"
            }
        }
    }

    // MARK: - 探测

    static func probe(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks) else { return nil }
        guard let v = tracks.first(where: { $0.mediaType == .video }) else { return nil }

        let size = (try? await v.load(.naturalSize)) ?? .zero
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        var codec = "?"
        var key = ""
        if let descs = try? await v.load(.formatDescriptions), let d = descs.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(d))
            key = parameterKey(d, codec: codec, w: w, h: h)
        }
        var channels = 0, rate = 0
        if let a = tracks.first(where: { $0.mediaType == .audio }),
           let descs = try? await a.load(.formatDescriptions), let d = descs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            rate = Int(asbd.pointee.mSampleRate)
        }
        let fps = Double((try? await v.load(.nominalFrameRate)) ?? 0)
        let sec = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let n = Self.bytes(of: url)

        return Info(width: w, height: h, videoCodec: codec,
                    audioChannels: channels, audioSampleRate: rate,
                    seconds: sec.isFinite ? sec : 0, bytes: n,
                    fps: fps.isFinite ? fps : 0,
                    paramKey: key)
    }

    /// ★★ "能不能直接拼"的真指纹。H.264 取 **SPS/PPS 的字节**；其他编码退回"编码名 + 宽高"。
    private static func parameterKey(_ d: CMFormatDescription, codec: String,
                                     w: Int, h: Int) -> String {
        guard codec == "H.264" else { return "\(codec)-\(w)x\(h)" }
        var out = ""
        for i in 0..<2 {                       // 0 = SPS，1 = PPS
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                d, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let p = ptr, size > 0 else { continue }
            out += Data(bytes: p, count: size).base64EncodedString()
        }
        return out.isEmpty ? "\(codec)-\(w)x\(h)" : out
    }

    private static func fourCC(_ c: FourCharCode) -> String {
        let bytes = [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF),
                     UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii) ?? "?"
        switch s {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "H.265"
        case "mp4v": return "MPEG-4"
        case "vp09": return "VP9"
        case "av01": return "AV1"
        default: return s.trimmingCharacters(in: .whitespaces)
        }
    }

    /// 文件字节数（拿不到算 0）—— 写法照抄项目里的 `Compressor.size`
    private static func bytes(of url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }

    // MARK: - 体检

    struct Check {
        var infos: [Info]
        var fatal: String?
        var warnings: [String]
        var report: String
        var totalBytes: Int64
        var totalSec: Double
        /// 目标画布（★ 取"面积最大那一档" —— 只放大、不缩小）
        var targetW: Int
        var targetH: Int
        var targetFps: String
        var targetBps: Int
        /// 每一段单独看：**要不要重编码**（跟目标真一致的段不用 —— 那是零损失）
        var needTranscode: [Bool]
        /// 全部段的参数真的完全一样（这种情况直接搬，零损失、秒级）
        var allSame: Bool
        /// 声音参数全一致（一致就原样搬，不重编码）
        var audioSame: Bool
    }

    static func inspect(_ sources: [Source]) async throws -> Check {
        var infos: [Info] = []
        for s in sources {
            guard let i = await probe(s.url) else { throw Fail.unreadable(s.title) }
            infos.append(i)
        }

        let codecs = Set(infos.map { $0.videoCodec })
        var fatal: String? = nil
        if codecs.count > 1 {
            fatal = "这几条的视频编码不一样（\(codecs.sorted().joined(separator: " / "))），"
                + "直接拼必然出问题 —— 需要走「重新编码后合并」。"
        }

        // ★★ 目标画布 = **面积最大的那一档**（画质优先：谁都不被缩小）
        guard let target = infos.max(by: { $0.pixels < $1.pixels }) else {
            throw Fail.unreadable(sources[0].title)
        }
        let tW = max(2, target.width - (target.width % 2))
        let tH = max(2, target.height - (target.height % 2))
        let tFps = String(format: "%.3f",
                          min(60, max(12, infos.map { $0.fps }.filter { $0 > 0 }.max() ?? 30)))
        // ★ 码率取源里**最高**的（不是平均）—— 平均会把高码率那几段压过头
        let bpsList = infos.compactMap { i -> Double? in
            guard i.seconds > 0.5, i.bytes > 0 else { return nil }
            return Double(i.bytes) * 8.0 / i.seconds
        }
        let tBps = Int(min(max(bpsList.max() ?? 2_000_000, 800_000), 12_000_000))

        // 声音参数是否全一致（一致就 `-c:a copy`，不重编码）
        let audioSame = Set(infos.map { "\($0.audioChannels)/\($0.audioSampleRate)" }).count == 1
            && infos.allSatisfy { $0.audioChannels > 0 }

        // 每段要不要转：**跟目标"真一样"才跳过**（尺寸 + SPS/PPS 指纹 + 帧率）
        let need: [Bool] = infos.map { i in
            var sameFps = true
            if i.fps > 0, target.fps > 0 { sameFps = abs(i.fps - target.fps) < 0.5 }
            return !(i.width == tW && i.height == tH && i.paramKey == target.paramKey && sameFps)
        }
        let allSame = !need.contains(true)

        var warnings: [String] = []
        if !allSame {
            let sizes = Set(infos.map { "\($0.width)×\($0.height)" })
            if sizes.count > 1 {
                warnings.append("· 画面尺寸不一样：\(sizes.sorted().joined(separator: " / "))\n"
                    + "  会统一到最大的一档（\(tW)×\(tH)）—— 小的被放大，**不会被缩小**。")
            }
            if Set(infos.map { $0.audioChannels }).count > 1 {
                warnings.append("· 声道数不一样："
                    + Set(infos.map { "\($0.audioChannels)" }).sorted().joined(separator: " / ") + " 声道")
            }
        }

        let lines = zip(sources, infos).map { "· \($0.title)：\($1.describe)" }
        let report = (warnings + ["", "各条的规格："] + lines).joined(separator: "\n")

        return Check(infos: infos, fatal: fatal, warnings: warnings, report: report,
                     totalBytes: infos.reduce(Int64(0)) { $0 + $1.bytes },
                     totalSec: infos.reduce(0.0) { $0 + $1.seconds },
                     targetW: tW, targetH: tH, targetFps: tFps, targetBps: tBps,
                     needTranscode: need, allSame: allSame, audioSame: audioSame)
    }

    // MARK: - 直接搬（零损失）

    /// 各段参数真一致时走这条：只搬运、不重编码 —— 秒级、**画质一个像素都不动**。
    /// - Parameter force: 参数有差异时是否照拼（界面问过他之后才传 true）
    static func merge(_ sources: [Source], output: URL, force: Bool = false,
                      onProgress: @escaping (Double, String) -> Void) async throws {
        guard sources.count >= 2 else { throw Fail.tooFew }
        let check = try await inspect(sources)
        if let bad = check.fatal, !force { throw Fail.codecMix(bad) }
        if !check.warnings.isEmpty, !force { throw Fail.mismatched(check.report) }
        try await concatCopy(sources.map { $0.url }, output: output,
                             totalBytes: check.totalBytes, onProgress: onProgress)
    }

    /// 只搬运的拼接（两条路最后都走它）。
    /// ★ `-fflags +genpts`：防拼接处时间戳不连续。
    private static func concatCopy(_ urls: [URL], output: URL, totalBytes: Int64,
                                   onProgress: @escaping (Double, String) -> Void) async throws {
        let listURL = output.deletingLastPathComponent()
            .appendingPathComponent("merge_\(UUID().uuidString.prefix(8)).txt")
        let body = urls.map { "file \(concatQuoted($0.path))" }.joined(separator: "\n") + "\n"
        guard (try? body.write(to: listURL, atomically: true, encoding: .utf8)) != nil else {
            throw Fail.ffmpegFailed(-1)
        }
        defer { try? FileManager.default.removeItem(at: listURL) }

        var args: [String] = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-fflags", "+genpts",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-sn", "-dn",
            "-c", "copy",
        ]
        // 大文件不加 +faststart（那是两遍 I/O，见 FFmpegConverter 的说明）
        if totalBytes < FFmpegConverter.faststartLimit {
            args += ["-movflags", "+faststart"]
        }
        args.append(output.path)

        onProgress(0.02, "正在合并…")
        let outURL = output
        let poller = Task {
            while !Task.isCancelled {
                let n = Self.bytes(of: outURL)
                if totalBytes > 0, n > 0 {
                    let p = min(0.97, Double(n) / Double(totalBytes))
                    onProgress(p, "正在合并… \(Int(p * 100))%")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var argv = args.map { strdup($0) }
            let c = HookFFmpeg(Int32(args.count), &argv)
            for p in argv { free(p) }
            return c
        }.value
        poller.cancel()

        guard code == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Fail.ffmpegFailed(code)
        }
        guard Self.bytes(of: output) > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Fail.emptyOutput
        }
        onProgress(1.0, "合并完成")
    }

    // MARK: - 重新编码（参数不一样时的路，画质损失做到最小）

    /// ★★ 两条保画质的动作都在这里：
    ///   1. **能跳过的跳过** —— 参数跟目标真一样的段**直接搬**（零损失），只转不一样的；
    ///   2. **只放大不缩小** —— 目标画布是"面积最大那一档"。
    static func mergeByReencoding(_ sources: [Source], output: URL,
                                  onProgress: @escaping (Double, String) -> Void) async throws {
        guard sources.count >= 2 else { throw Fail.tooFew }
        let check = try await inspect(sources)
        let n = sources.count

        var pieces: [URL] = []
        var tmps: [URL] = []
        defer { for t in tmps { try? FileManager.default.removeItem(at: t) } }   // 中间文件用完必删

        for (i, s) in sources.enumerated() {
            if !check.needTranscode[i] {
                pieces.append(s.url)          // ★ 达标 → 原文件直接进列表，零损失
                continue
            }
            onProgress(Double(i) / Double(n + 1), "正在重编码第 \(i + 1)/\(n) 集…")
            let tmp = JobStore.file(named: "mergetmp_\(UUID().uuidString.prefix(8)).mp4")
            try? FileManager.default.removeItem(at: tmp)

            // 缩放 + 补黑边到目标画布（像素宽高比也统一）
            let vf = "scale=\(check.targetW):\(check.targetH):force_original_aspect_ratio=decrease,"
                + "pad=\(check.targetW):\(check.targetH):(ow-iw)/2:(oh-ih)/2,setsar=1"
            var args: [String] = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", s.url.path,
                "-map", "0:v:0", "-map", "0:a:0?",
                "-sn", "-dn",
                "-vf", vf,
                "-r", check.targetFps,
                // ★ 硬件编码（软件编码在手机上太慢）；它不认 -crf，只认 -b:v
                "-c:v", "h264_videotoolbox",
                "-b:v", "\(check.targetBps)",
                "-maxrate", "\(Int(Double(check.targetBps) * 1.5))",
                "-bufsize", "\(check.targetBps * 2)",
                "-pix_fmt", "yuv420p",
                "-g", "60",
            ]
            // 声音参数全一致时**原样搬**（省一遍编码，也不动音质）
            if check.audioSame {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2"]
            }
            args.append(tmp.path)

            let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
                var argv = args.map { strdup($0) }
                let c = HookFFmpeg(Int32(args.count), &argv)
                for p in argv { free(p) }
                return c
            }.value
            guard code == 0, JobStore.size(of: tmp.lastPathComponent) > 0 else {
                throw Fail.ffmpegFailed(code)
            }
            tmps.append(tmp)
            pieces.append(tmp)
        }

        let skipped = check.needTranscode.filter { !$0 }.count
        onProgress(Double(n) / Double(n + 1),
                   skipped > 0 ? "正在拼接（\(skipped) 条免重编码）…" : "正在拼接…")
        try await concatCopy(pieces, output: output, totalBytes: check.totalBytes) { p, msg in
            onProgress(Double(n) / Double(n + 1) + p / Double(n + 1), msg)
        }
    }

    /// ffmpeg concat 列表里的路径：**整条用单引号包住，内部单引号写成 `'\''`**。
    /// （标题里带引号/空格/中文很常见，不转义就会拼出一个读不了的文件。）
    static func concatQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
