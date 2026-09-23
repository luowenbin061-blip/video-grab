import AVFoundation
import Foundation

/// 把拼接出来的 .ts 重新封装成 .mp4。
///
/// 为什么不用 AVAssetExportSession：
///   它对 MPEG-TS 输入的 Passthrough 支持不可靠，会报 AVErrorCannotExportPreset。
/// 这里用 AVAssetReader + AVAssetWriter 直通压缩数据（outputSettings: nil）——
/// 只换容器、不解码不编码。47 分钟的视频通常十几秒就能完事，画质零损失。
///
/// 注意：取数据是**串行**的。AVAssetReader 不是为并发取设计，
/// 两个轨道要在一个循环里交替取，不能用两个并发任务各取一路。
enum Remuxer {

    enum Fail: LocalizedError {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        case writeIncomplete

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "系统读不出这个 .ts 里的视频轨（说明 iOS 不认它的封装）"
            case .readerFailed(let s): return "读取失败：\(s)"
            case .writerFailed(let s): return "写入失败：\(s)"
            case .writeIncomplete: return "写入没有正常结束"
            }
        }
    }

    /// ts → mp4
    static func toMP4(ts: URL, mp4: URL) async throws {
        let asset = AVURLAsset(url: ts)

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Fail.noVideoTrack
        }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Fail.readerFailed(error.localizedDescription)
        }

        // outputSettings: nil = 直通，拿到的直接是压缩样本
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw Fail.readerFailed("视频轨不能直通") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let at = aTrack {
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) {
                reader.add(o)
                aOut = o
            }
        }

        try? FileManager.default.removeItem(at: mp4)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: mp4, fileType: .mp4)
        } catch {
            throw Fail.writerFailed(error.localizedDescription)
        }

        let vHint = try await vTrack.load(.formatDescriptions).first
        let vIn = AVAssetWriterInput(mediaType: .video,
                                     outputSettings: nil,
                                     sourceFormatHint: vHint)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw Fail.writerFailed("视频轨写不进 mp4") }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if let at = aTrack {
            let aHint = try await at.load(.formatDescriptions).first
            let i = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: nil,
                                       sourceFormatHint: aHint)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) {
                writer.add(i)
                aIn = i
            }
        }

        guard reader.startReading() else {
            throw Fail.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }
        guard writer.startWriting() else {
            throw Fail.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)

        var vDone = false
        var aDone = (aOut == nil)

        while !(vDone && aDone) {
            if Task.isCancelled { break }
            var idle = true

            // 视频
            if !vDone && vIn.isReadyForMoreMediaData {
                idle = false
                if let sb = vOut.copyNextSampleBuffer() {
                    if !vIn.append(sb) {
                        throw Fail.writerFailed(writer.error?.localizedDescription ?? "视频样本被拒")
                    }
                } else {
                    vIn.markAsFinished()
                    vDone = true
                }
            }

            // 音频
            if !aDone, let aIn, let aOut, aIn.isReadyForMoreMediaData {
                idle = false
                if let sb = aOut.copyNextSampleBuffer() {
                    if !aIn.append(sb) {
                        throw Fail.writerFailed(writer.error?.localizedDescription ?? "音频样本被拒")
                    }
                } else {
                    aIn.markAsFinished()
                    aDone = true
                }
            }

            // 两边都在等 writer 就绪，让出一下
            if idle {
                try? await Task.sleep(nanoseconds: 3_000_000)   // 3ms
            }
        }

        if !vDone { vIn.markAsFinished() }
        if !aDone, let aIn { aIn.markAsFinished() }
        if reader.status == .reading { reader.cancelReading() }

        await writer.finishWriting()

        if writer.status == .failed {
            throw Fail.writerFailed(writer.error?.localizedDescription ?? "未知原因")
        }
        if writer.status != .completed {
            throw Fail.writeIncomplete
        }
    }
}
