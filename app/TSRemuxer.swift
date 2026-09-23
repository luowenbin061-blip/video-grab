import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// 把 MPEG-TS 里的 H.264 + AAC 抠出来，重封装成 MP4。
///
/// ══ 为什么必须自己写这个 ══
///
/// 已查证的硬事实：**iOS 的 AVFoundation 对 HLS(m3u8) 资源不提供轨道**。
/// `AVURLAsset(url: m3u8).loadTracks(withMediaType: .video)` 永远返回**空数组**，
/// 哪怕这个 m3u8 能被 AVPlayer 正常播放（AVPlayer 走的是另一套内部通道）。
/// 有一份完整实测记录把这些路都试了一遍：
///   · 直接给 m3u8 建 AVAssetReader        → AVFoundationErrorDomain -11800
///   · 从 AVPlayer / AVPlayerItem 拿 asset → tracks 还是空
///   · 用 AVMutableComposition 拿到轨道     → insertTimeRange 报 -12780
/// 也就是说：直通封装 / 重新编码 / 重建轨道 —— 三条路对 HLS 输入全是死的。
///
/// 但我们**根本不需要解码器**：TS 里装的就是 H.264 和 AAC，
/// 只要把它们从 TS 容器里抠出来，用 AVAssetWriter 写进 MP4 容器就行
/// （stbl / avcC / esds 这些繁琐的表由 AVAssetWriter 生成）。
/// 本质上是 `ffmpeg -i in.ts -c copy out.mp4` 做的事，只是不带 FFmpeg。
///
/// ══ 目标流的实测结构（下面这些参数都是量出来的，不是猜的）══
///   · 188 字节定长包，零余数；PMT 里 video=H.264(0x1B)、audio=AAC-ADTS(0x0F)
///   · **一个 PES = 一个访问单元**（首 NAL 固定是 AUD）
///   · 视频 PES 带 PTS+DTS（偶尔只有 PTS）；**有 B 帧**（PTS≠DTS）
///     → 必须同时给出 DTS，否则 AVAssetWriter 生成不出 composition offset
///   · 音频 PES 里塞了 7~9 个 ADTS 帧，每帧 1024 样本
///   · SPS 29 字节 High profile / PPS 4 字节，就在第 0 个 PES 里
enum TSRemuxer {

    struct Stats {
        var videoSamples = 0
        var audioSamples = 0
        var width = 0
        var height = 0
        var fps = 0.0
        var duration = 0.0
        var note: String = ""
    }

    enum Fail: LocalizedError {
        case unreadable(String)
        case noStreams
        case noVideo
        case noParameterSets
        case writer(String)
        case cancelled
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable(let s): return "打不开 .ts 文件：\(s)"
            case .noStreams: return "没解析出 PAT/PMT，拿不到流的 PID"
            case .noVideo: return "TS 里没有 H.264 视频流（可能是 HEVC 或其它编码）"
            case .noParameterSets: return "整段数据里都没找到 SPS/PPS，没法建视频格式"
            case .writer(let s): return "写入 MP4 失败：\(s)"
            case .cancelled: return "已取消"
            case .empty: return "重封装出来是空的"
            }
        }
    }

    /// 主入口。ts 是本地拼好的 .ts 文件，mp4 是输出路径。
    static func toMP4(ts: URL, mp4: URL,
                      onProgress: @escaping (Double, String) -> Void) async throws -> Stats {
        let engine = Engine(ts: ts, mp4: mp4, onProgress: onProgress)
        return try await engine.run()
    }

    // MARK: - 工具

    /// 33 位时间戳（PTS/DTS）
    @inline(__always)
    static func ts33(_ b: [UInt8], _ i: Int) -> Int64 {
        let a = Int64((b[i] & 0x0E) >> 1)
        let bb = Int64(b[i + 1])
        let c = Int64((b[i + 2] & 0xFE) >> 1)
        let d = Int64(b[i + 3])
        let e = Int64((b[i + 4] & 0xFE) >> 1)
        return (a << 30) | (bb << 22) | (c << 15) | (d << 7) | e
    }

    /// 把 33 位环形上的差值解释成有符号数（B 帧会让 PTS 落在 DTS 前后）
    @inline(__always)
    static func signed33(_ raw: Int64) -> Int64 {
        let range: Int64 = 1 << 33
        var v = raw % range
        if v < 0 { v += range }
        return v >= (range >> 1) ? v - range : v
    }

    /// 按 Annex-B 起始码切 NAL。
    ///
    /// 关键细节：起始码可能是 3 字节（00 00 01）或 4 字节（00 00 00 01）。
    /// 实测这段流里 4 字节出现 82 次 —— 如果只按 3 字节切，
    /// 那个多出来的 00 会被粘到上一个 NAL 的尾巴上，**切片数据就被污染了**。
    /// 所以要把起始码前的所有 0 都剥掉（H.264 规范里这些属于 leading_zero_8bits，
    /// 剥掉是合规的）。
    static func splitNALs(_ buf: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        let n = buf.count
        var i = 0
        var start = -1

        func close(_ rawEnd: Int) {
            guard start >= 0 else { return }
            var e = rawEnd
            while e > start, buf[e - 1] == 0 { e -= 1 }
            if e > start { out.append(Array(buf[start..<e])) }
        }

        while i + 2 < n {
            if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                close(i)
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        close(n)
        return out
    }
}

