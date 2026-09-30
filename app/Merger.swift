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
        /// 全部段的参数真的完全一样（这种情况直接搬，零损失、秒级）
        var allSame: Bool
        /// 声音参数全一致（一致就原样搬，不重编码）
        var audioSame: Bool
        /// 各段分辨率是否**已经等于目标**（是的话就不用挂缩放滤镜 —— 缩放是 CPU 大头）
        var needScale: Bool
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

        // 全部段参数**真的一模一样**才走"直接搬"那条路
        // （判据是 SPS/PPS 字节 + 尺寸 + 帧率 —— "跳过个别段"那套已经彻底删掉了：
        //   它会把"duration 不准的原始段"塞进拼接，正是时长暴涨的根源）
        let allSame = infos.allSatisfy { i in
            var sameFps = true
            if i.fps > 0, target.fps > 0 { sameFps = abs(i.fps - target.fps) < 0.5 }
            return i.width == tW && i.height == tH && i.paramKey == target.paramKey && sameFps
        }

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
                     allSame: allSame, audioSame: audioSame,
                     needScale: !infos.allSatisfy { $0.width == tW && $0.height == tH })
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

        var argList: [String] = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-sn", "-dn",
            "-c", "copy",
        ]
        // 大文件不加 +faststart（那是两遍 I/O，见 FFmpegConverter 的说明）
        if totalBytes < FFmpegConverter.faststartLimit {
            argList += ["-movflags", "+faststart"]
        }
        argList.append(output.path)

        // ★★ 必须先绑成 let 再进下面的并发闭包。把 var 直接捕获进 Task.detached 会编译不过：
        //   reference to captured var - 本工程踩过 4 次（#138/#164/#171同类/#178），
        //   所以自检里有一条「源码里不许出现 var args」的断言。
        let args = argList

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

    /// ★★★ 参数不一样时走这条：**一条命令**边读边转边接（不再产生中间文件、不再"拼接"）。
    ///
    /// ══ 为什么改掉"逐段转 + 拼接"（2026-09-30 用户实测踩出来的）══
    ///
    /// ffmpeg 的 concat **是用"前一个文件的 duration"去偏移下一段的时间戳**的
    /// （官方文档：duration 不准就会出问题）。而手机上下载来的段是 **HLS 产物**，
    /// **容器里记的 duration 未必等于真实时长** —— 拿它当偏移量，
    /// **它之后所有段的时间戳会整体错位** → 用户实测到的
    /// 「22 分钟的素材显示成 1 小时 25 分 + 中段卡死 + 后半慢放」。
    /// （之前那条"参数达标就跳过、原封不动直接用"的优化，正是把这个脏段塞进了拼接。
    ///   它现在**已彻底去掉**。）
    ///
    /// 这条命令里，每一段都被**解码 → 按输出端重新计时 → 重新编码** ——
    /// 输入的脏时间戳 / 错 duration 全被清洗，**从根上不再依赖任何输入段的 duration**。
    ///
    /// 代价：没有中间文件可复用，中途失败要整条重来（单人自用可接受）。
    ///
    /// ══ 画质优先（用户最在意）══
    ///   · 画布取**面积最大**那一档 → 只放大、不缩小；
    ///   · 码率取**源里最高**的；
    ///   · 源分辨率**已经等于目标时，不挂缩放滤镜**（省 CPU、降温）。
    static func mergeByReencoding(_ sources: [Source], output: URL,
                                  onProgress: @escaping (Double, String) -> Void) async throws {
        guard sources.count >= 2 else { throw Fail.tooFew }
        let check = try await inspect(sources)
        let n = sources.count

        // ① 视频编码不同（H.264 混 H.265）：concat 带不动（同一条流不能混编码）
        //    → 只把**少数派**先转成多数派的编码，其余原样交给下面那条命令。
        var pieces: [URL] = sources.map { $0.url }
        var tmps: [URL] = []
        defer { for t in tmps { try? FileManager.default.removeItem(at: t) } }

        let byCodec = Dictionary(grouping: check.infos, by: { $0.videoCodec })
        if byCodec.count > 1 {
            let main = byCodec.max { $0.value.count < $1.value.count }?.key ?? "H.264"
            for (i, info) in check.infos.enumerated() where info.videoCodec != main {
                onProgress(Double(i) / Double(n + 1), "正在统一编码（第 \(i + 1)/\(n) 条）…")
                let tmp = JobStore.file(named: "mergetmp_\(UUID().uuidString.prefix(8)).mp4")
                try? FileManager.default.removeItem(at: tmp)
                try await transcodeToH264(from: sources[i].url, to: tmp, check: check)
                tmps.append(tmp)
                pieces[i] = tmp
            }
        }

        // ② 一条命令：concat demuxer 喂进来 → 统一画布/帧率 → 硬件编码 → 输出
        let listURL = output.deletingLastPathComponent()
            .appendingPathComponent("merge_\(UUID().uuidString.prefix(8)).txt")
        let body = pieces.map { "file \(concatQuoted($0.path))" }.joined(separator: "\n") + "\n"
        guard (try? body.write(to: listURL, atomically: true, encoding: .utf8)) != nil else {
            throw Fail.ffmpegFailed(-1)
        }
        defer { try? FileManager.default.removeItem(at: listURL) }

        var argList: [String] = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-sn", "-dn",
        ]
        if check.needScale {
            argList += ["-vf", "scale=\(check.targetW):\(check.targetH):"
                        + "force_original_aspect_ratio=decrease,"
                        + "pad=\(check.targetW):\(check.targetH):(ow-iw)/2:(oh-ih)/2,setsar=1,"
                        + "format=yuv420p"]
        } else {
            argList += ["-vf", "format=yuv420p"]        // 尺寸本来就对，只统一像素格式
        }
        argList += [
            "-r", check.targetFps,
            "-c:v", "h264_videotoolbox",                 // 硬件编码
            "-b:v", "\(check.targetBps)",
            "-maxrate", "\(Int(Double(check.targetBps) * 1.5))",
            "-bufsize", "\(check.targetBps * 2)",
            "-pix_fmt", "yuv420p",
            "-g", "60",
        ]
        if check.audioSame {
            argList += ["-c:a", "copy"]                  // 音频本来就一致 → 原样搬
        } else {
            // ★★ 2026-09-30 实测后把 `-af aresample=async=1` 删掉了：
            //   它是“预防性”加的（防音频时间戳跳动），但会在时间戳只是“不准”时**往里塞静音** →
            //   音频被拉长 → **声音越走越晚、跟画面对不上**（用户实测报的）。
            //   ★ 教训：**只修确实看到的症状，不做预防性加固** ——
            //     上一个被删的 `-fflags +genpts` 是同一个毛病。
            argList += ["-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2"]
        }
        argList.append(output.path)

        // ★ 必须先 let 再进并发闭包（本工程踩过 4 次的老坑，自检里有断言盯着）
        let args = argList
        onProgress(0.02, "正在合并…")

        let outURL = output
        let poller = Task {
            while !Task.isCancelled {
                let sz = Self.bytes(of: outURL)
                if check.totalBytes > 0, sz > 0 {
                    let p = min(0.97, Double(sz) / Double(check.totalBytes))
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

    /// 把**单条**素材转成 H.264（只在"编码混合"时用 —— 让少数派能跟多数派进同一条 concat 流）
    private static func transcodeToH264(from src: URL, to dst: URL, check: Check) async throws {
        var argList: [String] = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", src.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-sn", "-dn",
            "-c:v", "h264_videotoolbox",
            "-b:v", "\(check.targetBps)",
            "-pix_fmt", "yuv420p",
        ]
        argList += check.audioSame ? ["-c:a", "copy"]
                                   : ["-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2"]
        argList.append(dst.path)
        let args = argList
        let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var argv = args.map { strdup($0) }
            let c = HookFFmpeg(Int32(args.count), &argv)
            for p in argv { free(p) }
            return c
        }.value
        guard code == 0, JobStore.size(of: dst.lastPathComponent) > 0 else {
            throw Fail.ffmpegFailed(code)
        }
    }

    /// ffmpeg concat 列表里的路径：**整条用单引号包住，内部单引号写成 `'\''`**。
    /// （标题里带引号/空格/中文很常见，不转义就会拼出一个读不了的文件。）
    static func concatQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
