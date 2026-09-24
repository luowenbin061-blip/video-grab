import AVFoundation
import AVKit
import Combine
import CoreMedia
import UIKit

/// 后台保活：把下载进度**画进「画中画」小窗**（Stay 用的就是这一招）。
///
/// 原理：sample-buffer PiP —— 不做任何视频解码/播放，我们自己往
/// `AVSampleBufferDisplayLayer` 里塞进度帧；iOS 把这条渲染管道当成
/// 「正在播放的媒体」，于是在 App 进后台后继续给它运行时间。
/// 好处：不像「无声音频保活」那样要骗系统（那会被静音检测杀掉），
/// 而且用户能直接看到进度。
///
/// 注意（硬件/系统边界，实测才知道）：
///  · 用户从多任务里上滑杀掉 App，PiP 也会一起死 —— 这不是万能药。
///  · 需要 Info.plist 里声明 UIBackgroundModes = audio（PiP 归这条背景模式）。
final class PiPProgress: NSObject, ObservableObject {

    /// 画帧要用的数据，由外部（DownloadCenter）提供
    struct Snapshot {
        var title = "视频抓取"
        var detail = ""
        var progress: Double = 0      // 0...1
        var activeCount = 0
    }

    /// 画每一帧时回调取最新状态
    var provider: (() -> Snapshot)?

    /// 启动失败原因 —— 绝不吞掉（这是本项目的老教训）
    @Published private(set) var lastError: String?

    private let fw: CGFloat = 480          // 帧尺寸（16:9，够 PiP 小窗用）
    private let fh: CGFloat = 270

    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var frameIndex: Int64 = 0
    private var startAttempts = 0

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        // 回前台不自动弹；后台起不起由我们自己判断（有任务才起）
        c.canStartPictureInPictureAutomaticallyFromInline = false
        controller = c
    }

    /// 给界面挂载用（layer 要在一个视图层级里，PiP 才稳）
    var displayLayer: AVSampleBufferDisplayLayer { layer }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // MARK: - 起 / 停

    /// App 进后台、且有任务在跑时调用
    func start() {
        guard isSupported else { lastError = "这台设备不支持画中画"; return }
        guard let c = controller else { lastError = "画中画控制器没建起来"; return }
        if c.isPictureInPictureActive { return }

        renderFrame()                    // 先入一帧，否则 PiP 起不来
        startAttempts = 0
        tryStart(c)
    }

    /// 回前台、或没有活跃任务时调用
    func stop() {
        timer?.invalidate()
        timer = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
    }

    /// `isPictureInPicturePossible` 是异步就绪的（要先有帧），所以重试几次
    private func tryStart(_ c: AVPictureInPictureController) {
        if c.isPictureInPictureActive { return }         // 已经起来了，不再重试
        if c.isPictureInPicturePossible {
            c.startPictureInPicture()
            return
        }
        startAttempts += 1
        guard startAttempts <= 8 else {
            lastError = "画中画没能启动（系统一直没就绪）"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.renderFrame()
            self.tryStart(c)
        }
    }

    // MARK: - 画帧

    /// 每秒画一帧（PiP 里看起来像"在动"，也顺便让系统知道我们活着）
    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
    }

    private func renderFrame() {
        let snap = provider?() ?? Snapshot()

        let w = Int(fw), h = Int(fh)
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        UIGraphicsPushContext(ctx)
        draw(snap, in: ctx)
        UIGraphicsPopContext()

        guard let sb = makeSampleBuffer(from: buffer) else { return }
        layer.enqueue(sb)
    }

    private func draw(_ snap: Snapshot, in ctx: CGContext) {
        let w = fw, h = fh

        // 背景
        ctx.setFillColor(UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 标题（顶行）
        let title = snap.activeCount > 1 ? "\(snap.title) 等 \(snap.activeCount) 个任务" : snap.title
        drawText(title,
                 rect: CGRect(x: 20, y: 22, width: w - 40, height: 26),
                 font: .systemFont(ofSize: 17, weight: .semibold),
                 color: .white, align: .left)

        // 大号百分比（居中）
        let pct = Int((max(0, min(1, snap.progress)) * 100).rounded())
        drawText("\(pct)%",
                 rect: CGRect(x: 0, y: h / 2 - 34, width: w, height: 56),
                 font: .monospacedDigitSystemFont(ofSize: 46, weight: .bold),
                 color: UIColor(red: 0.42, green: 0.72, blue: 1, alpha: 1),
                 align: .center)

        // 进度条
        let barW = w - 80
        let barRect = CGRect(x: 40, y: h - 86, width: barW, height: 10)
        ctx.setFillColor(UIColor(white: 1, alpha: 0.14).cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        let filled = CGFloat(max(0, min(1, snap.progress))) * barW
        if filled > 1 {
            let fillRect = CGRect(x: 40, y: h - 86, width: filled, height: 10)
            ctx.setFillColor(UIColor(red: 0.17, green: 0.42, blue: 1, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }

        // 状态文字（底行）
        drawText(snap.detail,
                 rect: CGRect(x: 20, y: h - 50, width: w - 40, height: 22),
                 font: .systemFont(ofSize: 13),
                 color: UIColor(white: 0.72, alpha: 1),
                 align: .left)
    }

    private enum Align { case left, center }

    private func drawText(_ text: String, rect: CGRect, font: UIFont,
                          color: UIColor, align: Align) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align == .center ? .center : .left

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func makeSampleBuffer(from buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr, let f = format else { return nil }

        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid)

        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: f,
            sampleTiming: &timing,
            sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

// MARK: - PiP 事件

extension PiPProgress: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        lastError = nil
        startTicking()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        timer?.invalidate()
        timer = nil
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        // 失败原因要留痕：之前这个项目吃过「错误被静默吞掉」的亏
        lastError = "画中画启动失败：\(error.localizedDescription)"
    }
}

// MARK: - PiP 里的播放语义（我们不播视频，给个"一直在播"的假象即可）

extension PiPProgress: AVPictureInPictureSampleBufferPlaybackDelegate {

    /// PiP 窗口上的播放/暂停按钮 —— 下载没法暂停，忽略即可
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}

    /// 告诉系统"可播放区间"。给一个足够长的区间，避免时间条跳到末尾。
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    /// PiP 窗口上快进/快退：没有可跳的时间轴，直接回完成
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
