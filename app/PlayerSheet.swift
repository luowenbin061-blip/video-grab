import AVKit
import SwiftUI
import UIKit

/// App 内播放器。
///
/// ══ 之前白屏的原因 ══
///
/// 旧写法是 `VideoPlayer(player: AVPlayer(url: url))` —— **player 是在 body 里现造的**。
/// SwiftUI 只要重新求值一次 body（sheet 弹出、尺寸变化、任何 @State 变动都会触发），
/// 就会新建一个 AVPlayer 交给播放器。AVPlayerViewController 的 player 被反复替换，
/// 每一次加载都被下一次取消 —— 结果就是永远停在白屏。
///
/// 现在的做法：
///   1. AVPlayer 在 `PlayerBox` 里**只创建一次**（StateObject，跟着一次展示走）：
///      `updateUIViewController` 里也不再重建，只在真的换人时才换。
///   2. 用 AVPlayerViewController 本体（不用 SwiftUI 的 VideoPlayer 封装），
///      播放控制、全屏交给系统。
///   3. 盯 AVPlayerItem.status —— ready 才 play，failed / 卡住就把**具体错误和地址**
///      显示出来，不再是一块白屏。
struct PlayerSheet: View {
    let url: URL
    /// 视频名 —— **故意不显示**（用户要求：播放器上不要出现视频名）。
    /// 参数先留着：错误页/以后要用时不至于再改一遍调用方。
    let title: String
    /// 下载保活那个小窗（可以不传）。iOS 同时只允许一个小窗 ——
    /// 播放要占小窗时得让它先让位，否则两个抢同一个位子，结果不确定。
    let pip: PiPProgress?
    /// 播放小窗的总开关（设置页里那个）。关掉就完全不给小窗。
    @AppStorage("playerPiPEnabled") private var pipEnabled = true
    @Environment(\.dismiss) private var dismiss
    @StateObject private var box: PlayerBox
    /// 这次播放是否让下载保活窗让了位 —— 结束时要还回去
    @State private var pipHandedOver = false

    init(url: URL, title: String = "", pip: PiPProgress? = nil) {
        self.url = url
        self.title = title
        self.pip = pip
        _box = StateObject(wrappedValue: PlayerBox(url: url))
    }

    /// 播放器上的小圆按钮：白色图标 + 毛玻璃底 + 一圈细描边。
    /// 不用文字按钮 —— 系统那套控制条全是图标，混两个蓝字进去就显脏（用户反馈）。
    /// 38pt 是够手指点的尺寸（苹果建议 44，播放器上让一点、别有压迫感）。
    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)          // 关键：不然图标会被染成系统蓝
        .contentShape(Circle())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerVC(player: box.player, allowsPiP: pipEnabled)
                .ignoresSafeArea()

            if box.loading && box.error == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(1.2)
                    Text("正在加载…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            if let e = box.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("播放器起不来").font(.headline)
                    Text(e)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(url.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("重试") { box.retry() }
                            .buttonStyle(.borderedProminent)
                        Button("复制地址") {
                            UIPasteboard.general.string = url.absoluteString
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }

            // 关闭：左上角（跟"左上角是退出"的直觉一致）
            iconButton("xmark") { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
                .padding(.top, 10)

            // 横屏 / 竖屏：右下角（用户指定）。图标是"展开/收回"那一对，一眼看得懂。
            // 注意：系统的播放控制条里，右下角也有它自己的全屏按钮（只在控制条
            // 出现时才显示），两个会叠在一起 —— 用户已知，先按他说的放这儿。
            iconButton(box.forcedLandscape
                       ? "arrow.down.right.and.arrow.up.left"
                       : "arrow.up.left.and.arrow.down.right") {
                box.toggleOrientation()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 16)
            .padding(.bottom, 10)
        }
        // 铺满整屏、状态栏也不留 —— 用户要的是「点播放就是全屏」的观感。
        .statusBar(hidden: true)
        .onAppear {
            // 关键：不配音频会话的话，默认类别会被侧面静音拨片静掉 ——
            // 表现为「同一条视频导出去有声音、在 App 里没声音」。
            AppAudio.acquire()
            box.start()
            // 播放优先：iOS 同时只允许一个小窗，下载保活窗先让位。
            // 让位后下载照旧在跑（App 在前台不会被挂起），只是不显示那个小窗。
            if let pip, pip.isRunning {
                pipHandedOver = true
                pip.stop()
            }
        }
        .onDisappear {
            box.stop()
            ScreenOrientation.portrait()      // 退出播放器回竖屏，别把界面留在横着
            AppAudio.release()
            // 把刚才让位的下载保活窗还回去。
            // 此刻用户刚关掉播放器、App 一定在前台 —— 起画中画的前置条件正好满足。
            if pipHandedOver { pip?.start() }
        }
    }
}

/// 播放器的状态与生命周期。**只创建一次**，这是修掉白屏的关键。
///
/// 故意不加 `@MainActor`：所有 @Published 的写入都已经显式在主线程上做，
/// 而 View 的 init 里构造 StateObject 不受 actor 隔离约束 —— 加了反而会
/// 产生"从非隔离上下文调用主 actor 初始化器"的告警。
final class PlayerBox: ObservableObject {

