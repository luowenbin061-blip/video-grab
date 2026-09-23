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

        // ── 手段 1：自己重封装（主路，离线、不重新编码、快）────────────
        onProgress(0, "正在重封装成 MP4…")
        do {
            let stats = try await TSRemuxer.toMP4(ts: ts, mp4: mp4,
                                                 onProgress: { p, msg in
                                                     onProgress(p, msg)
                                                 })
            log.append(Attempt(name: "重封装 TS→MP4", ok: true, detail: stats.note))
            return (true, log)
        } catch {
            log.append(Attempt(name: "重封装 TS→MP4", ok: false, detail: brief(error)))
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

        log.append(Attempt(name: "结论", ok: false, detail: "重封装和导出会话都没成"))
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
