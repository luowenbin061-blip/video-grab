import AVFoundation
import Foundation

/// 把下载好的视频转成 .mp4。
///
/// 三条已查证的硬约束（都不是猜的，下面标了出处）：
///
///  1. **本地 .ts 文件不能交给 AVFoundation。**
///     Apple 开发者论坛官方回复原文：
///       "TS files are not and will not be supported on iOS. You must use fMP4."
///     错误发生在 AVURLAsset 建轨道那一刻，用户看到的就是「无法打开」。
///
///  2. **本地 .m3u8 文件也不行。** HLS 必须来自 http/https —— 把 m3u8 和 .ts
///     全放本地、用 file:// 交给 AVPlayer，会报 CoreMediaErrorDomain -12865/12881。
///     （多处独立来源一致。我上一版把「本地 m3u8」当备选路，是错的，这版去掉。）
///
///  3. 所以输入**只能是本机 HTTP 服务上的 m3u8 地址**（见 LocalHTTPServer）。
///
/// 于是"转 mp4"就变成：从 http://127.0.0.1:端口/xxx.m3u8 把它读出来写成 mp4。
/// 依次试三种手段，每一步的结果都会记录到界面上：
///
///   · 直通重封装（AVAssetReader + AVAssetWriter，无损、秒级）—— HLS 上通常不支持，
///     但便宜，几秒内就知道成败
///   · AVAssetExportSession 重新编码 —— 慢（要花十几到几十分钟），但这是能真正
///     出 mp4 的路
///   · AVMutableComposition 重建轨道后再导出 —— 社区里有不少"直接导出失败、
///     换成 composition 重建就成功"的案例，作为最后一招
enum Exporter {

    /// 一次尝试的记录，直接显示到界面上（上一轮只显示一句笼统原因，看不出卡在哪）
    struct Attempt {
        let name: String
        let ok: Bool
        let detail: String
        var line: String { "\(ok ? "✓" : "✗") \(name)：\(detail)" }
    }

    enum Fail: LocalizedError {
        case noSession
        case noMP4Support([String])
        case cancelled
        case failed(String)
        case writeIncomplete

        var errorDescription: String? {
            switch self {
            case .noSession: return "系统不给建导出会话"
            case .noMP4Support(let t): return "这个预设不能输出 mp4：\(t.joined(separator: ","))"
            case .cancelled: return "已取消"
            case .failed(let s): return s
            case .writeIncomplete: return "写入没有正常结束"
            }
        }
    }

    // MARK: - 入口

    /// candidates 按优先级排列，第一个应该是本机 HTTP 上的 m3u8。
    static func toMP4(candidates: [URL],
                      mp4: URL,
                      onProgress: @escaping (Double, String) -> Void) async -> (ok: Bool, log: [Attempt]) {

        var log: [Attempt] = []
        try? FileManager.default.removeItem(at: mp4)

        guard !candidates.isEmpty else {
            log.append(Attempt(name: "准备", ok: false, detail: "没有可用的输入地址"))
            return (false, log)
        }

        // ① 先探一遍：每个候选能不能读出视频轨。
        //    这一步很便宜，而且能一眼区分「读不到」和「读到了但后面出问题」。
        var opened: [(url: URL, asset: AVAsset, duration: CMTime)] = []
        for url in candidates {
            let asset = AVURLAsset(url: url)
            do {
                let vt = try await asset.loadTracks(withMediaType: .video)
                guard vt.first != nil else {
                    log.append(Attempt(name: "读取 \(short(url))", ok: false, detail: "视频轨是空的"))
                    continue
                }
                let dur = (try? await asset.load(.duration)) ?? .zero
                opened.append((url: url, asset: asset, duration: dur))
                log.append(Attempt(name: "读取 \(short(url))", ok: true,
                                   detail: "读到视频轨 · 时长 \(Int(dur.seconds)) 秒"))
            } catch {
                log.append(Attempt(name: "读取 \(short(url))", ok: false, detail: brief(error)))
            }
        }

        guard !opened.isEmpty else {
            log.append(Attempt(name: "结论", ok: false,
                               detail: "没有任何地址能读出视频轨，转不了"))
            return (false, log)
        }

        // ② 快速路：直通重封装。无损、秒级，值得先花几秒钟试。
        for item in opened {
            if Task.isCancelled { return (false, log) }
            do {
                try await passthrough(asset: item.asset, mp4: mp4)
                log.append(Attempt(name: "直通封装 \(short(item.url))", ok: true,
                                   detail: "成功（无损，秒级完成）"))
                return (true, log)
            } catch {
                log.append(Attempt(name: "直通封装 \(short(item.url))", ok: false,
                                   detail: brief(error)))
            }
        }

        // ③ 主路：AVAssetExportSession 重新编码。慢，但最可能出结果。
        for item in opened {
            if Task.isCancelled { return (false, log) }
            do {
                try await exportSession(asset: item.asset, mp4: mp4, onProgress: onProgress)
                log.append(Attempt(name: "重编码 \(short(item.url))", ok: true, detail: "成功"))
                return (true, log)
            } catch {
                log.append(Attempt(name: "重编码 \(short(item.url))", ok: false,
                                   detail: brief(error)))
            }
        }

        // ④ 最后一招：把轨道插进 AVMutableComposition 再导出
        if let first = opened.first {
            if Task.isCancelled { return (false, log) }
            do {
                try await viaComposition(asset: first.asset, duration: first.duration,
                                         mp4: mp4, onProgress: onProgress)
                log.append(Attempt(name: "重建轨道后导出", ok: true, detail: "成功"))
                return (true, log)
            } catch {
                log.append(Attempt(name: "重建轨道后导出", ok: false, detail: brief(error)))
            }
        }

        log.append(Attempt(name: "结论", ok: false, detail: "三种办法都试过了，都没成"))
        return (false, log)
    }