// MARK: - 引擎

extension TSRemuxer {

    /// 单向时间戳展开器：处理 33 位回绕，并把跳变接到一起。
    ///
    /// 不裁剪大的正跳变 —— 那是 HLS 里真实存在的时间间隔（广告插入 / 编码器重启，
    /// 对应清单里的 #EXT-X-DISCONTINUITY）。裁掉的话音画会各自漂移，越到后面越不准。
    private struct Unwrapper {
        private var last: Int64?
        private var accum: Int64 = 0

        mutating func next(_ raw: Int64, nominal: Int64) -> Int64 {
            guard let prev = last else {
                last = raw
                accum = raw
                return accum
            }
            let range: Int64 = 1 << 33
            var d = raw - prev
            if d < -(range >> 1) { d += range }          // 向前回绕
            else if d > (range >> 1) { d -= range }      // 向后回绕
            if d < 0 { d = nominal }                     // 真的倒退了 → 用标称步长顶过去
            last = raw
            accum += d
            return accum
        }
    }

    private final class Engine {

        struct VItem {
            let avcc: [UInt8]
            let dts: Int64       // 已展开，90kHz
            let pts: Int64       // 已展开，90kHz（= dts + 有符号合成偏移）
        }
        struct AItem {
            let frame: [UInt8]
            let pts: Int64       // 已展开，90kHz
            let index: Int       // 本 PES 内的第几个 ADTS 帧
        }

        let ts: URL
        let mp4: URL
        let onProgress: (Double, String) -> Void

        // 解复用状态
        private var pmtPID = -1
        private var videoPID = -1
        private var audioPID = -1
        private var videoPES = [UInt8]()
        private var audioPES = [UInt8]()
        private var sawPMT = false
        // PSI section 重组：PAT/PMT 的 section 经常跨 TS 包，只读单个包会截断
        private var patSection = [UInt8]()
        private var pmtSection = [UInt8]()
        private var pmtSeenCount = 0
        /// audioPID 是从「拿不准的类型」（private data 等）猜出来的
        private var audioPIDIsGuess = false

        // 格式
        private var sps: [UInt8]?
        private var pps: [UInt8]?
        private var videoFormat: CMVideoFormatDescription?
        private var audioFormat: CMAudioFormatDescription?
        private var sampleRate: Double = 44100
        private var channels = 2
        private var audioFormatError: String?

        // 时间轴
        private var dtsUnwrapper = Unwrapper()
        private var audioUnwrapper = Unwrapper()
        private var videoFirstDTS: Int64?
        private var audioFirstPTS: Int64?
        private var base90: Int64?
        private var frameDelta: Int64 = 3600
        private var frameDeltaLocked = false
        /// 保证给 writer 的 DTS 严格递增（相等/倒退都会被拒）
        private var lastEmittedDTS: Int64 = -1
        /// 同理保证音频 PTS 递增
        private var lastAudioT: Int64 = -1
        private var lastVideoDTS: Int64?
        private var firstAudioSampleDone = false

        // ── v1.0.14 新增：诊断 + 兜底状态 ──
        /// writer 一旦 startWriting 就**不能再加输入**。所以要么等音画两种格式
        /// 都齐了再启动；要么确认这条流真的没有音频，才走无音频兜底。
        private var audioSurrendered = false
        private var audioSurrenderWhy: String?
        /// 被放弃的音频包个数（PES）—— 无音频兜底路径上丢弃的，必须留痕
        private var audioDropped = 0
        /// 样本构造失败的次数（静默跳过是大忌 —— 第一个视频没声音就是这么瞎掉的）
        private var videoBuildFails = 0
        private var audioBuildFails = 0
        /// writer 长时间不接收时的兜底：保留已写入部分产出 MP4，而不是全盘失败
        private var partialWrite = false
        private var stallInfo: String?

        private var vq = [VItem]()
        private var aq = [AItem]()
        private var pendingBytes = 0

        // writer
        private var writer: AVAssetWriter?
        private var vIn: AVAssetWriterInput?
        private var aIn: AVAssetWriterInput?

        private var stats = Stats()

        init(ts: URL, mp4: URL, onProgress: @escaping (Double, String) -> Void) {
            self.ts = ts
            self.mp4 = mp4
            self.onProgress = onProgress
        }

        // MARK: 主流程

