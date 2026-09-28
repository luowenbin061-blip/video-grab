import AVFoundation
import Foundation

/// 把下载好的视频转成 MP4。
///
/// ══ 结论先写在这（都是查证过的事实，不是推测）══
///
/// **iOS 的 AVFoundation 不能用来把 HLS/TS 转成 MP4。** 四条路全试过，全死：
///   1. 本地 .ts 文件 → AVFoundation 直接不认。
///      Apple 开发者论坛官方回复："TS files are not and will not be supported
///      on iOS. You must use fMP4." 错误发生在建轨道那一刻。
///   2. 本地 .m3u8 文件 → 也不行。HLS 必须来自 http/https，
///      用 file:// 会报 CoreMediaErrorDomain -12865 / 12881。
///   3. 本机 HTTP 上的 m3u8 → **AVPlayer 能播，但 AVAsset 拿不到轨道**。
///      `loadTracks(withMediaType: .video)` 永远返回空数组（这是 HLS 的既定行为）。
///      连带 AVAssetReader 报 -11800、AVMutableComposition 插入报 -12780。
///   4. AVAssetExportSession → 建立在同样拿不到轨道的基础上，同样走不通。
///
/// **所以只能自己重封装**：解 MPEG-TS、把 H.264 / AAC 抠出来、
/// 交给 AVAssetWriter 写进 MP4 容器（见 TSRemuxer.swift）。
/// 等价于 `ffmpeg -i in.ts -c copy out.mp4`，只是不带 FFmpeg。
///
/// 下面按顺序试，每一步成败都记进日志显示到界面上。
enum Exporter {

    /// 一次尝试的记录，直接显示到界面上
    struct Attempt {
        let name: String
        let ok: Bool
        let detail: String
        var line: String { "\(ok ? "✓" : "✗") \(name)：\(detail)" }
    }

    /// 主入口
    /// - Parameters:
    ///   - ts: 拼好的本地 .ts 文件（重封装的输入）
    ///   - hls: 本机 HTTP 上的 m3u8 地址（备用手段用；可能为 nil）
    ///   - remote: 原始远端 m3u8（备用手段用）
    static func toMP4(ts: URL,
                      hls: URL?,
                      remote: URL?,
                      mp4: URL,
                      onProgress: @escaping (Double, String) -> Void) async -> (ok: Bool, log: [Attempt]) {

        var log: [Attempt] = []
        try? FileManager.default.removeItem(at: mp4)

        // ── 手段 0：FFmpeg 引擎（成熟方案，Stay / 各类下载器同款路线）──────
        // 用户实测：同一个 .ts 别的转码软件几秒转完 → 文件没问题，该用成熟引擎。
        // `-c copy` 只换容器：秒级 + 音轨保留 + 各类编码全覆盖。
        // ★ v1.0.138：界面用词统一成「转成 MP4」（用户指出「重封装」这个说法不对）
        onProgress(0, "正在转成 MP4…")
        do {
            let detail = try await FFmpegConverter.toMP4(input: ts, inputBytes: 0,
                                                         mp4: mp4, onProgress: onProgress)
            log.append(Attempt(name: "转成 MP4（FFmpeg）", ok: true, detail: detail))
            return (true, log)
        } catch {
            log.append(Attempt(name: "转成 MP4（FFmpeg）", ok: false, detail: brief(error)))
        }

        // ── 手段 1：自己写的换封装（历史兜底，H.264 明文流可用）────────────
        //   注意它比 FFmpeg 慢一个数量级，而且 writer 不就绪时会干等 ——
        //   界面上会显示「正在转成 MP4… XMB/YMB」，能看出它在动。
        onProgress(0, "正在转成 MP4…（备用方式）")
        do {
            let stats = try await TSRemuxer.toMP4(ts: ts, mp4: mp4,
                                                 onProgress: { p, msg in
                                                     onProgress(p, msg)
                                                 })
            // ★★ v1.0.141：**这条路也要过体检**。
            //   它就是历史上"产出垃圾却报成功"的那个惯犯（自研换封装只认 TS，
            //   拿到解密失败的数据也会硬认几百帧然后说成功 —— 真实事故里成品 2MB / 输入 212.7MB）。
            //   所以：产出体积跟输入差太多的，**当失败处理**，继续往下试，别报成功。
            try checkSize(out: mp4, input: ts)
            log.append(Attempt(name: "转成 MP4（备用方式）", ok: true, detail: stats.note))
            return (true, log)
        } catch {
            log.append(Attempt(name: "转成 MP4（备用方式）", ok: false, detail: brief(error)))
        }

        // ── 手段 2：交给系统的导出会话（留个后手；下面会先说明它为什么基本没戏）
        var candidates: [URL] = []
        if let hls { candidates.append(hls) }
        if let remote { candidates.append(remote) }

        for url in candidates {
            if Task.isCancelled { return (false, log) }
            let asset = AVURLAsset(url: url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                log.append(Attempt(name: "导出会话 \(short(url))", ok: false,
                                   detail: "读不到：\(brief(error))"))
                continue
            }
            guard !tracks.isEmpty else {
                log.append(Attempt(name: "导出会话 \(short(url))", ok: false,
                                   detail: "系统对这个 HLS 不提供轨道（AVPlayer 能播，但导出用不了这条路）"))
                continue
            }
            do {
                try await exportSession(asset: asset, mp4: mp4, onProgress: onProgress)
                log.append(Attempt(name: "导出会话 \(short(url))", ok: true, detail: "成功"))
                return (true, log)
            } catch {
                log.append(Attempt(name: "导出会话 \(short(url))", ok: false, detail: brief(error)))
            }
        }

        log.append(Attempt(name: "结论", ok: false, detail: "转成 MP4 的两种方式都没成"))
        return (false, log)
    }

