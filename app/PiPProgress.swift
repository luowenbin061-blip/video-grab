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

    /// 画中画小窗现在是开着还是关着（界面上的开关靠它显示状态）
    @Published private(set) var isRunning = false

    private let fw: CGFloat = 480          // 帧尺寸（16:9，够 PiP 小窗用）
    private let fh: CGFloat = 270

    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var frameIndex: Int64 = 0
    private var startAttempts = 0
    /// 我们这一份是否持有音频会话（画中画必须有个 active 的 playback 会话才可能就绪）
    private var audioHeld = false
    /// 正在爬启动梯子 —— 这期间的中间失败不甩给用户，等爬完一次性说清楚
    private var starting = false
    /// 系统给的最后一次失败原文（诊断用，含 localizedFailureReason）
    private var lastFailure: String?

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

    /// 由界面上那个开关调用 —— **必须在前台调用**（学 Stay：用户点确认后立刻起）。
    ///
    /// 为什么绝不能等 App 进了后台再起：后台事件会把 AVSampleBufferDisplayLayer
    /// 打成 failed，报 -11847「操作已中断」；此时往层里塞帧会被直接忽略，
    /// `isPictureInPicturePossible` 于是永远不为真。
    /// （实测报「等了 6 秒系统仍没就绪；层状态=失败，层报错=操作已中断」的就是这个。）
    func start() {
        lastError = nil
        guard isSupported else { lastError = "这台设备不支持画中画"; return }
        guard let c = controller else { lastError = "画中画控制器没建起来"; return }
        if c.isPictureInPictureActive { return }

        // 画中画「必须」有一个 active 的 playback 音频会话才会就绪。
        if !audioHeld {
            AppAudio.acquire()
            audioHeld = true
            if let e = AppAudio.lastError { lastError = e }
        }

        starting = true
        startAttempts = 0
        climb(c)
    }

    /// 先画一帧垫着。AVKit 拒绝给「刚建好、还从没显示过」的层启画中画，
    /// 所以 App 一开场就让它显示一次，别等用户点开关时才第一次画。
    func prime() {
        resetIfBroken()
        renderFrame()
    }

    /// 用户点开关关掉、或画中画小窗被系统收起时调用
    func stop() {
        starting = false
        timer?.invalidate()
        timer = nil
        isRunning = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        releaseAudio()
    }

    private func releaseAudio() {
        if audioHeld {
            AppAudio.release()
            audioHeld = false
        }
    }

    /// 层停在 failed 时先 flush 复位，否则后续 enqueue 会被系统直接忽略
    private func resetIfBroken() {
        if layer.status == .failed { layer.flushAndRemoveImage() }
    }

    /// 启动梯子。
    ///
    /// 为什么不能「possible 为真就调一次 start」：`isPictureInPicturePossible` 报的是
    /// **配置对不对**，不是**此刻能不能起**。AVKit 对「没真正在屏幕上显示过」的层会
    /// 直接拒绝启动 —— 报 AVKitErrorDomain -1001「Failed to start picture in picture」。
    /// 而「层什么时候才算显示好了」事先无从得知，所以按短梯子反复试，
    /// 而不是靠猜一个睡眠时长。顺带也把「确认框关闭动画」这段时间让过去。
    private func climb(_ c: AVPictureInPictureController) {
        if c.isPictureInPictureActive {
            starting = false
            return
        }
        startAttempts += 1
        guard startAttempts <= 10 else {
            starting = false
            let broken = layer.error.map { ($0 as NSError).code == AVError.operationInterrupted.rawValue } ?? false
            lastError = "画中画没能启动（试了 10 次，约 7 秒）"
                + (lastFailure.map { "；系统说：\($0)" } ?? "")
                + (broken ? "；画布层被后台事件打断过，请在前台重开" : "")
                + "（层状态=\(layerStatusText)，音频会话=\(AppAudio.describe())）"
            return
        }

        renderFrame()                     // 每次先保证层里真有帧（没显示过的层会被拒）
        c.startPictureInPicture()         // 起不来只会回调失败，不会崩

        let ladder: [Double] = [0.35, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.5, 2.0]
        let wait = ladder[min(startAttempts - 1, ladder.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.climb(c)
        }
    }

    /// 层的状态转成人看得懂的字（诊断画中画为什么起不来用）
    private var layerStatusText: String {
        switch layer.status {
        case .unknown: return "未知"
        case .rendering: return "渲染中"
        case .failed: return "失败"
        @unknown default: return "其它"
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

        // 层被打断过（后台事件、被别的 App 抢过）会停在 failed —— 此时塞帧会被忽略
        resetIfBroken()

        let w = Int(fw), h = Int(fh)
        var pb: CVPixelBuffer?
        // IOSurface 背衬是显示前提：AVSampleBufferDisplayLayer 显示的就是 IOSurface
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
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
        starting = false
        isRunning = true
        startTicking()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        releaseAudio()          // 小窗被关掉＝用户停用，把音频会话也让出去
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        // 失败原因要留痕：之前这个项目吃过「错误被静默吞掉」的亏
        isRunning = false
        let ns = error as NSError
        // 关键：真正的诊断在 localizedFailureReason 里（很多排查文章都漏了这个字段）
        lastFailure = "\(ns.domain) \(ns.code)：\(ns.localizedDescription)"
            + (ns.localizedFailureReason.map { " / \($0)" } ?? " / 无附加原因")
        // 还在爬梯子就不要把中间失败甩给用户 —— 等爬完再一次性说清楚
        if !starting {
            lastError = "画中画启动失败：\(lastFailure ?? "")"
        }
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