    let player: AVPlayer
    private let item: AVPlayerItem
    @Published var error: String?
    @Published var loading = true
    /// 当前是不是我们强制横过来的（按钮文案据此变）
    @Published var forcedLandscape = false
    /// 只自动转一次，之后听用户的
    private var autoOriented = false

    private var failObs: NSObjectProtocol?
    private var stallObs: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        // NotificationCenter 的 block 是 @Sendable 的：直接在闭包里调实例方法没问题
        // （queue: .main 保证已在主线程），但**不能在里面再套一层并发闭包引用 weak self**，
        // 那会报 "reference to captured var 'self' in concurrently-executing code"。
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main) { [weak self] n in
            let msg = PlayerBox.message(from: n)
            self?.fail(msg)
        }

        stallObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main) { [weak self] _ in
            self?.beginStallWatch()
        }
    }

    deinit {
        if let f = failObs { NotificationCenter.default.removeObserver(f) }
        if let s = stallObs { NotificationCenter.default.removeObserver(s) }
        pollTask?.cancel()
        stallTask?.cancel()
    }

    func start() {
        player.play()
        startPolling()
    }

    func stop() {
        player.pause()
        pollTask?.cancel()
        stallTask?.cancel()
    }

    /// 用户点「横屏 / 竖屏」
    func toggleOrientation() {
        forcedLandscape.toggle()
        if forcedLandscape { ScreenOrientation.landscape() } else { ScreenOrientation.portrait() }
    }

    func retry() {
        error = nil
        loading = true
        player.seek(to: .zero)
        player.play()
        startPolling()
    }

    // MARK: - 状态跟踪

    /// 轮询 AVPlayerItem.status。
    ///
    /// 为什么不用 KVO：KVO 的 handler 会在任意线程回调，要往主线程跳就得在闭包里
    /// 再套一层并发闭包，而嵌套并发闭包引用 weak self 是**编译错误**。
    /// 轮询一样简单，还能顺带做「一直不 ready」的兜底。
    private func startPolling() {
        pollTask?.cancel()
        let target = self               // 绑成 let：嵌套并发闭包里引用 weak var 会编译不过
        pollTask = Task { @MainActor in
            for _ in 0..<600 {          // 最多盯 60 秒
                if target.checkOnce() { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if target.error == nil, target.loading {
                target.loading = false
                target.error = "等了 60 秒还是加载不出来（地址能连上但取不到数据）"
            }
        }
    }

    /// 返回 true 表示已经有结论（能播或已失败）
    private func checkOnce() -> Bool {
        switch item.status {
        case .readyToPlay:
            loading = false
            error = nil
            // 视频是横的（宽 > 高）→ 自动横过来；竖屏视频保持竖屏。
            // 只自动来一次，用户手动切过之后不再自作主张。
            let sz = item.presentationSize
            if !autoOriented, sz.width > 0, sz.height > 0 {
                autoOriented = true
                forcedLandscape = sz.width > sz.height
                if forcedLandscape { ScreenOrientation.landscape() }
            }
            player.play()
            return true
        case .failed:
            loading = false
            error = PlayerBox.describe(item.error) ?? "系统没能打开这个视频"
            return true
        default:
            return false
        }
    }

    private func fail(_ msg: String) {
        loading = false
        error = msg
    }

    /// 卡住不动（一直出不来帧）超过 8 秒也报出来 —— 白屏就是这么来的
    private func beginStallWatch() {
        guard error == nil else { return }
        stallTask?.cancel()
        let target = self
        stallTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if target.error == nil, target.loading {
                target.loading = false
                target.error = "加载卡住了（地址能连上但取不到数据）"
            }
        }
    }

    private static func message(from n: Notification) -> String {
        if let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            return describe(e) ?? "播放中断"
        }
        return "播放中断"
    }

    /// 把错误写得具体一点 —— 只显示"播放失败"没法判断是地址问题还是文件问题
    private static func describe(_ e: Error?) -> String? {
        guard let e else { return nil }
        let ns = e as NSError
        var s = ns.localizedDescription
        s += " [\(ns.domain)#\(ns.code)]"
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(u.localizedDescription) [\(u.domain)#\(u.code)]"
        }
        return s
    }
}

/// AVPlayerViewController 本体。
/// 不用 SwiftUI 的 VideoPlayer 封装 —— 那个在 sheet 里容易被反复重建，是白屏的主因。
private struct PlayerVC: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPiP: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        // 打开它：播放器上出现画中画按钮，App 进后台时系统也会把画面接进小窗。
        // 前提是 Info.plist 里有 UIBackgroundModes=audio（我们有）——
        // 小窗播放靠的就是那条后台模式。
        vc.allowsPictureInPicturePlayback = allowsPiP
        vc.updatesNowPlayingInfoCenter = false
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        // 只在真的换了播放器时才替换，绝不无条件重建
        if vc.player !== player { vc.player = player }
        // 开关可能播放中途被改（用户去设置里拨），跟着变
        if vc.allowsPictureInPicturePlayback != allowsPiP {
            vc.allowsPictureInPicturePlayback = allowsPiP
        }
    }
}
