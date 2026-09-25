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
    /// 图标字号。**按截图量的**：系统那排图标实测 26~27px（scale≈1.4 → 约 19~20pt），
    /// 我们 22pt 时是 28px（偏大）、18pt 时 22px（偏小）→ 21pt ≈ 26px 才对得上。
    private static let landscapeIconSize: CGFloat = 21
    /// 位置 = 图标【中心】到「安全区右边 / 下边」的距离（pt）。横竖屏各一组：
    /// 竖屏：中心距右 113、距下 53 ←→ 与系统的「隔空播放」同一行、在它左边
    /// 横屏：中心距右 93、距下 63 —— 按截图量出来的：要让"我们 → 显示器 → …"
    /// 三个图标**间距相等**（系统那两个之间是 60px≈43pt），并且同一水平线。
    private static let lsTrailingTall: CGFloat = 113
    private static let lsBottomTall: CGFloat = 53
    private static let lsTrailingWide: CGFloat = 93
    private static let lsBottomWide: CGFloat = 63

    /// 播放中、亮着没再被点，多久后自动隐藏（秒）。
    /// 3 秒是用户实测系统那套的间隔（原生逻辑：播放中点一下显示、再点一下隐藏、
    /// 没再点就 3 秒后隐藏；暂停时点开则常显不隐藏）。
    private static let controlsHideAfter: Double = 3

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

    // MARK: - 控件显隐（对齐系统那套逻辑）
    //
    // 规则（用户实测 iOS 原生控制条的行为）：
    //   · 播放中：点一下屏幕 → 立刻显示；再点一下 → 立刻隐藏
    //   · 显示后没再点 → 3 秒后自动隐藏
    //   · 暂停时点开 → 常显，不自动隐藏（视频没在播就不该自己溜走）

    /// 点了一下画面：亮着就收起，藏着就亮出来
    private func toggleControls() {
        if controlsVisible { hideControls() } else { showControls() }
    }

    /// 亮出来。播放中才安排 3 秒后自动隐藏；暂停时保持常显。
    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = nil
        guard box.isPlaying else { return }       // 没在播 → 不自动隐藏
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.controlsHideAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { controlsVisible = false }
        }
    }

    private func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
    }

    /// 手指碰了屏幕（不管是不是点击）：正亮着而且在播，就把自动隐藏再往后推 3 秒
    /// —— 拖进度条那类操作不该把控件拖没了
    private func noteTouch() {
        if controlsVisible, box.isPlaying { showControls() }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerVC(player: box.player, allowsPiP: pipEnabled,
                     onSystemExit: { dismiss() },
                     onTouch: { noteTouch() },
                     onTap: { toggleControls() })
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
                // ★ 永远生效，不跟着控制条淡出。
                //   理由：上一版系统控件整个不显示时，唯一的关闭入口没了，只能强杀 App。
                //   这块区域贴着系统那个 ✕，位置一样；代价是"控制条藏着时点到左上角"
                //   也会关掉播放器 —— 但比"关不掉"强得多。

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
            showControls()          // 一进来先亮着（此刻还没播，所以不会自动隐藏）
            // 播放优先：iOS 同时只允许一个小窗，下载保活窗先让位。
            // 让位后下载照旧在跑（App 在前台不会被挂起），只是不显示那个小窗。
            if let pip, pip.isRunning {
                pipHandedOver = true
                pip.stop()
            }
        }
        // 播放状态一变就跟着调整：开始播了 → 亮着的控件 3 秒后自己收；
        // 暂停了 → 撤掉自动隐藏，让它常显
        .onChange(of: box.isPlaying) { playing in
            if playing {
                if controlsVisible { showControls() }
            } else {
                hideTask?.cancel()
                hideTask = nil
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
    /// 当前在不在播 —— 界面靠它决定"要不要自动隐藏控件"（暂停时不隐藏）
    @Published var isPlaying = false
    private var stateTask: Task<Void, Never>?

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
        stateTask?.cancel()
    }

    /// 盯着"在不在播"。轮询而不是 KVO —— 理由和其他地方一样（KVO 回调不在主线程，
    /// 要往主线程跳就得在闭包里再套并发闭包，这条线踩过坑）。250ms 一次，几乎不要钱。
    private func startStateWatch() {
        stateTask?.cancel()
        let target = self               // 绑成 let：嵌套并发闭包里引用 weak var 会编译不过
        stateTask = Task { @MainActor in
            while !Task.isCancelled {
                let playing = (target.player.timeControlStatus == .playing)
                if target.isPlaying != playing { target.isPlaying = playing }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func start() {
        player.play()
        startPolling()
        startStateWatch()
    }

    func stop() {
        player.pause()
        pollTask?.cancel()
        stallTask?.cancel()
        stateTask?.cancel()
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
/// 只"看"触摸、**永不识别**的手指感应器。
///
/// ★ 上一版这里用的是 `UILongPressGestureRecognizer(minimumPressDuration ≈ 0.01)` —— 那是错的：
///   它会**抢先进入"已识别"状态**，把系统播放器自己那套手势（显示控制条、点按钮）压掉，
///   表现就是「系统控制条一个都不出来、视频关不掉，只能强杀 App」。
///   `cancelsTouchesInView = false` 只管"触摸还发不发到视图"，**管不了"识别竞争"**。
///   正确做法：自己永远不识别（touchesBegan 里立刻 failed），只借回调知道"有人碰了屏幕"，
///   这样对系统的识别器零影响。
final class TouchObserver: UIGestureRecognizer {
    /// 手指碰到屏幕（任何情况）都报一次 —— 用来"重置自动隐藏计时"
    var onTouch: () -> Void = {}
    /// 判断为"点了一下"（短、且几乎没移动）时报一次 —— 用来"切换控件显隐"
    var onTap: () -> Void = {}

    private var startPoint = CGPoint.zero
    private var beganAt: TimeInterval = 0
    private var moved = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let t = touches.first else { return }
        startPoint = t.location(in: view)
        beganAt = t.timestamp
        moved = false
        onTouch()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let t = touches.first else { return }
        let p = t.location(in: view)
        if hypot(p.x - startPoint.x, p.y - startPoint.y) > 12 { moved = true }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches)
    }

    /// 手指被系统播放器自己的手势抢走时也走这里 —— 能判成点击就照样报
    /// （系统那个"点击切换控制条"本来就认得出这种短按）
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        if let t = touches.first, !moved, t.timestamp - beganAt < 0.4 { onTap() }
        // ★ 全程不进入"已识别"状态：只在最后收尾成 failed，绝不跟系统的手势抢
        state = .failed
    }
}

private struct PlayerVC: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPiP: Bool
    /// 系统的 ✕ 若是「退出全屏」→ 顺手把播放器也关掉（第二道保险；
    /// 第一道是上面那块看不见的热区，它才是真正兜住"一定关得掉"的那道）
    let onSystemExit: () -> Void
    /// 播放器上有任何触摸 → 重置自动隐藏的计时
    let onTouch: () -> Void
    /// 播放器上"点了一下"（短按、几乎没移动）→ 切换控件显隐
    let onTap: () -> Void

    final class Coord: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var onSystemExit: () -> Void = {}
        var onTouch: () -> Void = {}
        var onTap: () -> Void = {}

        /// 挂在播放器视图上，只为"知道有人碰了屏幕"。两件事必须保证：
        /// ① cancelsTouchesInView = false —— 绝不能把触摸从系统控件手里吃掉
        /// ② minimumPressDuration 极小 —— 手指一碰就报，不用等按满
        /// 兜一层：挂到我们这边的识别器一律允许和系统播放器的手势**同时识别**。
        /// 上一版就是缺了这条（用了会抢先识别的长按识别器）才把系统控件压掉的，
        /// 所以显式写上；现在的 TouchObserver 自己永不识别，本来也不会抢。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
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
        // 只观察、永不识别 —— 对系统控件的手势零影响（上一版就是在这里踩的雷）
        let touch = TouchObserver(target: nil, action: nil)
        touch.onTouch = { context.coordinator.onTouch() }
        touch.onTap = { context.coordinator.onTap() }
        touch.cancelsTouchesInView = false
        touch.delaysTouchesBegan = false
        touch.delaysTouchesEnded = false
        touch.delegate = context.coordinator
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
        context.coordinator.onTap = onTap
        // 只在真的换了播放器时才替换，绝不无条件重建
        if vc.player !== player { vc.player = player }
        if vc.delegate !== context.coordinator { vc.delegate = context.coordinator }
        // 开关可能播放中途被改（用户去设置里拨），跟着变
        if vc.allowsPictureInPicturePlayback != allowsPiP {
            vc.allowsPictureInPicturePlayback = allowsPiP
        }
    }
}