        func run() async throws -> Stats {
            let attrs = try? FileManager.default.attributesOfItem(atPath: ts.path)
            let total = (attrs?[.size] as? Int) ?? 0
            guard total > 0 else { throw Fail.unreadable("文件是空的") }
            guard let fh = try? FileHandle(forReadingFrom: ts) else {
                throw Fail.unreadable("无法打开")
            }
            defer { try? fh.close() }

            var leftover = [UInt8]()
            let chunk = 188 * 4096          // ~770KB，且是 188 的整数倍，保证包对齐
            var done = 0

            while true {
                if Task.isCancelled { throw Fail.cancelled }
                guard let d = try? fh.read(upToCount: chunk), !d.isEmpty else { break }
                done += d.count

                var buf = leftover
                buf.append(contentsOf: d)

                var i = 0
                while i + 188 <= buf.count {
                    if buf[i] != 0x47 { i += 1; continue }   // 容错：找同步字节
                    parsePacket(buf, at: i)
                    i += 188
                }
                leftover = Array(buf[i...])

                try await pump()

                let pct = Double(done) / Double(total)
                onProgress(pct, "正在重封装… \(done / 1_048_576)MB / \(total / 1_048_576)MB")
            }

            // 收尾
            flushVideoPES()
            flushAudioPES()
            videoPES.removeAll(); audioPES.removeAll()
            try await pump(force: true)

            if !sawPMT { throw Fail.noStreams }
            if videoPID < 0 { throw Fail.noVideo }
            if videoFormat == nil { throw Fail.noParameterSets }
            guard let w = writer, let vIn else { throw Fail.writer("没有开始写") }
            if stats.videoSamples == 0 { throw Fail.empty }

            vIn.markAsFinished()
            aIn?.markAsFinished()
            onProgress(1.0, "写入收尾…")
            // finishWriting 也可能卡住（writer 内部落盘出问题时）—— 20 秒兜底
            await Self.withTimeout(seconds: 20, what: "finishWriting 没有返回") {
                await w.finishWriting()
            }

            if w.status == .failed {
                throw Fail.writer(w.error?.localizedDescription ?? "未知原因")
            }
            if w.status != .completed {
                throw Fail.writer("写入没有正常结束（status=\(w.status.rawValue)）")
            }

            if let f = videoFormat {
                let dim = CMVideoFormatDescriptionGetDimensions(f)
                stats.width = Int(dim.width)
                stats.height = Int(dim.height)
            }
            stats.fps = frameDelta > 0 ? 90000.0 / Double(frameDelta) : 0
            var parts = ["H.264 \(stats.width)×\(stats.height) @\(String(format: "%.2f", stats.fps))fps"]
            parts.append("\(stats.videoSamples) 个视频帧")
            // ── 音频结果必须写明白，一个字都不含糊 ──
            if stats.audioSamples > 0 {
                parts.append("\(stats.audioSamples) 个音频帧（\(Int(sampleRate))Hz \(channels)声道）")
            } else if audioDropped > 0 {
                parts.append("无音频轨：\(audioSurrenderWhy ?? "未知原因")，丢弃 \(audioDropped) 个音频包")
            } else if let e = audioFormatError {
                parts.append("音频没写进去：\(e)")
            } else if audioPID < 0 {
                parts.append("无音频轨：TS 里没识别出音频流")
            } else {
                parts.append("无音频轨：原因不明（音频流存在但一帧都没写出来）")
            }
            if videoBuildFails > 0 { parts.append("视频帧构造失败 \(videoBuildFails) 次") }
            if audioBuildFails > 0 { parts.append("音频帧构造失败 \(audioBuildFails) 次") }
            if partialWrite, let s = stallInfo {
                parts.append("⚠ 只包含部分内容：\(s)")
            }
            stats.note = parts.joined(separator: " · ")
            return stats
        }

