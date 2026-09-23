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
            guard writer != nil, let vIn else { throw Fail.writer("没有开始写") }
            if stats.videoSamples == 0 { throw Fail.empty }

            vIn.markAsFinished()
            aIn?.markAsFinished()
            onProgress(1.0, "写入收尾…")
            await writer.finishWriting()

            if writer.status == .failed {
                throw Fail.writer(writer.error?.localizedDescription ?? "未知原因")
            }
            if writer.status != .completed {
                throw Fail.writer("写入没有正常结束（status=\(writer.status.rawValue)）")
            }

            if let f = videoFormat {
                let dim = CMVideoFormatDescriptionGetDimensions(f)
                stats.width = Int(dim.width)
                stats.height = Int(dim.height)
            }
            stats.fps = frameDelta > 0 ? 90000.0 / Double(frameDelta) : 0
            var parts = ["H.264 \(stats.width)×\(stats.height) @\(String(format: "%.2f", stats.fps))fps"]
            parts.append("\(stats.videoSamples) 个视频帧")
            if stats.audioSamples > 0 {
                parts.append("\(stats.audioSamples) 个音频帧（\(Int(sampleRate))Hz \(channels)声道）")
            } else if let e = audioFormatError {
                parts.append("音频没写进去：\(e)")
            }
            stats.note = parts.joined(separator: " · ")
            return stats
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
                if pusi == 1 { parsePAT(payload) }
                return
            }
            if pmtPID >= 0, pid == pmtPID {
                if pusi == 1 { parsePMT(payload) }
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

        private func parsePAT(_ payload: ArraySlice<UInt8>) {
            let arr = Array(payload)
            guard arr.count > 12 else { return }
            let ptr = Int(arr[0])
            let sec = Array(arr[(1 + ptr)...])
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

        private func parsePMT(_ payload: ArraySlice<UInt8>) {
            let arr = Array(payload)
            guard arr.count > 12 else { return }
            let ptr = Int(arr[0])
            let sec = Array(arr[(1 + ptr)...])
            guard sec.count >= 12, sec[0] == 0x02 else { return }
            let secLen = (Int(sec[1] & 0x0F) << 8) | Int(sec[2])
            let progInfoLen = (Int(sec[10] & 0x0F) << 8) | Int(sec[11])
            let end = min(3 + secLen - 4, sec.count)
            var k = 12 + progInfoLen
            while k + 5 <= end {
                let st = sec[k]
                let epid = (Int(sec[k + 1] & 0x1F) << 8) | Int(sec[k + 2])
                let esLen = (Int(sec[k + 3] & 0x0F) << 8) | Int(sec[k + 4])
                if st == 0x1B || st == 0x24 || st == 0x02 {
                    if videoPID < 0 { videoPID = epid }
                } else if st == 0x0F || st == 0x11 || st == 0x03 || st == 0x04 {
                    if audioPID < 0 { audioPID = epid }
                }
                k += 5 + esLen
            }
            sawPMT = true
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
            let st: OSStatus = asc.withUnsafeBufferPointer { p in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    formatID: kAudioFormatMPEG4AAC,
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
            if audioPID >= 0, audioFormat == nil, audioFormatError == nil { return }

            // 音画要落在同一根时间轴上，否则会错位（实测音频比视频晚 56.8ms）
            guard let base = resolvedBase() else { return }

            try? FileManager.default.removeItem(at: mp4)
            let w: AVAssetWriter
            do { w = try AVAssetWriter(outputURL: mp4, fileType: .mp4) }
            catch { throw Fail.writer(error.localizedDescription) }

            let v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: nil,
                                       sourceFormatHint: vf)
            v.expectsMediaDataInRealTime = false
            guard w.canAdd(v) else { throw Fail.writer("视频轨加不进去（格式不被接受）") }
            w.add(v)

            var a: AVAssetWriterInput?
            if let af = audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio,
                                               outputSettings: nil,
                                               sourceFormatHint: af)
                input.expectsMediaDataInRealTime = false
                if w.canAdd(input) { w.add(input); a = input }
                else { audioFormatError = "音频轨加不进去" }
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

        /// 把排队的样本写进 writer（起 writer 的条件够不够就在这里面判）
        private func pump(force: Bool = false) async throws {
            if writer == nil {
                if force || videoFirstDTS != nil || pendingBytes > 4 * 1_048_576 {
                    try startWriterIfPossible()
                }
                // 音频格式迟迟建不起来、或文件已经读到尾 → 别为了音频把视频也拖住
                if writer == nil, videoFormat != nil,
                   force || pendingBytes > 12 * 1_048_576 {
                    try startWriterIfPossibleWithoutAudio()
                }
            }
            guard writer != nil, let vIn else { return }

            while !vq.isEmpty {
                if Task.isCancelled { throw Fail.cancelled }
                let it = vq.removeFirst()
                pendingBytes -= it.avcc.count
                if let sb = makeVideoSample(it) {
                    try await append(sb, to: vIn)
                    stats.videoSamples += 1
                }
            }

            if let aIn {
                while !aq.isEmpty {
                    if Task.isCancelled { throw Fail.cancelled }
                    let it = aq.removeFirst()
                    pendingBytes -= it.frame.count
                    if let sb = makeAudioSample(it) {
                        try await append(sb, to: aIn)
                        stats.audioSamples += 1
                    }
                }
            }
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
            v.expectsMediaDataInRealTime = false
            guard w.canAdd(v) else { throw Fail.writer("视频轨加不进去") }
            w.add(v)
            guard w.startWriting() else {
                throw Fail.writer(w.error?.localizedDescription ?? "startWriting 失败")
            }
            w.startSession(atSourceTime: .zero)
            writer = w
            vIn = v
            base90 = base
            aq.removeAll()
            if audioFormatError == nil { audioFormatError = "音频轨始终没能建立，已跳过" }
        }

        private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput) async throws {
            var spin = 0
            while !input.isReadyForMoreMediaData {
                if Task.isCancelled { throw Fail.cancelled }
                try? await Task.sleep(nanoseconds: 2_000_000)
                spin += 1
                if spin > 5000 { throw Fail.writer("writer 长时间不接收数据") }
            }
            if !input.append(sb) {
                throw Fail.writer(input.error?.localizedDescription ?? "样本被拒")
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
