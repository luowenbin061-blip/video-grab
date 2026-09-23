import AVFoundation
import Foundation

/// 把下载下来的 HLS 重新封装成 .mp4。
///
/// 两条硬性约束（都是实测/查证过的）：
///  1. **不能直接把本地 .ts 文件交给 AVFoundation** —— Apple 官方明确说
///     "TS files are not and will not be supported on iOS. You must use fMP4."，
///     报错就发生在 AVURLAsset 建轨道那一步，信息是「无法打开 / 不支持此媒体格式」。
///  2. 但 AVFoundation **能读通过 HTTP 以 HLS 形式提供的 TS**（AVPlayer 播 m3u8 就这机制）。
///
/// 所以这里的入参是**本机 HTTP 服务器上的 m3u8 地址**，不是本地文件路径。
/// 拿到 asset 之后用 AVAssetReader + AVAssetWriter 直通重封装：
/// 只换容器、不解码不编码，画质零损失。
///
/// 注意：取数据是**串行**的。AVAssetReader 不是为并发取设计，
/// 两个轨道要在一个循环里交替取，不能用两个并发任务各取一路。
enum Remuxer {

    enum Fail: LocalizedError {
        case noVideoTrack(String)
        case readerFailed(String)
        case writerFailed(String)
        case writeIncomplete

        var errorDescription: String? {
            switch self {
            case .noVideoTrack(let d):
                return "系统读不出视频轨：\(d)"
            case .readerFailed(let s): return "读取失败：\(s)"
            case .writerFailed(let s): return "写入失败：\(s)"
            case .writeIncomplete: return "写入没有正常结束"
            }
        }
    }

    /// hls（本机 HTTP 的 m3u8 地址）→ mp4
    static func toMP4(hls: URL, mp4: URL) async throws {
        let asset = AVURLAsset(url: hls)

        // 把失败原因原样带出来 —— 之前只显示一句笼统的「无法打开」，没法定位
        let vTracks: [AVAssetTrack]
        do {
            vTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw Fail.noVideoTrack("\(error.localizedDescription)（\(type(of: error))）")
        }
        guard let vTrack = vTracks.first else {
            throw Fail.noVideoTrack("轨道列表是空的")
        }
        // 注意不能写 `try? await asset.loadTracks(...).first` ——
        // 那会得到 AVAssetTrack?? 的嵌套可选，类型对不上。
        var aTrack: AVAssetTrack?
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
            aTrack = audioTracks.first
        }

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