        /// 给「可能永远不返回的异步操作」套一个超时。
        /// 超时后不再等待（底层操作继续飘着，但我们不能陪它卡死）。
        private static func withTimeout(seconds: UInt64, what: String,
                                        _ op: @escaping () async -> Void) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let lock = NSLock()
                var resumed = false
                let resumeOnce = {
                    lock.lock()
                    let first = !resumed
                    resumed = true
                    lock.unlock()
                    if first { cont.resume() }
                }
                Task {
                    await op()
                    resumeOnce()
                }
                Task {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    resumeOnce()
                }
            }
            // 超时路径上没法把「没等到」告诉调用方 —— 只能靠 status 检查兜底
            _ = what
        }

        // MARK: TS 包

        private func parsePacket(_ buf: [UInt8], at off: Int) {
            let b1 = buf[off + 1]
            let b2 = buf[off + 2]
            let b3 = buf[off + 3]
            let pusi = (b1 >> 6) & 1
            let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
            let afc = (b3 >> 4) & 0x03

            var p = off + 4
            if afc & 0x02 == 0x02 {
                p += 1 + Int(buf[p])          // 跳过自适应字段
            }
            guard afc & 0x01 == 0x01, p < off + 188 else { return }
            let payload = buf[p..<(off + 188)]

            if pid == 0 {
                feedPSI(payload, pusi: pusi == 1, into: &patSection, isPMT: false)
                return
            }
            if pmtPID >= 0, pid == pmtPID {
                feedPSI(payload, pusi: pusi == 1, into: &pmtSection, isPMT: true)
                return
            }
            if pid == videoPID {
                if pusi == 1 { flushVideoPES(); videoPES.removeAll(keepingCapacity: true) }
                videoPES.append(contentsOf: payload)
                return
            }
            if pid == audioPID {
                if pusi == 1 { flushAudioPES(); audioPES.removeAll(keepingCapacity: true) }
                audioPES.append(contentsOf: payload)
                return
            }
        }

        // MARK: PSI 解析

        /// ══ PSI section 重组（v1.0.14 重写）══
        ///
        /// PAT/PMT 的 section **经常超过一个 TS 包的净荷（184 字节）**，
        /// 旧版只读单个包 → section 被截断 → 排在 section 尾部的音频条目丢失
        /// → audioPID 永远是 -1 → 音频轨整个没人管 → MP4 没有声音。
        ///
        /// 规则（ISO 13818-1）：
        ///   · PUSI 包：第 0 字节是 pointer_field，指出新 section 从哪开始；
        ///     它前面的字节（如果有）是上一个 section 的尾巴
        ///   · 非 PUSI 包：整个净荷都是当前 section 的延续
        private func feedPSI(_ payload: ArraySlice<UInt8>, pusi: Bool,
                             into buf: inout [UInt8], isPMT: Bool) {
            let arr = Array(payload)
            guard !arr.isEmpty else { return }

            if pusi {
                let pointer = Int(arr[0])
                if pointer > 0, !buf.isEmpty {
                    buf.append(contentsOf: arr[1..<min(1 + pointer, arr.count)])
                    if let sec = psiSection(buf) {
                        buf.removeAll(keepingCapacity: true)
                        if isPMT { parsePMT(sec) } else { parsePAT(sec) }
                    }
                }
                buf = Array(arr[min(1 + pointer, arr.count)...])
            } else {
                guard !buf.isEmpty else { return }   // 不在 section 中间的散包
                buf.append(contentsOf: arr)
            }

            if let sec = psiSection(buf) {
                buf.removeAll(keepingCapacity: true)
                if isPMT { parsePMT(sec) } else { parsePAT(sec) }
            }
        }

        /// section 凑齐了吗？凑齐了就完整取出来（section 长度写在第 1~2 字节）
        private func psiSection(_ buf: [UInt8]) -> [UInt8]? {
            guard buf.count >= 3 else { return nil }
            let secLen = (Int(buf[1] & 0x0F) << 8) | Int(buf[2])
            let total = 3 + secLen
            guard total >= 9, buf.count >= total else { return nil }
            return Array(buf[0..<total])
        }

        private func parsePAT(_ sec: [UInt8]) {
            guard sec.count >= 12, sec[0] == 0x00 else { return }
            let secLen = (Int(sec[1] & 0x0F) << 8) | Int(sec[2])
            let end = min(3 + secLen - 4, sec.count)
            var k = 8
            while k + 4 <= end {
                let prog = (Int(sec[k]) << 8) | Int(sec[k + 1])
                let ppid = (Int(sec[k + 2] & 0x1F) << 8) | Int(sec[k + 3])
                if prog != 0, ppid > 0 { pmtPID = ppid }
                k += 4
            }
        }

        private func parsePMT(_ sec: [UInt8]) {
            guard sec.count >= 12, sec[0] == 0x02 else { return }
            pmtSeenCount += 1
            sawPMT = true
            let secLen = (Int(sec[1] & 0x0F) << 8) | Int(sec[2])
            let progInfoLen = (Int(sec[10] & 0x0F) << 8) | Int(sec[11])
            let end = min(3 + secLen - 4, sec.count)
            var k = 12 + progInfoLen
            while k + 5 <= end {
                let st = sec[k]
                let epid = (Int(sec[k + 1] & 0x1F) << 8) | Int(sec[k + 2])
                let esLen = (Int(sec[k + 3] & 0x0F) << 8) | Int(sec[k + 4])
                if st == 0x1B || st == 0x24 || st == 0x02 || st == 0x10 {
                    if videoPID < 0 { videoPID = epid }
                } else if st == 0x0F || st == 0x11 || st == 0x03 || st == 0x04 {
                    // 明确的音频类型 —— 即使之前拿不准认过一个，也升级成确定的
                    if audioPID < 0 || audioPIDIsGuess { audioPID = epid; audioPIDIsGuess = false }
                } else if audioPID < 0, st == 0x06 || st == 0x81 {
                    // 拿不准的（private data / AC-3）—— 先记着，遇到确定的会升级。
                    // 就算认错（比如其实是字幕），ADTS 同步找不到 → 队列是空的 →
                    // 10 秒兜底会放弃音频并写明原因，不会卡死。
                    if audioPID < 0 { audioPID = epid; audioPIDIsGuess = true }
                }
                k += 5 + esLen
            }
        }

        // MARK: PES → 样本

        /// 取出 PES 的 (body, ptsRaw, dtsRaw, pdts)
        private func pesParts(_ pes: [UInt8]) -> (body: [UInt8], pts: Int64?, dts: Int64?) {
            guard pes.count > 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else {
                return ([], nil, nil)
            }
            let pesLen = (Int(pes[4]) << 8) | Int(pes[5])
            let pdts = (pes[7] >> 6) & 0x03
            let hlen = Int(pes[8])
            var pts: Int64?
            var dts: Int64?
            if pdts == 2 {
                pts = TSRemuxer.ts33(pes, 9)
                dts = pts
            } else if pdts == 3 {
                pts = TSRemuxer.ts33(pes, 9)
                dts = TSRemuxer.ts33(pes, 14)
            }
            var end = pes.count
            if pesLen > 0 {
                let total = 6 + pesLen
                if total < end { end = total }      // 有尾部填充时按声明长度截断
            }
            let bodyStart = 9 + hlen
            guard end > bodyStart else { return ([], pts, dts) }
            return (Array(pes[bodyStart..<end]), pts, dts)
        }

        private func flushVideoPES() {
            guard videoPID >= 0, videoPES.count > 9 else { return }
            let (body, ptsRaw, dtsRaw) = pesParts(videoPES)
            guard let ptsRaw, let dtsRaw, !body.isEmpty else { return }

            let nals = TSRemuxer.splitNALs(body)
            guard !nals.isEmpty else { return }

            var avcc = [UInt8]()
            avcc.reserveCapacity(body.count + 4 * nals.count)
            for n in nals {
                guard let t = n.first.map({ $0 & 0x1F }) else { continue }
                if t == 7 { if sps == nil { sps = n } }
                else if t == 8 { if pps == nil { pps = n } }
                if t == 9 { continue }               // AUD 对 mp4 没意义，去掉
                let len = n.count
                avcc.append(UInt8((len >> 24) & 0xFF))
                avcc.append(UInt8((len >> 16) & 0xFF))
                avcc.append(UInt8((len >> 8) & 0xFF))
                avcc.append(UInt8(len & 0xFF))
                avcc.append(contentsOf: n)
            }
            guard !avcc.isEmpty else { return }

            // DTS 是单调的，拿它当时间轴；PTS 用「相对 DTS 的有符号偏移」还原 ——
            // 不能对 PTS 单独做累加，因为 B 帧会让 PTS 在时间轴上来回跳。
            let dts = dtsUnwrapper.next(dtsRaw, nominal: frameDelta)
            if let prev = lastVideoDTS {
                let d = dts - prev
                // 只从头两帧定帧长，后面别被跳变带跑
                if !frameDeltaLocked, d > 0, d < 90000 {
                    frameDelta = d
                    frameDeltaLocked = true
                }
            }
            lastVideoDTS = dts
            let offset = TSRemuxer.signed33(ptsRaw - dtsRaw)
            var pts = dts + offset
            if pts < dts { pts = dts }                       // 合成偏移不能为负

            if videoFirstDTS == nil { videoFirstDTS = dts }
            vq.append(VItem(avcc: avcc, dts: dts, pts: pts))
            pendingBytes += avcc.count
        }

        private func flushAudioPES() {
            guard audioPID >= 0, audioPES.count > 9 else { return }
            if audioSurrendered {
                // 无音频兜底路径上，音频包只能放弃 —— 但必须留痕，不能悄悄扔
                audioDropped += 1
                return
            }
            let (body, ptsRaw, _) = pesParts(audioPES)
            guard let ptsRaw, !body.isEmpty else { return }

            let base = audioUnwrapper.next(ptsRaw, nominal: 2090)
            if audioFirstPTS == nil { audioFirstPTS = base }

            var off = 0
            var idx = 0
            let n = body.count
            while off + 7 <= n {
                guard body[off] == 0xFF, (body[off + 1] & 0xF0) == 0xF0 else { break }
                let protAbsent = Int(body[off + 1] & 0x01)
                let profile = Int((body[off + 2] >> 6) & 0x03)
                let sfi = Int((body[off + 2] >> 2) & 0x0F)
                let chan = (Int(body[off + 2] & 0x01) << 2) | Int((body[off + 3] >> 6) & 0x03)
                let flen = (Int(body[off + 3] & 0x03) << 11)
                    | (Int(body[off + 4]) << 3)
                    | Int((body[off + 5] >> 5) & 0x07)
                let hlen = protAbsent == 1 ? 7 : 9
                guard flen > hlen, off + flen <= n else { break }

                if audioFormat == nil { buildAudioFormat(profile: profile, sfi: sfi, chan: chan) }

                let frame = Array(body[(off + hlen)..<(off + flen)])
                aq.append(AItem(frame: frame, pts: base, index: idx))
                pendingBytes += frame.count
                idx += 1
                off += flen
            }
        }

        // MARK: 格式

        private func buildAudioFormat(profile: Int, sfi: Int, chan: Int) {
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000,
                                   24000, 22050, 16000, 12000, 11025, 8000, 7350]
            guard sfi >= 0, sfi < rates.count else {
                audioFormatError = "ADTS 采样率索引 \(sfi) 不合法"
                return
            }
            sampleRate = rates[sfi]
            channels = max(1, chan)
            let aot = profile + 1

            // AudioSpecificConfig：5 位 aot + 4 位采样率索引 + 4 位声道数
            // 实测这段流是 AAC-LC / 44100 / 立体声 → 12 10
            let asc: [UInt8] = [
                UInt8((aot << 3) | (sfi >> 1)),
                UInt8(((sfi & 1) << 7) | (channels << 3))
            ]

            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0,
                mReserved: 0)

            var fmt: CMAudioFormatDescription?
            // 注意：这个 API 没有 formatID 参数 —— 格式从 asbd.mFormatID 取
            let st: OSStatus = asc.withUnsafeBufferPointer { p in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: asc.count,
                    magicCookie: p.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &fmt)
            }
            if st == 0, let f = fmt {
                audioFormat = f
            } else {
                audioFormatError = "CMAudioFormatDescriptionCreate 失败 OSStatus=\(st)"
            }
        }

        private func buildVideoFormat() {
            guard videoFormat == nil, let s = sps, let p = pps,
                  !s.isEmpty, !p.isEmpty else { return }
            var fmt: CMVideoFormatDescription?
            var status: OSStatus = -1
            s.withUnsafeBufferPointer { sBuf in
                p.withUnsafeBufferPointer { pBuf in
                    let ptrs: [UnsafePointer<UInt8>] = [sBuf.baseAddress!, pBuf.baseAddress!]
                    let sizes: [Int] = [s.count, p.count]
                    ptrs.withUnsafeBufferPointer { ptrBuf in
                        sizes.withUnsafeBufferPointer { sizeBuf in
                            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrBuf.baseAddress!,
                                parameterSetSizes: sizeBuf.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &fmt)
                        }
                    }
                }
            }
            if status == 0 { videoFormat = fmt }
        }

        // MARK: 写 MP4

    private func startWriterIfPossible() throws {
            guard writer == nil else { return }
            guard videoPID >= 0 else { return }
            buildVideoFormat()
            guard let vf = videoFormat else { return }          // 还没拿到 SPS/PPS
            // ★ v1.0.14：走到这里的前提是 maybeStartWriter 已确认音频格式就绪。
            //   绝不允许在音频缺失时启动双轨 writer —— startWriting 之后
            //   就不能再加输入，那等于给整个文件判「无声」。
            guard let af = audioFormat else { return }

            // 音画要落在同一根时间轴上，否则会错位（实测音频比视频晚 56.8ms）
            guard let base = resolvedBase() else { return }

            try? FileManager.default.removeItem(at: mp4)
            let w: AVAssetWriter
            do { w = try AVAssetWriter(outputURL: mp4, fileType: .mp4) }
            catch { throw Fail.writer(error.localizedDescription) }

            let v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: nil,
                                       sourceFormatHint: vf)
            // ⚠️ 这里必须用 true（实时模式）。文档写得很清楚：
            //   有多个输入时，asset writer 会按时间戳交错写入，只有"就绪"的输入才能
            //   追加数据；而 expectsMediaDataInRealTime 为 false 时，就绪性会被
            //   「两路进度是否匹配」影响 —— 我们按时间归并喂（见 pump），
            //   用实时模式让就绪性只反映处理压力，不再被交错卡死。
            //   因为我们是按时间戳顺序追加的，输出文件照样是交错好的。
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { throw Fail.writer("视频轨加不进去（格式不被接受）") }
            w.add(v)

            var a: AVAssetWriterInput?
            if let af = audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio,
                                               outputSettings: nil,
                                               sourceFormatHint: af)
                input.expectsMediaDataInRealTime = true
                if w.canAdd(input) { w.add(input); a = input }
                else { audioFormatError = "音频轨加不进去" }
            }
            if a == nil, audioFormatError == nil {
                audioFormatError = "音频输入没能创建（should not happen，见 maybeStartWriter）"
            }

            guard w.startWriting() else {
                throw Fail.writer(w.error?.localizedDescription ?? "startWriting 失败")
            }
            w.startSession(atSourceTime: .zero)

            writer = w
            vIn = v
            aIn = a
            base90 = base
        }

        /// 公共基准：视频首 DTS 与音频首 PTS 里较小的那个（90kHz）
        private func resolvedBase() -> Int64? {
            switch (videoFirstDTS, audioFirstPTS) {
            case let (v?, a?): return min(v, a)
            case let (v?, nil): return v
            case let (nil, a?): return a
            default: return nil
            }
        }

        /// 把排队的样本写进 writer。
        ///
        /// ══ v1.0.13 的死锁教训 ══
        /// Apple 文档：writer 有多个输入时按时间戳交错写入，某条轨道不就绪时不能塞。
        /// 旧版先喂完视频再喂音频 → 视频等音频、音频没机会喂 → 死锁。
        /// 现在按时间戳归并：每次挑时间更早的那路喂，一路不就绪就先喂另一路。
        ///
        /// ══ v1.0.14 的两个新教训 ══
        /// 1. writer 一旦 startWriting 就**不能再加输入** —— 启动时机由
        ///    maybeStartWriter 统一把关：音画格式都齐了才启动（修「没有声音」）。
        /// 2. 「等 5 秒不收就报错」太急 —— 高码率流（4.8Mbps）一次落盘就能
        ///    超过 5 秒，第二个视频就是这么死的。放宽到 30 秒；真等不到就
        ///    **保留已写入部分**产出 MP4（部分内容好过全盘失败），并把
        ///    两队列的积压和已写帧数写进记录。
        private func pump(force: Bool = false) async throws {
            if writer == nil {
                try maybeStartWriter(force: force)
            }
            guard let w = writer, let vIn else { return }
            if aIn == nil, !aq.isEmpty {
                // 无音频兜底路径：音频帧只能放弃，但必须留痕
                audioDropped += aq.count
                aq.removeAll()
            }

            var spin = 0
            while !(vq.isEmpty && aq.isEmpty) {
                if Task.isCancelled { throw Fail.cancelled }
                if w.status == .failed {
                    throw Fail.writer("writer 内部报错：\(w.error?.localizedDescription ?? "未知")")
                }

                let vT = vq.first.map { max($0.dts - (base90 ?? 0), 0) }
                let aT = aq.first.map { audioT90($0) }
                let vReady = vIn.isReadyForMoreMediaData
                let aReady = aIn?.isReadyForMoreMediaData ?? false

                let preferVideo: Bool
                switch (vT, aT) {
                case let (.some(v), .some(a)): preferVideo = v <= a
                case (.some, .none): preferVideo = true
                default: preferVideo = false
                }

                var did = false
                if preferVideo, vReady, let it = popVideo() {
                    try appendNow(makeVideoSample(it), to: vIn); did = true
                } else if !preferVideo, aReady, let aIn, let it = popAudio() {
                    try appendNow(makeAudioSample(it), to: aIn); did = true
                } else if vReady, let it = popVideo() {
                    // 首选那一路没收，就先喂另一路 —— 不能死等
                    try appendNow(makeVideoSample(it), to: vIn); did = true
                } else if aReady, let aIn, let it = popAudio() {
                    try appendNow(makeAudioSample(it), to: aIn); did = true
                }

                if did { spin = 0; continue }

                spin += 1
                if spin % 2500 == 0 {
                    // 每 5 秒报一次状态 —— 万一最后还是不行，界面记录里有完整线索
                    onProgress(-1, String(format: "等待 writer 接收数据… 已等 %d 秒（积压 视频 %d 帧 / 音频 %d 帧）",
                                          spin / 500, vq.count, aq.count))
                }
                if spin > 15000 {          // 约 30 秒（每轮 2ms）
                    partialWrite = true
                    stallInfo = String(format: "writer 30 秒不接收（status=%d），已写视频 %d 帧 / 音频 %d 帧，积压视频 %d / 音频 %d 已丢弃",
                                       w.status.rawValue, stats.videoSamples, stats.audioSamples,
                                       vq.count, aq.count)
                    vq.removeAll(); aq.removeAll(); pendingBytes = 0
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        /// ══ writer 的启动时机（v1.0.14 的核心修改，修「没有声音」）══
        ///
        /// 为什么不能像旧版那样「有视频就启动」：
        ///   AVAssetWriter 一旦 startWriting()，**就不能再添加任何输入**。
        ///   旧版在第一帧视频就启动，那一刻音频往往还没就绪（甚至 audioPID
        ///   还没解析出来）→ 音频输入永远加不进去 → MP4 只有视频轨。
        ///
        /// 现在的规则：
        ///   · 音频格式就绪 → 立即启动（音画双轨）
        ///   · 音频确实不存在 / 等了 10 秒还没出现 / 缓冲超限 → 明确放弃音频，
        ///     走无音频兜底，并把放弃原因写进记录
        private func maybeStartWriter(force: Bool) throws {
            guard writer == nil, videoFormat != nil, videoFirstDTS != nil else { return }

            if audioFormat != nil {
                try startWriterIfPossible()
                return
            }
            if audioSurrendered {
                try startWriterIfPossibleWithoutAudio()
                return
            }

            var why: String?
            if force {
                why = "文件读完了音频格式还没建出来"
            } else if sawPMT, audioPID < 0, pmtSeenCount >= 3 {
                why = "PMT 重复出现 \(pmtSeenCount) 次都没有音频条目"
            } else if let v0 = videoFirstDTS, let vNow = lastVideoDTS, vNow - v0 >= 900_000 {
                why = String(format: "视频走了 %.0f 秒音频还没出现", (vNow - v0) / 90_000.0)
            } else if pendingBytes > 48 * 1_048_576 {
                why = "等待音频期间缓冲已超 48MB"
            }
            guard let why else { return }   // 继续等音频

            audioSurrendered = true
            audioSurrenderWhy = why
            try startWriterIfPossibleWithoutAudio()
        }

        private func popVideo() -> VItem? {
            guard !vq.isEmpty else { return nil }
            let it = vq.removeFirst()
            pendingBytes -= it.avcc.count
            return it
        }

        private func popAudio() -> AItem? {
            guard !aq.isEmpty else { return nil }
            let it = aq.removeFirst()
            pendingBytes -= it.frame.count
            return it
        }

        /// 音频样本时间换算到 90kHz，只用来跟视频比先后
        private func audioT90(_ it: AItem) -> Int64 {
            guard let base = base90 else { return 0 }
            let rate = Int64(Int(sampleRate))
            let shift = Int64((Double(it.pts - base) * sampleRate / 90000.0).rounded())
            let samples = shift + Int64(it.index) * 1024
            return rate > 0 ? samples * 90000 / rate : 0
        }

        /// 就绪性已经在外面判过了，这里直接追加。
        /// 样本构造失败（sb == nil）**绝不能静默跳过** ——
        /// 第一个视频没声音，查到最后发现失败全被吞了，界面上一点痕迹都没有。
        private func appendNow(_ sb: CMSampleBuffer?, to input: AVAssetWriterInput) throws {
            guard let sb else {
                if input.mediaType == .video { videoBuildFails += 1 }
                else { audioBuildFails += 1 }
                return
            }
            if !input.append(sb) {
                let why = writer?.error?.localizedDescription ?? "原因未提供"
                throw Fail.writer("样本被拒：\(why)")
            }
            if input.mediaType == .video { stats.videoSamples += 1 }
            else { stats.audioSamples += 1 }
        }

        private func startWriterIfPossibleWithoutAudio() throws {
            guard writer == nil, let vf = videoFormat,
                  let base = resolvedBase() else { return }
            try? FileManager.default.removeItem(at: mp4)
            let w: AVAssetWriter
            do { w = try AVAssetWriter(outputURL: mp4, fileType: .mp4) }
            catch { throw Fail.writer(error.localizedDescription) }
            let v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: nil,
                                       sourceFormatHint: vf)
            v.expectsMediaDataInRealTime = true      // 同上：见 startWriterIfPossible 里的说明
            guard w.canAdd(v) else { throw Fail.writer("视频轨加不进去") }
            w.add(v)
            guard w.startWriting() else {
                throw Fail.writer(w.error?.localizedDescription ?? "startWriting 失败")
            }
            w.startSession(atSourceTime: .zero)
            writer = w
            vIn = v
            base90 = base
            // 已排队的音频帧不在这里清 —— pump 里会清掉并计数留痕
            if audioSurrenderWhy != nil, audioFormatError == nil {
                audioFormatError = "音频轨没建起来（\(audioSurrenderWhy ?? "")）"
            }
        }

        // MARK: 样本构造

        private func makeVideoSample(_ it: VItem) -> CMSampleBuffer? {
            guard let f = videoFormat, let base = base90 else { return nil }
            var dts = it.dts - base
            if dts < 0 { dts = 0 }
            if dts <= lastEmittedDTS { dts = lastEmittedDTS + 1 }
            lastEmittedDTS = dts
            var pts = it.pts - base
            if pts < dts { pts = dts }

            guard let bb = makeBlockBuffer(it.avcc) else { return nil }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: frameDelta, timescale: 90000),
                presentationTimeStamp: CMTime(value: pts, timescale: 90000),
                decodeTimeStamp: CMTime(value: dts, timescale: 90000))
            var size = it.avcc.count
            var sb: CMSampleBuffer?
            let st = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: f,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sb)
            return st == 0 ? sb : nil
        }

        private func makeAudioSample(_ it: AItem) -> CMSampleBuffer? {
            guard let f = audioFormat, let base = base90 else { return nil }
            let rate = Int32(sampleRate)
            // 统一换算到「样本数」为时间单位，避免 90kHz 换算的取整误差累积
            let shift = Int64((Double(it.pts - base) * sampleRate / 90000.0).rounded())
            var t = shift + Int64(it.index) * 1024
            if t <= lastAudioT { t = lastAudioT + 1024 }
            lastAudioT = t

            guard let bb = makeBlockBuffer(it.frame) else { return nil }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1024, timescale: rate),
                presentationTimeStamp: CMTime(value: t, timescale: rate),
                decodeTimeStamp: .invalid)
            var size = it.frame.count
            var sb: CMSampleBuffer?
            let st = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: f,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sb)
            return st == 0 ? sb : nil
        }

        private func makeBlockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
            let n = bytes.count
            guard n > 0 else { return nil }
            var bb: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: n,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: n,
                flags: 0,
                blockBufferOut: &bb) == 0, let block = bb else { return nil }

            let copied: Bool = bytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferReplaceDataBytes(with: base,
                                                     blockBuffer: block,
                                                     offsetIntoDestination: 0,
                                                     dataLength: n) == 0
            }
            return copied ? block : nil
        }
    }
}
