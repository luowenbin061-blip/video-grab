import Foundation
import AVFoundation

// HookFFmpeg 由 app/Hook.m 实现（经桥接头暴露给 Swift）。
// 它进程内调起 FFmpeg CLI 的 main（FFmpeg_main 符号来自
// FFmpeg-iOS 包的 fftools 静态库），并用 setjmp/longjmp 兜住
// ffmpeg 内部的 exit() —— 返回 0 = 成功。

/// 成熟方案：进程内跑 FFmpeg CLI 把 TS **转成 MP4**。
/// （Stay / 亚瑟 / 各类下载器 App 内部用的都是这条引擎路线）
///
/// ★ 用词（用户 2026-09-28 指出界面用词不对）：
///   **这一步不是"转码"，是"换封装"** —— `-c copy` 只换容器、不重新编码。
///   界面上统一写「正在转成 MP4…」，不再出现「重封装 / 转码」这类容易误解的词。
///
/// 为什么用它：自写 demuxer 的换封装已被实测证明不可靠（反复出问题），
/// 而用户拿同一个 .ts 用其他转码软件「几秒钟就转好了」—— 说明文件是好的，
/// 该用成熟引擎。`-c copy` 的效果：
///   · 秒级完成（50MB 几秒钟）
///   · 音轨原样保留（ADTS→ASC、B 帧 ctts、LATM、HEVC 全由 FFmpeg 处理）
///   · `+faststart` 把 moov 挪到文件头 → 拖进度条秒响应
enum FFmpegConverter {

    /// 「大文件」的分界线：超过它就不开 `+faststart`。
    ///
    /// ★★ v1.0.138（用户报「转 MP4 时真卡死，文件越大卡得越久」）：
    ///   `+faststart` 的代价是**两遍 I/O** —— 先整份写完，再整体读一遍重写，
    ///   只为把索引（moov）挪到文件开头。文件越大这一遍越贵，接近翻倍。
    ///   而它换来的好处是「网络串流 / 边下边播时能秒开」—— **本地文件用不上**。
    ///   所以大文件上关掉它，拿回接近一半的 I/O 时间。
    ///   阈值 400MB 是**保守取值、不是量出来的最优解**：小文件照旧开（几乎不亏），
    ///   大文件（也正是最容易卡的那种）省掉整一遍。若哪天发现某处打不开，
    ///   把阈值调大（或让它恒为 true）就能退回原行为。
    static let faststartLimit: Int64 = 400 * 1024 * 1024

    /// 返回体检结果文本（写进过程记录）
    static func toMP4(ts: URL, mp4: URL,
                      onProgress: @escaping (Double, String) -> Void) async throws -> String {
        try? FileManager.default.removeItem(at: mp4)

        let inSize = size(of: ts)
        let useFaststart = inSize < faststartLimit

        onProgress(0, "正在转成 MP4…")

        // ── 进度：**盯着输出文件的大小**算百分比 ────────────────────────────
        // ★ v1.0.138 新增。以前这一步只上报「开始」和「结束」两次，
        //   中间那几个 G 的搬运过程界面上**一个像素都不动** —— 用户看到的就是"卡死"
        //   （用户原话「转码时界面是真卡死」，而"卡得久不久"跟文件大小成正比，
        //    正因为这一步耗时本来就 ∝ 文件大小）。
        //   `-c copy` 的输出**大小≈输入**，所以拿"输出已写多少 / 输入多大"当进度是站得住的。
        //   代价极低：每 500ms 读一次文件大小，不碰 ffmpeg 一行。
        let sizePoller = Task {
            while !Task.isCancelled {
                let out = size(of: mp4)
                if inSize > 0, out > 0 {
                    // 封顶 99%：最后那一下交给"体检输出文件"那步报 100%
                    let p = min(0.99, Double(out) / Double(inSize))
                    onProgress(p, "正在转成 MP4… \(Int(p * 100))%")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        var argList: [String] = [
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-y",
            "-i", ts.path,
            "-map", "0:v:0",      // 第一条视频流
            "-map", "0:a:0?",     // 第一条音频流（? = 没有也不报错）
            "-sn", "-dn",         // 字幕/数据流不要（mp4 装不下会整单失败）
            "-c", "copy",         // 只换容器，不重新编码 → 快 + 无损
        ]
        if useFaststart {
            argList += ["-movflags", "+faststart"]
        }
        argList.append(mp4.path)
        // ★★ 必须是 `let` 之后再进并发闭包。
        //   run #138 就挂在这：上面用 `var args` 拼参数，下面 `Task.detached` 里引用它 →
        //   `error: reference to captured var 'args' in concurrently-executing code`。
        //   （同一个坑 `Downloader.run` 里踩过一次，注释就写在那边；这次换了个文件又踩。）
        //   规矩：**要进并发闭包的集合，先在外面拼完再绑成 `let`。**
        let args = argList

        // ffmpeg 的 CLI main 是阻塞调用，丢到后台线程跑。
        // 返回 0 = 成功，非 0 = ffmpeg 自己的退出码。
        //
        // ★ 优先级**故意保持 userInitiated 不动**：改成 utility 看起来"更礼貌"，
        //   但会让转换在忙时明显变慢 —— 而"卡顿"到底是不是 CPU 抢出来的，
        //   目前没有实测证据（见 notes 里那份诊断）。没证据就不动性能相关的旋钮。
        let code = await Task.detached(priority: .userInitiated) { () -> Int32 in
            var argv = args.map { strdup($0) }
            let c = HookFFmpeg(Int32(args.count), &argv)
            // ★ v1.0.89：**必须释放**。
            //   以前是"一次转码泄一份、量级可忽略"（kewlbear 原实现的 FIXME 也留着）。
            //   但注意 ffmpeg 的 CLI main 是被 setjmp/longjmp 兜住的 ——
            //   ffmpeg 内部 exit() 会跳过它自己那套清理，全局状态只靠 resetFFmpeg()
            //   清三个计数。所以这里每一点泄漏都是**每次转码累积一次**，
            //   而且这条路上本来就容易越跑越胖。顺手清干净。
            for p in argv { free(p) }
            return c
        }.value
        sizePoller.cancel()

        guard code == 0 else {
            throw NSError(domain: "VideoGrab.FFmpeg", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey:
                                     String(format: "FFmpeg 退出码 %d（0 = 成功）", code)])
        }

        // ── 体检输出文件：轨、时长全写进过程记录 ──
        // 本地 MP4 的轨道查询是可靠的（HLS 才返回空数组）。
        let asset = AVURLAsset(url: mp4)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty else {
            throw NSError(domain: "VideoGrab.FFmpeg", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "输出里没有视频轨（这一步没成功）"])
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
        info += useFaststart ? " · 已优化开头" : " · 大文件跳过开头优化（省一遍读写）"
        let outSize = size(of: mp4)
        if outSize > 0 {
            info += String(format: " · 成品 %.1f MB", Double(outSize) / 1_048_576)
        }
        onProgress(1, info)
        return info
    }

    /// 文件字节数（不存在 / 读不到 = 0）
    private static func size(of url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }
}