    // MARK: - 手段 1：直通重封装

    /// 只换容器、不解码不编码。取数据必须**串行** ——
    /// AVAssetReader 不是为并发取设计的，两个轨道要在一个循环里交替取。
    private static func passthrough(asset: AVAsset, mp4: URL) async throws {
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        guard let vTrack = vTracks.first else { throw Fail.failed("没有视频轨") }

        var aTrack: AVAssetTrack?
        if let at = try? await asset.loadTracks(withMediaType: .audio) {
            aTrack = at.first
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Fail.failed("建 reader 失败：\(brief(error))") }

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else {
            throw Fail.failed("这个源不支持直通（HLS 上通常就是这样）")
        }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let at = aTrack {
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) {
                reader.add(o)
                aOut = o
            } else {
                // 源有音轨却加不进 reader —— 直通下去会得到一个没声音的视频，
                // 那比不出结果更糟。直接放弃这条路，交给重新编码。
                throw Fail.failed("有音轨但不支持直通")
            }
        }

        try? FileManager.default.removeItem(at: mp4)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: mp4, fileType: .mp4) }
        catch { throw Fail.failed("建 writer 失败：\(brief(error))") }

        let vHint = try? await vTrack.load(.formatDescriptions).first
        let vIn = AVAssetWriterInput(mediaType: .video,
                                     outputSettings: nil,
                                     sourceFormatHint: vHint)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else {
            throw Fail.failed("视频轨写不进 mp4（TS 里的 H.264 格式不被接受）")
        }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if let at = aTrack {
            let aHint = try? await at.load(.formatDescriptions).first
            let i = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: nil,
                                       sourceFormatHint: aHint)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) {
                writer.add(i)
                aIn = i
            } else {
                throw Fail.failed("音轨写不进 mp4")
            }
        }

        guard reader.startReading() else {
            throw Fail.failed("startReading 失败：\(reader.error.map { brief($0) } ?? "未知")")
        }
        guard writer.startWriting() else {
            throw Fail.failed("startWriting 失败：\(writer.error.map { brief($0) } ?? "未知")")
        }
        writer.startSession(atSourceTime: .zero)

        var vDone = false
        var aDone = (aOut == nil)

        while !(vDone && aDone) {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw Fail.cancelled
            }
            var idle = true

            if !vDone, vIn.isReadyForMoreMediaData {
                idle = false
                if let sb = vOut.copyNextSampleBuffer() {
                    if !vIn.append(sb) {
                        let why = writer.error.map { brief($0) } ?? "未知"
                        reader.cancelReading(); writer.cancelWriting()
                        throw Fail.failed("视频样本被拒：\(why)")
                    }
                } else {
                    vIn.markAsFinished()
                    vDone = true
                }
            }

            if !aDone, let aIn, let aOut, aIn.isReadyForMoreMediaData {
                idle = false
                if let sb = aOut.copyNextSampleBuffer() {
                    if !aIn.append(sb) {
                        let why = writer.error.map { brief($0) } ?? "未知"
                        reader.cancelReading(); writer.cancelWriting()
                        throw Fail.failed("音频样本被拒：\(why)")
                    }
                } else {
                    aIn.markAsFinished()
                    aDone = true
                }
            }

            if idle { try? await Task.sleep(nanoseconds: 3_000_000) }   // 3ms
        }

        if !vDone { vIn.markAsFinished() }
        if !aDone, let aIn { aIn.markAsFinished() }
        if reader.status == .reading { reader.cancelReading() }

        await writer.finishWriting()
        if writer.status == .failed {
            throw Fail.failed(writer.error.map { brief($0) } ?? "未知")
        }
        if writer.status != .completed { throw Fail.writeIncomplete }
    }

    // MARK: - 手段 2：重新编码

    private static func exportSession(asset: AVAsset, mp4: URL,
                                      onProgress: @escaping (Double, String) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw Fail.noSession
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw Fail.noMP4Support(session.supportedFileTypes.map { $0.rawValue })
        }
        try? FileManager.default.removeItem(at: mp4)
        session.outputURL = mp4
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        try await run(session: session, onProgress: onProgress, label: "重新编码")
    }

    // MARK: - 手段 3：重建轨道后导出

    private static func viaComposition(asset: AVAsset, duration: CMTime, mp4: URL,
                                       onProgress: @escaping (Double, String) -> Void) async throws {
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        guard let vSource = vTracks.first else { throw Fail.failed("没有视频轨") }
        let aSource = try? await asset.loadTracks(withMediaType: .audio).first

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Fail.failed("建 composition 视频轨失败")
        }
        // duration 可能是 0（HLS 有时算不出来），退化成"能插多长插多长"
        let span = duration.seconds > 0 ? duration : (try? await asset.load(.duration)) ?? .zero
        let range = CMTimeRange(start: .zero, duration: span)
        do { try vTrack.insertTimeRange(range, of: vSource, at: .zero) }
        catch { throw Fail.failed("插视频轨失败：\(brief(error))") }

        if let aSource,
           let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? aTrack.insertTimeRange(range, of: aSource, at: .zero)
            // 源没有音轨时会产生空轨道，必须摘掉，否则导出必失败
            if aTrack.segments.isEmpty { comp.removeTrack(aTrack) }
        }

        let finalRange = CMTimeRange(start: .zero, duration: comp.duration)

        guard let session = AVAssetExportSession(asset: comp,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw Fail.noSession
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw Fail.noMP4Support(session.supportedFileTypes.map { $0.rawValue })
        }
        try? FileManager.default.removeItem(at: mp4)
        session.outputURL = mp4
        session.outputFileType = .mp4
        session.timeRange = finalRange
        try await run(session: session, onProgress: onProgress, label: "重建导出")
    }

    // MARK: - 跑导出会话（兼容 iOS 15 的老 API）

    private static func run(session: AVAssetExportSession,
                            onProgress: @escaping (Double, String) -> Void,
                            label: String) async throws {
        // 老 API 没有 async 版本，只好轮询 progress
        let poller = Task {
            while !Task.isCancelled {
                let p = Double(session.progress)
                onProgress(p, "\(label)中… \(Int(p * 100))%")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw Fail.cancelled
        default:
            throw Fail.failed(session.error.map { brief($0) } ?? "未知原因")
        }
    }

    // MARK: - 小工具

    private static func short(_ u: URL) -> String {
        if u.isFileURL { return u.lastPathComponent }
        return "\(u.host ?? "?")/\(u.lastPathComponent)"
    }

    /// 把错误写得具体一点 —— 只显示一句「无法打开」是没法定位的
    private static func brief(_ e: Error) -> String {
        let ns = e as NSError
        var s = ns.localizedDescription
        s += " [\(ns.domain)#\(ns.code)]"
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(u.localizedDescription) [\(u.domain)#\(u.code)]"
        }
        if s.count > 220 { s = String(s.prefix(220)) + "…" }
        return s
    }
}
