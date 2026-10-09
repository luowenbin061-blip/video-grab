import AVFoundation
import Foundation

/// 把**分开的两条流**（一条视频、一条音频）合成一个 mp4。
///
/// ★ 为什么需要它：B站 的高清是 **DASH** —— 画面和声音是**两个文件**，
///   分开下完之后必须合起来才是一个能播的视频。
///   工程里原有的两个合并工具都不管这件事：
///   · `FFmpegConverter.toMP4` 只接受**单个**输入（它做的是"换容器"）
///   · `Merger` 做的是"多个**完整**视频首尾相接"
///   所以这里是新的一档：**两条流 → 一个文件**。
///
/// ★ 全程 `-c copy`：不重编码 → 快、且**画质一点不掉**。
///   （用户对画质敏感，"能不动编码就不动"是这里的硬要求。）
enum AVRemux {

    enum Fail: LocalizedError {
        case ffmpeg(Int32)
        case noVideoTrack
        case demuxerHint

        var errorDescription: String? {
            switch self {
            case .ffmpeg(let c): return "合并失败（ffmpeg 退出码 \(c)）"
            case .noVideoTrack: return "合出来的文件里没有画面（这一步没成功）"
            case .demuxerHint: return "合并失败 —— 两条流的容器对不上"
            }
        }
    }

    /// 合并。返回成品体积（字节）。
    ///
    /// - Parameters:
    ///   - video: 视频流文件（B站的 `.m4s`）
    ///   - audio: 音频流文件
    ///   - out: 输出 mp4 路径
    ///   - faststart: 是否把索引挪到文件头（大文件挪一次要重写整个文件，所以有体积门槛）
    @discardableResult
    static func merge(video: URL, audio: URL, out: URL,
                      faststart: Bool = true,
                      onStage: @escaping (String) -> Void = { _ in }) async throws -> Int64 {
        let fm = FileManager.default
        try? fm.createDirectory(at: out.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: out)

        var argList: [String] = [
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-y",
            "-i", video.path,
            "-i", audio.path,
            "-map", "0:v:0",          // 画面取第一条输入
            "-map", "1:a:0",          // 声音取第二条输入
            "-sn", "-dn",             // 字幕/数据轨不要（mp4 装不下会让整单失败）
            "-c", "copy",             // 只换容器，不重编码
        ]
        if faststart { argList += ["-movflags", "+faststart"] }
        argList.append(out.path)
        // ★ 要进并发闭包的集合先拼完再绑成 let（工程里为这个栽过两次）
        let args = argList

        onStage("正在合并画面和声音…")
        let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var argv = args.map { strdup($0) }
            let c = HookFFmpeg(Int32(args.count), &argv)
            for p in argv { free(p) }
            return c
        }.value
        guard code == 0 else { throw Fail.ffmpeg(code) }

        // 体检：必须真的有画面轨。ffmpeg 退出码为 0 但内容不对的情况是见过的
        // （见 FFmpegConverter 里那段"退出码照样是 0，只是内容只剩三分之一"的记录）。
        let asset = AVURLAsset(url: out)
        let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !vTracks.isEmpty else { throw Fail.noVideoTrack }

        let attrs = try? fm.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size
    }

    /// 合并前的体积门槛：超过它就不做 faststart
    /// （挪索引要把整个文件重写一遍，几百 MB 的会白等很久）。
    static let faststartLimit: Int64 = 400 * 1024 * 1024

    static func shouldFaststart(videoBytes: Int64, audioBytes: Int64) -> Bool {
        videoBytes + audioBytes <= faststartLimit
    }
}
