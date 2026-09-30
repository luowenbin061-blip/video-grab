import AVFoundation
import Foundation

/// 把几条已下载的成品**合并成一条**（整部剧一次看完）。
///
/// ══ 为什么不重新编码 ══
///
/// 同一部剧的各集通常同源、同参数，`-c copy` 只搬数据、不重编码 ——
/// 12 集几十秒就能合完，画质零损失。这条路跟 `FFmpegConverter` 的"换封装"是同一个套路
/// （那边已经在真机上跑了很久，`HookFFmpeg` 的调用姿势直接照抄）。
///
/// ★★ **合并前必须先查各集参数是否一致**：不一致时 `-c copy` **不会报错**，
///   而是产出花屏 / 音画不同步的坏文件 —— 那种坏法比失败更糟（用户以为成功了）。
///   所以这里先探一遍（分辨率 / 视频编码 / 采样率），不一致就**拒绝**并说明原因。
///
/// ══ 参数怎么探 ══
///
/// 用 `AVURLAsset`，**不用 ffprobe** —— ffmpeg/ffprobe 在进程内跑，
/// **拿不到它们的 stdout**（`Compressor` 里为了拿进度都得写 `-progress <文件>`）。
/// 而 AVFoundation 是现成的、纯 Swift 的，拿分辨率/编码/时长足够了。
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
        var seconds: Double
        var bytes: Int64

        /// 判"能不能直接拼"的指纹 —— ★ 只认**分辨率 + 视频编码**。
        ///   声道数**不算**：ffmpeg 照搬每条流，它不影响能不能拼；
        ///   算进去只会把本来能合的片子挡在门外（2026-09-30 实测踩到）。
        var fingerprint: String { "\(width)x\(height)/\(videoCodec)" }

        /// 给人看的规格串 —— 合并前的提示要**逐条列出来**（只说"规格不一样"等于没说）
        var describe: String { "\(width)×\(height) · \(videoCodec) · \(audioChannels) 声道" }
    }

    enum Fail: LocalizedError {
        case tooFew
        case unreadable(String)
        case mismatched(String)      // 规格有差异 —— 带回差异文本，让调用方决定要不要强合
        case codecMix(String)        // 视频编码不同 —— 真的不能合（会花屏）
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

    /// 读一条素材的分辨率 / 编码 / 声道 / 时长 / 字节数。
    /// 拿不到视轨就返回 nil（说明这条不是能拼的视频）。
    static func probe(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks) else { return nil }
        guard let v = tracks.first(where: { $0.mediaType == .video }) else { return nil }

        let size = (try? await v.load(.naturalSize)) ?? .zero
        var codec = "?"
        if let descs = try? await v.load(.formatDescriptions), let d = descs.first {
            let sub = CMFormatDescriptionGetMediaSubType(d)
            codec = fourCC(sub)
        }
        var channels = 0
        if let a = tracks.first(where: { $0.mediaType == .audio }) {
            if let descs = try? await a.load(.formatDescriptions), let d = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        let sec = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let bytes = Self.bytes(of: url)

        return Info(width: Int(abs(size.width)), height: Int(abs(size.height)),
                    videoCodec: codec, audioChannels: channels,
                    seconds: sec.isFinite ? sec : 0, bytes: bytes)
    }

    /// 文件字节数（拿不到算 0）—— 写法照抄项目里的 `Compressor.size`：
    /// `(try? …)?[.size]`（`try?` 只包住那次调用），别写成 `try? (…[.size])`。
    private static func bytes(of url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }

    /// 四条字符的编码标识 → 可读名（认不出就原样返回，别假装认识）
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

    // MARK: - 合并

    /// 合并前的体检结果
    struct Check {
        var infos: [Info]
        var fatal: String?          // 不能合（编码不同）
        var warnings: [String]      // 能合但有代价
        var report: String          // 给人看的：差异 + 逐条规格
        var totalBytes: Int64
        var totalSec: Double
    }

    /// 体检一次。
    ///
    /// ★★ 为什么改成"先体检、再由调用方决定"（2026-09-30 用户实测后）：
    ///   原来一发现规格不同就**直接拒绝** —— 结果**同一部剧下的几集也被拒**。
    ///   而那几集往往只差分辨率或声道（源站各集清晰度不一样很常见），
    ///   `-c copy` 拼起来**通常照样能播**。一律拒绝 = 把功能废掉。
    ///   现在分两层：
    ///     · **视频编码不同**（H.264 混 H.265）→ 真的不能合，拦住；
    ///     · **只差分辨率 / 声道** → 能合，但把差异**逐条列出来**让他自己定。
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
                + "合出来会是花屏 —— 建议分开合。"
        }

        var warnings: [String] = []
        let sizes = Set(infos.map { "\($0.width)×\($0.height)" })
        if sizes.count > 1 {
            warnings.append("· 分辨率不一样：\(sizes.sorted().joined(separator: " / "))\n"
                + "  切换处可能黑一下、画面比例会变，但通常能看。")
        }
        let chans = Set(infos.map { "\($0.audioChannels)" })
        if chans.count > 1 {
            warnings.append("· 声道数不一样：\(chans.sorted().map { "\($0)" }.joined(separator: " / ")) 声道"
                + "（一般不影响）")
        }

        let lines = zip(sources, infos).map { "· \($0.title)：\($1.describe)" }
        let report = (warnings + ["" , "各条的规格："] + lines).joined(separator: "\n")

        return Check(infos: infos, fatal: fatal, warnings: warnings, report: report,
                     totalBytes: infos.reduce(Int64(0)) { $0 + $1.bytes },
                     totalSec: infos.reduce(0.0) { $0 + $1.seconds })
    }

    /// **重新编码后合并** —— 规格真的对不上时（尤其编码不同）唯一的出路。
    ///
    /// ★ 为什么不是「一条命令 concat filter 全搞定」：十几集一起走 `-filter_complex concat`，
    ///   命令行会长到离谱、内存也顶不住。这里改成**逐集先转成统一规格、再走一遍 concat copy**：
    ///   每一步都简单、能报进度，最后那步仍然只是"搬运"。
    ///
    /// 代价（必须让他知道，不能默默变慢）：**慢**（每集都要重编码）、**画质会掉一点**、
    /// 中间文件会临时占地方（收尾自动删）。
    static func mergeByReencoding(_ sources: [Source], output: URL,
                                  onProgress: @escaping (Double, String) -> Void) async throws {
        guard sources.count >= 2 else { throw Fail.tooFew }
        let check = try await inspect(sources)

        // 统一到"最窄的那一档" —— 不放大：放大只费时间、不长信息
        let widths = check.infos.map { $0.width }.filter { $0 > 0 }
        guard let narrow = widths.min() else { throw Fail.unreadable(sources[0].title) }
        let targetW = max(2, narrow - (narrow % 2))      // h264 要求偶数

        let fm = FileManager.default
        var tmps: [URL] = []
        defer { for t in tmps { try? fm.removeItem(at: t) } }   // 中间文件用完必删

        let n = sources.count
        for (i, s) in sources.enumerated() {
            onProgress(Double(i) / Double(n + 1), "正在重编码第 \(i + 1)/\(n) 集…")
            let tmp = JobStore.file(named: "mergetmp_\(UUID().uuidString.prefix(8)).mp4")
            try? fm.removeItem(at: tmp)

            // ★ 这里的参数是"统一"的目的地：同编码 / 同宽 / 同像素格式 / 同音频参数，
            //   转完之后它们才真的能走 concat copy。
            let args: [String] = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", s.url.path,
                "-map", "0:v:0", "-map", "0:a:0?",
                "-sn", "-dn",
                "-vf", "scale=\(targetW):-2",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2",
                "-movflags", "+faststart",
                tmp.path,
            ]
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
        }

        // 转完就都是同一规格了 → 复用"只搬运"那条路拼起来（force 因为指纹里还带着原分辨率）
        let converted = tmps.map { Source(url: $0, title: $0.lastPathComponent) }
        onProgress(Double(n) / Double(n + 1), "正在拼接…")
        try await merge(converted, output: output, force: true) { p, msg in
            // 逐集那 0…n/(n+1) 已经报过了，这里把最后一段摊进去
            onProgress(Double(n) / Double(n + 1) + p / Double(n + 1), msg)
        }
    }

    /// 合并成一条 MP4。
    /// - Parameter force: 规格有差异时是否照合（差异只到"分辨率/声道"这一层才用得上；
    ///   视频编码不同一律拦）。
    /// - Parameter onProgress: (0…1, 人话)。进度靠**输出文件大小 ÷ 输入总大小**算 ——
    ///   `-c copy` 的输出大小≈输入之和，所以这个比值站得住，且每 500ms 只读一次文件属性，不碰 ffmpeg。
    static func merge(_ sources: [Source], output: URL, force: Bool = false,
                      onProgress: @escaping (Double, String) -> Void) async throws {
        guard sources.count >= 2 else { throw Fail.tooFew }

        // ① 先体检 —— 判定和合本身分开，界面才能"先问过他再合"
        let check = try await inspect(sources)
        if let bad = check.fatal { throw Fail.codecMix(bad) }
        if !check.warnings.isEmpty, !force { throw Fail.mismatched(check.report) }

        let totalBytes = check.totalBytes
        let totalSec = check.totalSec

        // ② concat 列表文件（ffmpeg 的 concat demuxer 格式）
        let listURL = output.deletingLastPathComponent()
            .appendingPathComponent("merge_\(UUID().uuidString.prefix(8)).txt")
        let listBody = sources.map { "file \(concatQuoted($0.url.path))" }.joined(separator: "\n") + "\n"
        guard (try? listBody.write(to: listURL, atomically: true, encoding: .utf8)) != nil else {
            throw Fail.ffmpegFailed(-1)
        }
        defer { try? FileManager.default.removeItem(at: listURL) }

        // ③ 起 ffmpeg（姿势照抄 `FFmpegConverter`）
        var argList: [String] = [
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-sn", "-dn",
            "-c", "copy",                    // 只搬运，不重编码
        ]
        // 大文件不加 +faststart（那是两遍 I/O，见 FFmpegConverter 的说明）
        if totalBytes < FFmpegConverter.faststartLimit {
            argList += ["-movflags", "+faststart"]
        }
        argList.append(output.path)

        // ★ 必须 `let` 之后再进并发闭包（run #138 / #164 的坑）
        let args = argList
        let mins = Int((totalSec / 60).rounded())
        onProgress(0.02, "正在合并 \(sources.count) 条 · 约 \(max(1, mins)) 分钟")

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
            for p in argv { free(p) }            // 必须释放（照抄 FFmpegConverter 的规矩）
            return c
        }.value
        poller.cancel()

        guard code == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Fail.ffmpegFailed(code)
        }
        let outBytes = Self.bytes(of: output)
        guard outBytes > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Fail.emptyOutput
        }
        onProgress(1.0, "合并完成")
    }

    /// ffmpeg concat 列表里的路径写法：**整条用单引号包住，内部的单引号写成 `'\''`**。
    /// 标题里带引号、空格、中文都很常见，不转义就会拼出一个读不了的文件。
    static func concatQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