    // MARK: - 备用手段

    private static func exportSession(asset: AVAsset, mp4: URL,
                                      onProgress: @escaping (Double, String) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoGrab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "系统不给建导出会话"])
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            let t = session.supportedFileTypes.map { $0.rawValue }.joined(separator: ",")
            throw NSError(domain: "VideoGrab", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "这个预设不能输出 mp4：\(t)"])
        }
        try? FileManager.default.removeItem(at: mp4)
        session.outputURL = mp4
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false

        let poller = Task {
            while !Task.isCancelled {
                let p = Double(session.progress)
                onProgress(p, "系统导出中… \(Int(p * 100))%")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        switch session.status {
        case .completed: return
        case .cancelled:
            throw NSError(domain: "VideoGrab", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "已取消"])
        default:
            throw session.error ?? NSError(domain: "VideoGrab", code: 4,
                                           userInfo: [NSLocalizedDescriptionKey: "未知原因"])
        }
    }

    // MARK: - 小工具

    private static func short(_ u: URL) -> String {
        if u.isFileURL { return u.lastPathComponent }
        return "\(u.host ?? "?")/\(u.lastPathComponent)"
    }

    /// ★★ v1.0.141：**成品体检** —— 产出体积必须跟输入在一个量级。
    ///
    /// 依据是实测，不是"保险起见"：钥匙用错时 ffmpeg 的**退出码照样是 0**（只是内容剩 1/3），
    /// 而自研换封装更狠 —— 完全解不开的数据它也能产出 1% 大小、然后报成功。
    /// 真实事故：成品 2.0 MB / 输入 212.7 MB，一路报"成功"，随后原始数据被删。
    /// 所以"没报错"根本不等于"转对了"：体积差得离谱（超出 50%~150%）一律当失败。
    private static func checkSize(out: URL, input: URL) throws {
        let o = fileSize(out)
        let i = fileSize(input)
        guard i > 0, o > 0 else {
            throw NSError(domain: "VideoGrab.Exporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "产出是空的"])
        }
        let ratio = Double(o) / Double(i)
        guard ratio >= 0.5, ratio <= 1.5 else {
            throw NSError(domain: "VideoGrab.Exporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: String(
                            format: "产出大小不对劲：输入 %.1f MB、产出 %.1f MB（只有 %.0f%%）—— 这次不算成功",
                            Double(i) / 1_048_576, Double(o) / 1_048_576, ratio * 100)])
        }
    }

    private static func fileSize(_ u: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }

    /// 把错误写得具体一点 —— 只显示一句「无法打开」是没法定位的
    private static func brief(_ e: Error) -> String {
        let ns = e as NSError
        var s = ns.localizedDescription
        s += " [\(ns.domain)#\(ns.code)]"
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(u.localizedDescription) [\(u.domain)#\(u.code)]"
        }
        if s.count > 240 { s = String(s.prefix(240)) + "…" }
        return s
    }
}
