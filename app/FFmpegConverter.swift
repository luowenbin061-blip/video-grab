import Foundation
import AVFoundation
import FFmpegSupport

/// 成熟方案：进程内跑 FFmpeg CLI 做重封装。
/// （Stay / 亚瑟 / 各类下载器 App 内部用的都是这条引擎路线）
///
/// 为什么换成它：自写 demuxer 的重封装已被实测证明不可靠（反复出问题），
/// 而用户拿同一个 .ts 用其他转码软件「几秒钟就转好了」—— 说明文件是好的，
/// 该用成熟引擎。`-c copy` 只换容器不重编码：
///   · 秒级完成（50MB 几秒钟）
///   · 音轨原样保留（ADTS→ASC、B 帧 ctts、LATM、HEVC 全由 FFmpeg 处理）
///   · `+faststart` 把 moov 挪到文件头 → 拖进度条秒响应
enum FFmpegConverter {

    /// 返回体检结果文本（写进过程记录）
    static func toMP4(ts: URL, mp4: URL,
                      onProgress: @escaping (Double, String) -> Void) async throws -> String {
        try? FileManager.default.removeItem(at: mp4)

        onProgress(0, "FFmpeg 重封装中…")
        let args: [String] = [
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-y",
            "-i", ts.path,
            "-map", "0:v:0",      // 第一条视频流
            "-map", "0:a:0?",     // 第一条音频流（? = 没有也不报错）
            "-sn", "-dn",         // 字幕/数据流不要（mp4 装不下会整单失败）
            "-c", "copy",         // 只换容器，不重新编码 → 快 + 无损
            "-movflags", "+faststart",
            mp4.path,
        ]

        // ffmpeg() 是阻塞调用（进程内跑 CLI 主函数），丢到后台线程跑。
        // 返回 0 = 成功，非 0 = ffmpeg 自己的退出码。
        let code = await Task.detached(priority: .userInitiated) {
            ffmpeg(args)
        }.value

        guard code == 0 else {
            throw NSError(domain: "VideoGrab.FFmpeg", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(format: "FFmpeg 退出码 %d（0 = 成功）", code)])
        }

        // ── 体检输出文件：轨、时长全写进过程记录 ──
        // 本地 MP4 的轨道查询是可靠的（HLS 才返回空数组）。
        let asset = AVURLAsset(url: mp4)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty else {
            throw NSError(domain: "VideoGrab.FFmpeg", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "输出里没有视频轨（转码没成功）"])
        }
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        var info = String(format: "视频轨 %d 条 · 时长 %.0f 秒", vTracks.count, dur)
        if aTracks.isEmpty {
            info += " · ⚠ 没有音轨（源里可能就没带音频）"
        } else {
            info += " · 音轨存在 ✔"
            if let fd = try? await aTracks[0].load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                info += String(format: "（%.0fHz %d 声道）",
                               asbd.pointee.mSampleRate, Int(asbd.pointee.mChannelsPerFrame))
            }
        }
        onProgress(1, info)
        return info
    }
}
