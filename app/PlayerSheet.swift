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
    // ── 横屏按钮：尺寸与位置（全部是从用户截图上量像素换算出来的，不是估的）──
    /// 图标字号。系统那排（隔空播放 / …）实测约 19~20pt；我们那个箭头是"长斜线"，
    /// 同样的字号看上去更胖，所以再收一档 —— 视觉上才等大。嫌小/大就改这一个数。
    private static let landscapeIconSize: CGFloat = 18
    /// 位置 = 图标【中心】到「安全区右边 / 下边」的距离（pt）。横竖屏各一组：
    /// 竖屏：中心距右 113、距下 53 ←→ 与系统的「隔空播放」同一行、在它左边
    /// 横屏：中心距右 102、距下 68
    private static let lsTrailingTall: CGFloat = 113
    private static let lsBottomTall: CGFloat = 53
    private static let lsTrailingWide: CGFloat = 102
    private static let lsBottomWide: CGFloat = 68

    /// 我们自己的按钮多久后淡出（秒）。
    /// 说明：AVKit 控制条的显隐时长**没有公开接口**（也查不到官方数值），
    /// 所以这里是"跟随触摸 + 自己计时"的近似值 —— 任何触摸都让两者一起出现，
    /// 静止这么久之后我们淡出。看着比系统的早/晚，改这一个数就能靠拢。
    private static let controlsHideAfter: Double = 4

    /// 下载保活那个小窗（可以不传）。iOS 同时只允许一个小窗 ——
    /// 播放要占小窗时得让它先让位，否则两个抢同一个位子，结果不确定。
    let pip: PiPProgress?
    /// 播放小窗的总开关（设置页里那个）。关掉就完全不给小窗。
    @AppStorage("playerPiPEnabled") private var pipEnabled = true
    @Environment(\.dismiss) private var dismiss
    @StateObject private var box: PlayerBox
    /// 这次播放是否让下载保活窗让了位 —— 结束时要还回去
    @State private var pipHandedOver = false
    /// 我们这两个控件要不要显示 —— 跟系统控制条一样：有触摸就出现，静一会儿就淡出
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    init(url: URL, title: String = "", pip: PiPProgress? = nil) {
        self.url = url
        self.title = title
        self.pip = pip
        _box = StateObject(wrappedValue: PlayerBox(url: url))
    }

    /// 有触摸：立刻显示 + 重置淡出计时
    private func pokeControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.controlsHideAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { controlsVisible = false }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerVC(player: box.player, allowsPiP: pipEnabled,
                     onSystemExit: { dismiss() },
                     onTouch: { pokeControls() })
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

            // ── 关闭：视觉上交给系统左上角那个 ✕（用户要求撤掉我们自己的）──
            // 但这里留了一个**完全看不见的点击热区**，点它就关掉播放器。
            // 为什么必须留：系统那个 ✕ 很可能是「退出全屏」而不是「关闭播放器」，
            // 真那样的话撤掉我们的按钮就出不去了。热区跟它对齐（左上、安全区内侧），
            // 你点那个 ✕ 实际打到的是我们这块 —— 所以它一定关得掉。
            Color.clear
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 4)
                .padding(.top, 2)
                // 跟系统那个 ✕ 一起显隐（系统那个也是随控制条消失的）——
                // 藏着的时候不能吃触摸，否则点画面会莫名其妙把播放器关掉
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            // ── 横屏 / 竖屏：紧挨系统那排「隔空播放」的左边、同一行 ──
            // 为什么用 GeometryReader 自己算位置：系统的控件是按"安全区"摆的，
            // 横竖屏的安全区不一样（竖屏左右为 0、横屏刘海那侧约 46），
            // 用固定 padding 会让横屏偏掉一截。这里按实测的两组数分别定位。
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height
                Button {
                    box.toggleOrientation()
                } label: {
                    Image(systemName: box.forcedLandscape
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: Self.landscapeIconSize))
                        .foregroundStyle(.white)
                        // 极淡阴影：亮画面上也看得见；黑底上完全看不出来，不影响"无底座"观感
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .frame(width: 48, height: 48)     // 触控区比图标大，好按
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: geo.size.width - (wide ? Self.lsTrailingWide : Self.lsTrailingTall),
                          y: geo.size.height - (wide ? Self.lsBottomWide : Self.lsBottomTall))
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
        }
        // 铺满整屏、状态栏也不留 —— 用户要的是「点播放就是全屏」的观感。
        .statusBar(hidden: true)
        .onAppear {
            // 关键：不配音频会话的话，默认类别会被侧面静音拨片静掉 ——
            // 表现为「同一条视频导出去有声音、在 App 里没声音」。
            AppAudio.acquire()
            box.start()
            pokeControls()          // 一进来先亮一会儿，再跟系统一起淡出
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
    /// 系统的 ✕ 若是「退出全屏」→ 顺手把播放器也关掉（第二道保险；
    /// 第一道是上面那块看不见的热区，它才是真正兜住"一定关得掉"的那道）
    let onSystemExit: () -> Void
    /// 播放器上有任何触摸 → 通知界面「把控件亮起来、并重置淡出计时」
    let onTouch: () -> Void

    final class Coord: NSObject, AVPlayerViewControllerDelegate {
        var onSystemExit: () -> Void = {}
        var onTouch: () -> Void = {}

        /// 挂在播放器视图上，只为"知道有人碰了屏幕"。两件事必须保证：
        /// ① cancelsTouchesInView = false —— 绝不能把触摸从系统控件手里吃掉
        /// ② minimumPressDuration 极小 —— 手指一碰就报，不用等按满
        @objc func touched() { onTouch() }
        /// 退出全屏时不问原因，直接关播放器 —— 用户点这个 ✕ 就是想退出
        func playerViewController(
            _ vc: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            onSystemExit()
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.delegate = context.coordinator
        // 只读触摸、不吃触摸：系统那套控件（暂停/进度/画中画）一切照旧
        let touch = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coord.touched))
        touch.minimumPressDuration = 0.01
        touch.cancelsTouchesInView = false
        touch.delaysTouchesBegan = false
        touch.delaysTouchesEnded = false
        vc.view.addGestureRecognizer(touch)
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
        context.coordinator.onSystemExit = onSystemExit
        context.coordinator.onTouch = onTouch
        // 只在真的换了播放器时才替换，绝不无条件重建
        if vc.player !== player { vc.player = player }
        if vc.delegate !== context.coordinator { vc.delegate = context.coordinator }
        // 开关可能播放中途被改（用户去设置里拨），跟着变
        if vc.allowsPictureInPicturePlayback != allowsPiP {
            vc.allowsPictureInPicturePlayback = allowsPiP
        }
    }
}
