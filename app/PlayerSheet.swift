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
    /// 图标字号。**按截图量的**：左上那排 ✕ 是 15pt、小窗图标约 20pt；我们 21pt 时
    /// 视觉约 19.5pt（跟小窗一样大，但它是两条张开的斜线，看着比小窗"大一圈"）。
    /// 用户要"再小一点、跟左边那两颗更协调" → 取 **18pt**（视觉约 16.6pt），
    /// 正好落在 ✕(15) 和小窗(20) 中间。
    private static let landscapeIconSize: CGFloat = 18
    /// 位置 = 图标【中心】到「安全区右边 / 下边」的距离（pt）。横竖屏各一组：
    /// 竖屏：中心距右 113、距下 53 ←→ 与系统的「隔空播放」同一行、在它左边（用户说 OK）
    private static let lsTrailingTall: CGFloat = 113
    private static let lsBottomTall: CGFloat = 53
    /// 横屏：在【左上角、系统"小窗播放"图标的右边】。数值是从截图量像素换算的
    /// （scale≈1.39；左上 ✕ 屏幕 55pt、小窗图标 107pt → 系统两颗中心间距 52pt）：
    /// 取「跟小窗同一间距」→ 我们的中心应在**屏幕坐标 158pt**（= 107 + 51）。
    /// 纵向跟系统那一行平齐 → 47pt。
    /// ★★ **这两个数是"屏幕坐标"，不是"安全区坐标"** —— 血的教训（v1.0.73 实测）：
    ///   系统的图标是按屏幕摆的，而 GeometryReader 在安全区里（横屏刘海那侧约 48pt）。
    ///   上一版我按"距安全区左 158"定位，落到屏幕上就成了 206pt → 跟小窗的间隔
    ///   变成 100pt（应该是 52），用户一眼看出"间隔太大"。
    ///   → position 那里减掉 windowSafeLead()（窗口真实的安全区宽度）换算回屏幕坐标。
    ///   （横向不需要避让刘海：横屏的顶部工具栏那一带本来就没有刘海。）
    private static let lsLeadingWide: CGFloat = 158
    private static let lsTopWide: CGFloat = 47

    /// 窗口左侧的安全区宽度（横屏时就是刘海那一侧）。**直接读窗口的真实值**，
    /// 不猜机型、也不写死数字 —— 换算"安全区坐标 ↔ 屏幕坐标"要用它。
    private static func windowSafeLead() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.safeAreaInsets.left ?? 0
    }

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
    /// 我们这两个控件要不要显示。**进来时不显示** —— 系统控制条一开始也是不显示的
    /// （用户实测：点播放时不应该冒出来，点屏幕才显示）。
    @State private var controlsVisible = false
    @State private var hideTask: Task<Void, Never>?
    /// 已经能读到系统控制条的状态了 → 显隐完全交给它（兜底逻辑让位）
    @State private var mirrorSystem = false
    @State private var sawSystemVisible = false
    @State private var sawSystemHidden = false
    /// 正在滑动（拖进度条 / 左右滑动调进度都算）
    @State private var dragActive = false
    /// **冻结系统读数**：从手指按下去、到松手后一小段，这段时间显隐只听我们自己的。
    /// 为什么必须有它（用户实测"右滑时一闪一闪"的根因）：手指一按下去，系统可能正
    /// 把控制条点亮（左右滑动 seek 就是），我们不冻就会先跟着亮一下、紧接着被滑动逻辑
    /// 收掉 —— 那一亮一灭就是他看到的闪。左滑不闪只是因为落手更快，窗口没被看见。
    @State private var frozen = false
    /// 解冻用的定时器
    @State private var settleTask: Task<Void, Never>?
    /// 转屏没成功时补一次的定时器
    @State private var orientationRetry: Task<Void, Never>?

    init(url: URL, title: String = "", pip: PiPProgress? = nil) {
        self.url = url
        self.title = title
        self.pip = pip
        _box = StateObject(wrappedValue: PlayerBox(url: url))
    }

    // MARK: - 控件显隐
    //
    // 目标：**完全跟系统控制条同步**（用户明确要求的那套：刚进播放器不显示、点屏幕才显示、
    // 点播放/暂停时保持、拖进度条时收起、没触摸后自己收）。这些状态公开接口一个都给不了，
    // 所以去读系统那个控制条视图的显隐来跟随它（只读，不碰它）。
    // **读不到就自动退回我们自己那套**（下面那些自己算的逻辑就是兜底，不会把人卡住）。
    // 全程不做淡出 —— 用户明确说"没有淡出这个概念"，一律立即显示 / 立即消失。

    /// 系统控制条报了它的显隐（来自 PlayerVC 里那个只读的观察）
    private func systemControls(_ visible: Bool) {
        sawSystemVisible = sawSystemVisible || visible
        sawSystemHidden = sawSystemHidden || !visible
        // 两种状态都亲眼见过，才承认这条读数可信 —— 免得读到个"永远显示"的假值，
        // 反而把按钮变成永远亮着（那就比现在更糟）
        guard sawSystemVisible, sawSystemHidden else { return }
        mirrorSystem = true
        // ★ 冻结期间（手指按着 + 刚离开那一小段）、以及滑动期间，系统读数一律
        //   不许改我们的显隐。用户实测要求：左右滑动调进度时按钮不该出现，
        //   而且此前会"一闪一闪" —— 根因就是开始滑的那一下我们跟着系统亮了一下。
        guard !dragActive, !frozen else { return }
        if controlsVisible != visible { controlsVisible = visible }
    }

    /// 松手后隔一小段再解冻 —— 躲开系统在 seek 松手瞬间的状态抖动。
    /// 解冻之后由系统读数接管（轮询 100ms 一次，最多 100ms 就同步上）。
    /// 0.2 秒是折中：再长"点空白处切换"会显得迟钝，再短躲不开系统那一下。
    private func settle(after seconds: Double = 0.2) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            frozen = false
        }
    }

    private func showNow() {
        hideTask?.cancel(); hideTask = nil
        controlsVisible = true
    }

    private func hideNow() {
        hideTask?.cancel(); hideTask = nil
        controlsVisible = false
    }

    /// 兜底逻辑：播放中亮着 3 秒后自己收；暂停不自动收
    private func startAutoHide() {
        hideTask?.cancel(); hideTask = nil
        guard !mirrorSystem, box.isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.controlsHideAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            controlsVisible = false                 // 立即消失
        }
    }

    /// 点了一下画面。
    /// ★★ **绝不本地切换显隐**（v1.0.75 修，用户实测报的 bug）：
    /// 这一指可能落在系统按钮上（播放/暂停、快进、音量、进度条…），也可能是点空白处
    /// 要切换控制条显隐 —— 从我们这一层**分不出来**（读不到系统按钮在哪）。
    /// 本地切了就会跟系统打架：**交替点播放/暂停时我们每次都反转一次**，
    /// 图标于是反复显示/消失（用户实测报告的就是这个；他自己分辨过：系统控制条是稳的）。
    /// 所以交回系统读数 —— 它该怎么收就怎么收（点完停一会儿 3 秒后收起），
    /// 点空白处它自己会切换，我们跟着就是。
    /// 唯一例外：**完全读不到系统状态**时（私有读法失效、退化到自算那套），
    /// 不给本地切换就等于点击彻底没反应 —— 所以那条路上保留自己切换。
    private func tapToggled() {
        frozen = true                                  // 这一指怎么处理交给系统，我们别插嘴
        guard !mirrorSystem else { return }             // 能读到系统状态 → 一律听它的
        if controlsVisible { hideNow() } else { showNow(); startAutoHide() }
    }

    /// 开始滑动：一律先收起来（拖进度条、左右滑动调进度都算）
    private func dragBegan() {
        dragActive = true
        hideNow()
    }

    /// 松手。**一律不主动点亮**，全部交回系统读数（用户已确认删掉"拖进度条"那个特例）：
    /// · 拖底部进度条：系统控制条本来就是显示的 → 解冻后 ≤100ms 我们自动跟着亮，
    ///   效果跟"立刻恢复"一样，但不用再猜"手指起点在不在进度条上"（误判就是闪的来源）
    /// · 左右滑动调进度：系统该隐藏就隐藏，我们不再自作主张
    private func dragEnded() {
        dragActive = false
        settle()
    }

    /// 手指碰了屏幕（不是点击、也不是拖动）
    private func noteTouch() {
        // ★ 一碰就先冻结读数 —— 这是"右滑一闪一闪"的正解：滑动开始时系统正把
        //   控制条点亮，不冻的话我们会先亮一下、再被滑动逻辑收掉。左滑之所以看着正常，
        //   只是落手更快、那个窗口没被看见而已（不能只按"左滑没事"就放过）。
        frozen = true
        settleTask?.cancel(); settleTask = nil
        // 读不到系统读数时（兜底模式）触摸仍然把自动隐藏的计时往后推
        guard !mirrorSystem, !dragActive, controlsVisible else { return }
        startAutoHide()
    }

    /// 转屏：按实际方向要，失败会重试（系统的转屏请求在弹层动画没结束时会被丢掉）
    private func requestOrientation(landscape: Bool) {
        ScreenOrientation.lock(landscape ? .landscape : .portrait)
        orientationRetry?.cancel()
        orientationRetry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
            let nowLandscape = scene?.interfaceOrientation.isLandscape ?? false
            if nowLandscape != landscape {
                ScreenOrientation.lock(landscape ? .landscape : .portrait)
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerVC(player: box.player, allowsPiP: pipEnabled,
                     onSystemExit: { dismiss() },
                     onTouch: { noteTouch() },
                     onTap: { tapToggled() },
                     onDragBegan: { dragBegan() },
                     onDragEnded: { dragEnded() },
                     onRelease: { settle() },
                     onSystemControls: { systemControls($0) })
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
                // ★ 图标样式和点击动作都按【实际方向】判断，不按我们记的那个状态 ——
                //   否则转屏请求被系统丢掉时（弹层动画没结束时就会），图标先变了、屏幕没转，
                //   用户就得再点一次才进横屏（实测反馈就是这个）。
                let wide = geo.size.width > geo.size.height
                Button {
                    requestOrientation(landscape: !wide)
                } label: {
                    Image(systemName: wide
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
                // 横屏：左上角、小窗图标右边（跟它同间距、同一水平线）
                //   ★ 减去窗口左侧的安全区宽度 → 换算成【屏幕坐标】（系统图标就是这个基准）
                // 竖屏：右下角、跟系统的「隔空播放」同一行（用户说 OK，没动）
                .position(x: wide ? Self.lsLeadingWide - Self.windowSafeLead()
                                  : geo.size.width - Self.lsTrailingTall,
                          y: wide ? Self.lsTopWide
                                  : geo.size.height - Self.lsBottomTall)
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
                if controlsVisible { startAutoHide() }    // 开播了：亮着的那 3 秒后收
            } else {
                hideTask?.cancel()                        // 暂停：撤掉自动隐藏，让它常显
                hideTask = nil
            }
        }
        .onDisappear {
            hideTask?.cancel()
            settleTask?.cancel()
            orientationRetry?.cancel()
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
    /// 只自动转一次，之后听用户的。**故意不记"我让它横了"这个状态** ——
    /// 图标和点击都按实际方向判断（转屏请求会被系统丢掉，记状态就会出现"点了没反应"的下一次点）
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
                // 横屏视频自动横过来（竖屏视频保持竖屏）。只自动一次，之后听用户的。
                // 注意：这里**不记状态** —— 图标和点击都按"实际方向"判断（见 PlayerSheet）
                if sz.width > sz.height { ScreenOrientation.landscape() }
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
    /// 刚越过拖动阈值（不是点击）→ 报"开始拖"
    var onDragBegan: () -> Void = {}
    /// 松手 → 报"拖完了"
    var onDragEnded: () -> Void = {}
    /// 手指离开（算点击、算滑动、长按后松手、被系统抢走）—— 一律触发一次。
    /// 用来"解冻"系统读数：长按不放再松手那条路既不报点击也不报滑动，
    /// 漏了它读数会被永久冻住（自己给自己挖的坑）。
    var onRelease: () -> Void = {}

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
        if !moved, hypot(p.x - startPoint.x, p.y - startPoint.y) > 12 {
            moved = true
            onDragBegan()            // 刚越过阈值 —— 报一次"开始滑了"
        }
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
        if moved {
            onDragEnded()            // 松手 —— 交回系统读数
        } else if let t = touches.first, t.timestamp - beganAt < 0.4 {
            onTap()
        }
        onRelease()                  // 统一解冻（上面两条分支没覆盖到的路径靠它）
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
    /// 开始拖东西（进度条那种）→ 先把控件收起来
    let onDragBegan: () -> Void
    /// 松手 → 交回系统读数
    let onDragEnded: () -> Void
    /// 手指离开（含长按松手、被系统抢走）→ 解冻读数
    let onRelease: () -> Void
    /// 读到系统控制条的显隐了（只读）→ 我们跟着它
    let onSystemControls: (Bool) -> Void

    final class Coord: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var onSystemExit: () -> Void = {}
        var onTouch: () -> Void = {}
        var onTap: () -> Void = {}
        var onDragBegan: () -> Void = {}
        var onDragEnded: () -> Void = {}
        var onRelease: () -> Void = {}
        var onSystemControls: (Bool) -> Void = { _ in }

        /// 只在"刚越过拖动阈值"那一下报一次
        private var dragReported = false
        private weak var playerView: UIView?
        private weak var controlsView: UIView?
        private var watch: Task<Void, Never>?
        /// 去抖用：上一次的原始读数（连续两次一致才认）
        private var pendingVisible: Bool?

        /// 开始盯系统控制条的显隐（**只读**，绝不改它）
        func startWatchingSystemControls(_ view: UIView) {
            playerView = view
            watch?.cancel()
            watch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    // 播放器关了就把这条循环断掉（self 是弱引用，不能一直空转）
                    guard let self else { return }
                    self.pollSystemControls()
                    try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms
                }
            }
        }

        private func pollSystemControls() {
            if controlsView == nil, let pv = playerView {
                controlsView = Self.findControlsView(pv, 0)
            }
            guard let v = controlsView else { return }
            // 阈值 0.8（不是 0.5）：系统控制条自己淡入淡出时会经过 0.5，采样落在那一带
            // 就会 true/false 反复 → 我们也跟着闪。
            let raw = (!v.isHidden && v.alpha > 0.8)
            // 连续两次读数一致才认（100ms 一次 → 最多晚 100ms）—— 过渡区间不再引起抖动。
            guard raw == pendingVisible else { pendingVisible = raw; return }
            // ★ 每次都报，不做"只在变化时报"的优化 —— 否则我们滑动时主动隐藏之后，
            //   系统读数若一直是 true（没变化），就没人来把它同步回来了，按钮会一直不亮。
            onSystemControls(raw)
        }

        /// 找系统那个"控制条"视图：类名里带 Controls、且有子视图的那一层。
        /// 找不到就返回 nil → 上层自动退回"自己算"的兜底逻辑。
        private static func findControlsView(_ v: UIView, _ depth: Int) -> UIView? {
            if depth > 8 { return nil }
            if String(describing: type(of: v)).contains("Controls"), !v.subviews.isEmpty {
                return v
            }
            for sub in v.subviews {
                if let f = findControlsView(sub, depth + 1) { return f }
            }
            return nil
        }

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
        touch.onDragBegan = { context.coordinator.onDragBegan() }
        touch.onDragEnded = { context.coordinator.onDragEnded() }
        touch.onRelease = { context.coordinator.onRelease() }
        context.coordinator.startWatchingSystemControls(vc.view)   // 只读地盯系统控制条
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
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onRelease = onRelease
        context.coordinator.onSystemControls = onSystemControls
        // 只在真的换了播放器时才替换，绝不无条件重建
        if vc.player !== player { vc.player = player }
        if vc.delegate !== context.coordinator { vc.delegate = context.coordinator }
        // 开关可能播放中途被改（用户去设置里拨），跟着变
        if vc.allowsPictureInPicturePlayback != allowsPiP {
            vc.allowsPictureInPicturePlayback = allowsPiP
        }
    }
}
