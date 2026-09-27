import AVFoundation
import SwiftUI
import UIKit

/// 所有下载任务的容器。**记录会落盘**，重启程序后还在。
@MainActor
final class DownloadCenter: ObservableObject {
    @Published var jobs: [DownloadJob] = []

    init() {
        // 启动时把上次的记录读回来（文件还在的就还能播、还能存相册）
        jobs = JobStore.load().map { rec in
            let job = DownloadJob(record: rec)
            job.onUpdate = { [weak self] in self?.save() }
            return job
        }
    }

    @discardableResult
    func add(title: String, url: String,
             referrer: String = "", ua: String = "", cookie: String = "",
             kind: DownloadJob.MediaKind? = nil) -> DownloadJob {
        let job = DownloadJob(title: title, sourceURL: url,
                              referrer: referrer, ua: ua, cookie: cookie,
                              kind: kind)
        job.onUpdate = { [weak self] in self?.save() }
        jobs.insert(job, at: 0)
        save()
        job.start()
        return job
    }

    /// 工具箱「导入视频」：相册/文件选来的视频进这里。
    /// 立刻建卡（用户看得到「正在导入」），复制/探测/转码在后台走。
    func addImported(_ files: [SavedFile]) {
        guard !files.isEmpty else { return }
        for f in files {
            let job = DownloadJob.makeImported(originalName: f.originalName)
            job.onUpdate = { [weak self] in self?.save() }
            jobs.insert(job, at: 0)
            let src = f.url
            Task { await job.runImport(from: src) }
        }
        save()
    }

    /// 删除任务时把文件也删掉（用户明确要删，就别留垃圾）
    func remove(at offsets: IndexSet) {
        for i in offsets { jobs[i].cancel() }
        let going = offsets.map { jobs[$0] }
        jobs.remove(atOffsets: offsets)
        for j in going { j.deleteFiles() }
        save()
    }

    func remove(_ job: DownloadJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        job.deleteFiles()
        save()
    }

    func save() {
        JobStore.save(jobs.map { $0.snapshot() })
    }

    var activeCount: Int { jobs.filter { $0.isActive }.count }
    var usedSpace: Int64 { JobStore.totalSize() }

    // MARK: - 后台保活（画中画进度窗）

    /// 把进度画进画中画小窗，让 App 进后台也继续跑（Stay 用的同一招）
    let pip = PiPProgress()

    /// 这个小窗是「开共享」连带起的吗？
    /// 只记连带起的 —— 用户自己手动开的那个，关共享时不许替他收掉。
    private var pipByShare = false

    /// 局域网共享开着没有（给按钮上色用）
    @Published var lanOn = false

    /// 开始共享：同一 Wi-Fi 下的电脑用浏览器就能拿文件。成功返回可访问地址。
    func startSharing() -> URL? {
        guard LocalHTTPServer.shared.enableLAN(root: JobStore.dir) else { return nil }
        lanOn = true
        preparePiP()

        // ★ 共享要真做到「切走了电脑也能连」，就得靠这个小窗把进程保活 ——
        //   所以开共享直接连带起小窗。此刻一定在前台，正好是起画中画唯一靠谱的时机
        //   （进了后台再起必失败：画布层已被后台事件打成 -11847）。
        //   只记「是我连带起的」，用户自己开的那个不记账。
        let wasRunning = pip.isRunning
        pip.start()
        if !wasRunning { pipByShare = true }

        return LocalHTTPServer.shared.lanURL
    }

    func stopSharing() {
        LocalHTTPServer.shared.disableLAN()
        lanOn = false

        // 关共享就把「连带起的小窗」收回去 —— 否则它白占一个窗、还一直抢着音频通道。
        // 两个前提缺一不可：① 是共享连带起的（用户手动开的不动）
        //                   ② 没有下载在跑（那种情况这窗是给下载保活用的，不能收）
        if pipByShare && activeCount == 0 {
            pip.stop()
            pipByShare = false
        }
    }

    /// 进后台前调用：把"进度从哪来"告诉 PiP
    func preparePiP() {
        // ★ v1.0.104：用户自己划掉小窗 → 保活没了 → 共享在后台也就失效了。
        //   与其让开关显示"开着"骗人，不如跟着关掉。
        //   挂在这里是因为它每次 start 之前都会被调用；重复赋值无害。
        pip.onUserClosed = { [weak self] in
            Task { @MainActor in
                guard let self, self.lanOn else { return }
                self.stopSharing()
            }
        }
        pip.prime()          // 先让层显示一次（AVKit 拒绝给「从没显示过」的层起画中画）
        pip.provider = { [weak self] in
            guard let self else { return PiPProgress.Snapshot() }
            let act = self.jobs.filter { $0.isActive }
            let total = act.reduce(0) { $0 + $1.total }
            let done = act.reduce(0) { $0 + $1.done }
            let first = act.first
            // 没有下载任务时小窗也得有像样的画面（开关可能正开着）
            if act.isEmpty {
                return self.lanOn
                    ? PiPProgress.Snapshot(title: "局域网共享中",
                                           detail: "电脑可在同一 Wi-Fi 下下载",
                                           progress: 0, activeCount: 0)
                    : PiPProgress.Snapshot(title: "后台保活中",
                                           detail: "有下载任务时会显示进度",
                                           progress: 0, activeCount: 0)
            }
            return PiPProgress.Snapshot(
                title: first?.title ?? "视频抓取",
                detail: first?.phase ?? "",
                progress: total > 0 ? Double(done) / Double(total) : 0,
                activeCount: act.count)
        }
    }
}

/// 画中画的宿主视图**不再由 SwiftUI 承载** —— 见 PiPProgress.attachToWindow()：
/// 自己把层加到 keyWindow 上，确保 layer.window 一定有值（AVKit 靠它解析 UIScene）。

/// 画中画起不来时把原因显示出来 —— 静静失败是这个项目的老毛病
struct PiPErrorBanner: View {
    @ObservedObject var pip: PiPProgress

    var body: some View {
        if let e = pip.lastError {
            Text(e)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)      // 绝不挡住任何按钮
        }
    }
}

struct ContentView: View {

    @StateObject private var model = BrowserModel()
    @StateObject private var downloads = DownloadCenter()
    @StateObject private var store = BookmarkStore()      // 收藏 + 历史
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPanel = false
    /// 「长按诊断」开关的镜像 —— 开关一关，屏幕上的诊断条立刻消失
    @AppStorage("lpDebug") private var lpDebugOn = false
    /// 「嗅探按钮常驻屏幕」开关（默认关）。关着时右下角那个圆按钮不显示 ——
    /// 它原来一直压在页面右下角（视频站常把倍速/设置放那儿）。
    /// **后台嗅探跟这个按钮没有关系**，收起来照旧嗅探。
    @AppStorage("sniffButtonResident") private var sniffResident = false
    @State private var showDownloads = false
    @State private var showShare = false
    @State private var showPiPAsk = false
    @State private var showMenu = false        // 底部功能卡片是否展开
    // 「说明」现在挂在设置页里，外面不再单独弹 —— 所以 showHelp 这个状态去掉了
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var showToolbox = false
    @State private var showTabs = false        // 多窗口管理卡片
    @State private var input = ""
    /// ★ v1.0.118：长按菜单里点「选择清晰度」→ 拿着那条视频的地址弹挑档卡片
    ///   （嗅探面板那条路本来就能挑档，用户要的是长按这条路也能）
    @State private var pickQuality: LongPressMenuInfo?
    /// ★ v1.0.119 首页快捷入口（单例：存档 + 图标缓存都在它手里）
    @ObservedObject private var homeStore = HomeStore.shared
    /// ★ v1.0.119 系统分享面板：要分享的东西（当前网址 / 下载好的文件 / 截出来的长图）
    /// ★ v1.0.124：一次要分享的东西可能有好几件（导出 PDF + 转出的图片）
    ///   原来是单个 URL，现在换成容器；分享网址 / 分享下载好的文件仍是一件的写法。
    @State private var shareBundle: ShareBundle?
    /// 地址栏是否正在被编辑 —— 正在打字时，页面导航不能覆盖他输入的内容
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // ★ v1.0.82：原来这里有一条横向文字标签条（开 2 个以上才出现）。
            //   已经换成 Safari 式的整屏缩略图网格（功能卡片 →「标签页」），
            //   那条横条跟它重复、而且名字挤在一起认不出谁是谁 → 删掉。
            Divider()

            ZStack(alignment: .bottomTrailing) {
                BrowserView(model: model)
                    // 切标签时整体重建 → 挂上新标签的 WebView。
                    // 少了这个 .id，SwiftUI 会复用旧视图，画面还是上一个标签的。
                    .id(model.currentTabIndex)
                    .ignoresSafeArea(edges: .bottom)

                // ★ v1.0.119 首页：新标签（地址还空着）时，用快捷入口盖住那片空白。
                //   打开任何网页后 showHomePage 立刻变 false → 自动让位，不用手动关。
                if model.showHomePage {
                    HomePageView(store: homeStore,
                                 onOpenURL: { model.load($0) },
                                 onFeature: { handleHomeFeature($0) })
                }

                // 「打不开这个网页」→ 整页盖一层（对齐 Safari：告诉你原因 + 给个重试）。
                // 只对**主文档**加载失败显示；点停止 / 页面自己跳转那种"取消"已经在
                // 模型里滤掉了，不会莫名其妙弹出来。
                //
                // 这里原来是个转圈（加载时显示）：跟地址栏下面那根进度条干同一件事，
                // 而且正好压在页面顶部挡内容 —— 已经有进度条了，删掉。
                if let err = model.loadError {
                    PageErrorView(info: err,
                                  onRetry: { model.retry() },
                                  onTrust: err.isCertificate ? { model.trustAndReload() } : nil)
                }

                if sniffResident {
                Button {
                    showPanel = true
                    model.forceScan()
                } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        if !model.items.isEmpty {
                            Text("\(model.items.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 16, y: -16)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .shadow(radius: 6, y: 3)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 20)
                }   // sniffResident（关掉就不占屏幕；入口在「功能」卡片和「工具箱」里）
            }

            Divider()
            PiPErrorBanner(pip: downloads.pip)
                .padding(.horizontal, 8)
            progressLine
            bottomBar
        }
        .overlay(alignment: .top) { toastView }
        // 诊断条：放在顶部（原来在底部，正好压着视频的画面区）。只在诊断开关打开时出现
        .overlay(alignment: .top) { lpDebugBanner }
        // 长按视频的菜单（自绘，照截图：预览卡 + 标题行 + Download 行）
        .overlay {
            if let info = model.lpMenu {
                LongPressMenuView(info: info,
                                  onDownload: { model.downloadFromLongPressMenu() },
                                  // ★ v1.0.118：先收起菜单，再把挑档卡片抬起来 ——
                                  //   两张卡片同时在屏幕上会看着像卡住（overlay 的淡出要 0.12s）
                                  onPickQuality: {
                                      model.closeLongPressMenu()
                                      let m = info
                                      Task { @MainActor in
                                          try? await Task.sleep(nanoseconds: 160_000_000)
                                          pickQuality = m
                                      }
                                  },
                                  onClose: { model.closeLongPressMenu() })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.lpMenu)
        // ★ v1.0.118：长按 → 选择清晰度（选完立刻开始下载，跟嗅探面板那条路不同）
        .sheet(item: $pickQuality) { m in
            VariantPickerSheet(model: model,
                               url: m.url,
                               referrer: m.referrer, ua: m.ua, cookie: m.cookie) { v in
                downloads.add(title: m.title.isEmpty ? "Download" : m.title,
                              url: v?.url.absoluteString ?? m.url,
                              referrer: m.referrer,
                              ua: m.ua,
                              cookie: m.cookie,
                              kind: .video)
                model.showToast(v == nil ? "已加入下载（自动选档）" : "已加入下载")
            }
        }
        // ★ v1.0.119：系统分享面板（当前网页 / 拼好的长图 / 下载好的文件都走它）
        .sheet(item: $shareBundle) { b in
            ActivityView(items: b.items)
        }
        // ★ v1.0.122：PDF 导好了 → 立刻抬分享面板（存文件 / 发微信 / 存相册都从这里走）
        //   v1.0.124：选了"顺带转图片"时这里会带两份（PDF + JPG）
        .onChange(of: model.pagePDFResult) { list in
            guard let list, !list.isEmpty else { return }
            // ★ 图片排前面：有些 App（微信这类分享扩展）只接第一个 item ——
            //   用户选"PDF + 图片"图的往往是"能直接在聊天里看到的那张图"，
            //   而 PDF 依然在分享面板里（想发文件就选「存储到文件」）。
            let imgs = list.filter { $0.pathExtension.lowercased() == "jpg" }
            let rest = list.filter { $0.pathExtension.lowercased() != "jpg" }
            shareBundle = ShareBundle(imgs + rest)
            model.pagePDFResult = nil
        }
        // 长按诊断（设置里打开才出现）：显示这一步卡在哪，12 秒自己消失
        // 功能卡片：点底栏「≡」调出；点空白处收起，选完一项也收起。
        .overlay(alignment: .bottom) {
            if showMenu {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.05)
                        .ignoresSafeArea()
                        .onTapGesture { showMenu = false }
                    funcMenuCard
                        .padding(.horizontal, 12)
                        .padding(.bottom, 62)      // 浮在底栏之上
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showMenu)
        // （旧版这里是「下载这个视频？」的确认条 —— 已由长按菜单取代，见 LongPressMenuView）
        .alert("通过画中画保活后台下载", isPresented: $showPiPAsk) {
            Button("取消", role: .cancel) {}
            Button("好的") { downloads.pip.start() }
        } message: {
            Text("开启后会立刻出现一个画中画小窗，里面的进度就是下载进度。这样切到别的 App 或锁屏，下载都继续跑。随时关掉小窗即可停用。\n\n开着「共享给电脑」时也靠它保活 —— 那种情况开共享会自动起，不用在这里点。")
        }
        .sheet(isPresented: $showPanel) {
            SniffPanel(model: model, downloads: downloads, isPresented: $showPanel)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadList(center: downloads, isPresented: $showDownloads)
        }
        .sheet(isPresented: $showShare) { LanShareView(downloads: downloads) }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(store: store, isPresented: $showBookmarks) { url in
                input = url
                model.load(url)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, downloads: downloads, store: store,
                         isPresented: $showSettings)
        }
        .sheet(isPresented: $showToolbox) {
            ToolboxView(model: model, center: downloads, store: store,
                        isPresented: $showToolbox,
                        onOpenSniff: {
                            showToolbox = false
                            showPanel = true
                        })
        }
        // 标签页网格：Safari 那个是**全屏**盖上来，不是半屏卡片 → 用 fullScreenCover
        .fullScreenCover(isPresented: $showTabs) {
            TabGridView(model: model, isPresented: $showTabs)
        }
        // （这里原来挂了一条：网页层 900ms 兜底 → 自动弹嗅探面板。已删 ——
        //   长按只弹下载菜单，嗅探面板只由右下角按钮/底栏入口打开。）
        // 历史记录不再挂在「监听 address 变化」上 —— 有个新问题：
        // 切换标签也会让 address 变，那样每切一次窗口就虚增一次「访问次数」。
        // 改成挂在「页面真的加载完成」上，见下面 onAppear 里的 model.onPageFinished。
        .onChange(of: scenePhase) { ph in
            // 进后台/被打断前把记录落盘 —— 不然被系统杀掉就丢
            if ph != .active {
                downloads.save()
                // ★ 标签存档也要立刻写：后台随时可能被系统杀掉，等不了那 1.2 秒的节流。
                //   写了它，下次打开 App 标签和组才在。
                model.saveNow()
            }
            // 进后台且有任务在跑（或开着局域网共享）→ 起画中画保活
            if ph == .background {
                // 故意不再自动起画中画：进了后台才起的话，画布层已经被后台事件
                // 打成 failed（-11847「操作已中断」），必失败。改由前台那个开关负责。
                downloads.preparePiP()
            } else if ph == .active {
                // 画中画是用户自己开的开关，回前台不主动关掉；
                // 只有本来就闲着的时候，才把音频会话让出去。
                if !downloads.pip.isRunning { downloads.pip.stop() }
            }
        }
        // ★ v1.0.79（用户报的「顶部网址居然是固定的」）：
        //   地址栏绑的是本地 input，而 input 原来**只在 onAppear 同步一次** ——
        //   打开 App 时取一次 model.address，之后页面怎么跳它都不动了。
        //   现在 model.address 一变就跟着更新；而 model.address 由 KVO(url) +
        //   didCommit + 前端路由共同驱动（见 BrowserModel），所以点站内链接、
        //   换 hash、前端路由跳页，地址栏都会立刻跟上。
        //   唯一例外：**用户正在地址栏里打字时不能覆盖他**（用焦点判断）。
        .onChange(of: model.address) { addr in
            guard !urlFocused, !addr.isEmpty, input != addr else { return }
            input = addr
        }
        .onAppear {
            input = model.address
            downloads.preparePiP()
            // 历史只记「真的加载完成的、你正在看的」那一页
            // （同一地址由 store 合并，不会把列表刷成一堆重复项；
            //   about:blank 之类由 store 自己挡掉）
            model.onPageFinished = { url, title in
                store.record(url: url, title: title)
            }
            // 系统长按菜单里的「Download」被点 → 真正开始下载。
            // 请求上下文复用嗅探结果同一条（防盗链站的分片要带 Referer/Cookie）。
            model.onDownloadRequest = { u in
                let hit = model.items.first { $0.url == u }
                downloads.add(title: model.pageTitle.isEmpty ? "Download" : model.pageTitle,
                              url: u,
                              referrer: hit?.referrer ?? "",
                              ua: hit?.ua ?? "",
                              cookie: hit?.cookie ?? "",
                              kind: .video)
                model.showToast("已加入下载")
            }
            // ★ v1.0.106：长按下载 —— 上下文**由长按自己带回来**（探测时从页面直接取的），
            //   不再依赖「嗅探结果里恰巧有同一条」。自动嗅探默认关之后，
            //   那条路基本拿不到东西 → Referer/Cookie 全空 → 防盗链站必然失败。
            model.onLongPressDownload = { m in
                downloads.add(title: m.title.isEmpty ? "Download" : m.title,
                              url: m.url,
                              referrer: m.referrer,
                              ua: m.ua,
                              cookie: m.cookie,
                              kind: .video)
                model.showToast("已加入下载")
            }
            // ★ v1.0.112：**网页自己触发的文件下载**（点页面的下载按钮 / 附件链接 / `download` 属性）。
            //   以前这类请求在 WKWebView 里等于"什么都不发生"（它不实现下载）；
            //   现在接进下载中心：进度、暂停、分类、存文件夹全都复用，最后进「下载页 → 文件」。
            model.onFileDownload = { r in
                let ext = (r.name as NSString).pathExtension
                downloads.add(title: r.name.isEmpty ? "下载的文件" : r.name,
                              url: r.url,
                              referrer: r.referrer,
                              ua: r.ua,
                              cookie: r.cookie,
                              kind: DownloadJob.kind(fromExtension: ext) ?? .doc)
            }
        }
    }

    // MARK: - 顶部（只有这一行：后退 / 前进 / 地址栏 / 前往）
    // 原来「后退 前进 刷新」挤在底部工具栏里，三条工具栏 + 一排图标按钮堆在一起，
    // 功能看着重叠。现在顶上一行只管「去哪儿」，其余全部收到下面。

    // MARK: - 顶部（只有地址栏这一行）
    // 后退/前进挪到底栏去了 —— 参考图里导航就在下面，顶上一行只负责「去哪儿」。

    private var topBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextField("输入网址，或打开一个视频页", text: $input)
                    .focused($urlFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.system(size: 14))
                    .onSubmit { model.load(input) }
                    .submitLabel(.go)

                if !input.isEmpty {
                    Button {
                        input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空地址")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))

            Button("前往") { model.load(input) }
                .font(.system(size: 14, weight: .medium))
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
        // 加载进度条：贴在地址栏**正下方**（对齐 Safari 的位置）
        .overlay(alignment: .bottom) { pageProgressBar }
    }

    /// 页面加载进度条（v1.0.79）。
    /// 数据是 WebView 自带的 estimatedProgress（KVO 实时推进，见 BrowserModel）——
    /// 观感对齐 Safari：细线贴着地址栏下沿、从左走到右，走满后收起。
    @ViewBuilder private var pageProgressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Color.clear
                if model.progressActive {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(1, g.size.width * model.progress))
                }
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 0.18), value: model.progress)
        .allowsHitTesting(false)
    }

    // MARK: - 底部栏（‹ › ≡ ⬇ ⟳）
    // 「≡」是那张功能卡片的入口 —— 功能不常驻页面，点开才出现。
    // 底栏只放「浏览时随时要用」的几个动作。

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("chevron.left", "后退", enabled: model.canGoBack) { model.goBack() }
            barButton("chevron.right", "前进", enabled: model.canGoForward) { model.goForward() }
            // ★ 中间这颗是主入口 —— 图标放大到 24pt（原来 19pt，用户嫌小）
            barButton("line.3.horizontal", "功能", size: 24, active: showMenu) { showMenu.toggle() }
            barButton("arrow.down.circle", "下载管理", badge: downloads.activeCount) {
                showDownloads = true
            }
            // 加载中变「停止」（对齐 Safari：同一个位置，✕ 停下）
            if model.isLoading {
                barButton("xmark", "停止") { model.stop() }
            } else {
                barButton("arrow.clockwise", "刷新") { model.reload() }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground))
    }

    /// 底栏按钮：五等分、44pt 高（够手指点）
    private func barButton(_ icon: String, _ label: String,
                           size: CGFloat = 19,
                           enabled: Bool = true, active: Bool = false,
                           badge: Int = 0,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: size))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Color.red, in: Capsule())
                        // 徽标位置跟着图标大小走 —— 图标放大了它才不会压在图标上
                        .offset(x: size * 0.58, y: -size * 0.37)
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    // MARK: - 功能卡片（点底栏「≡」调出）
    // 8 个入口都收在这里，页面上不常驻。
    // 顺序按参考图：收藏/历史 · 收藏网址 · 下载管理 · 设置 / 工具箱 · 复制URL · 多窗口 · 刷新

    private var funcMenuCard: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                menuCell("clock.arrow.circlepath", "收藏/历史") { showBookmarks = true }
                menuCell("bookmark", "收藏网址") { toggleBookmark() }
                menuCell("arrow.down.circle", "下载管理", badge: downloads.activeCount) {
                    showDownloads = true
                }
                menuCell("gearshape", "设置") { showSettings = true }
            }
            HStack(spacing: 0) {
                menuCell("wrench.and.screwdriver", "工具箱") { showToolbox = true }
                menuCell("link", "复制URL") { copyCurrentURL() }
                // ★ v1.0.119：系统分享面板（发给微信 / 存到别处）
                menuCell("square.and.arrow.up", "分享") { shareCurrentPage() }
                // 徽标改成一直都显示 —— 只有一个标签时也让你知道开着一个
                // （点开就是 Safari 式网格：缩略图 + ✕ + 底部新建/完成）
                menuCell("square.on.square", "标签页",
                         badge: model.tabCount) { showTabs = true }
                // 这里原来是「刷新」——底栏已经有一个了，换成嗅探结果的入口
                menuCell("antenna.radiowaves.left.and.right", "嗅探结果",
                         badge: model.items.count) { showPanel = true }
            }

            Divider().padding(.horizontal, 10)

            // PIP / 共享是「开关」不是「功能」，所以放卡片底部单独一行 ——
            // 留在页面上就又是「固定按钮」了。
            HStack(spacing: 8) {
                downloadStatus
                Spacer(minLength: 4)
                pill(downloads.pip.isRunning ? "pip.fill" : "pip",
                     "PIP 保活", on: downloads.pip.isRunning) {
                    if downloads.pip.isRunning {
                        downloads.pip.stop()
                    } else {
                        showPiPAsk = true          // 先问一句，再趁前台立刻起（学 Stay）
                    }
                }
                pill(downloads.lanOn ? "wifi.circle.fill" : "wifi",
                     "共享给电脑", on: downloads.lanOn) { showShare = true }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
    }

    /// 卡片里的一格。
    /// - soon: 本轮还没做的功能 —— 画成灰的、点了说明白，别让按钮看着能用却不动。
    private func menuCell(_ icon: String, _ label: String,
                          soon: Bool = false, badge: Int = 0,
                          action: @escaping () -> Void = {}) -> some View {
        Button {
            showMenu = false                       // 选完就收起
            if soon {
                model.showToast("「\(label)」下一批加进来")
            } else {
                action()
            }
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Color.red, in: Capsule())
                            .offset(x: 12, y: -8)
                    }
                }
                Text(label)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(soon ? Color.secondary.opacity(0.5) : Color.primary)
        .accessibilityLabel(label)
        .accessibilityHint(soon ? "下一批开放" : "")
    }

    /// 复制当前页地址（不是地址栏里正在输入的半截内容）
    /// 用 model.address：它在每次加载完成时被同步成真实页面地址；
    /// 走 webView.url 的话这个文件还得 import WebKit，没必要。
    private func copyCurrentURL() {
        let s = model.address
        guard !s.isEmpty, s != "about:blank" else {
            model.showToast("还没打开网页")
            return
        }
        model.copy(s)          // 已有实现：写剪贴板 + 弹提示
    }

    /// ★ v1.0.119：分享当前网页 —— 走**系统分享面板**（发给微信 / 存到文件 / AirDrop 都用它）
    private func shareCurrentPage() {
        guard let s = model.currentURL, let u = URL(string: s) else {
            model.showToast("还没打开网页")
            return
        }
        shareBundle = ShareBundle([u])
    }

    /// ★ v1.0.119：首页上的功能格子 → 接到各自动作。
    /// 跟底栏「≡」卡片里那套**完全一致** —— 同一个功能只有一份实现，首页只是多一个入口。
    private func handleHomeFeature(_ f: HomeFeature) {
        switch f {
        case .sniff:       showPanel = true
        case .downloads:   showDownloads = true
        case .bookmarks:   showBookmarks = true
        case .toolbox:     showToolbox = true
        case .settings:    showSettings = true
        case .tabs:        showTabs = true
        case .copyURL:     copyCurrentURL()
        case .desktopMode: model.toggleDesktopUA()
        case .noImage:     model.toggleNoImage()
            case .pagePDF:     model.exportPagePDF()
            case .share:       shareCurrentPage()
        }
    }

    /// 收藏 / 取消收藏当前页（同一个入口，看当前状态决定）
    private func toggleBookmark() {
        guard let page = model.currentURL else {
            model.showToast("还没打开网页")
            return
        }
        let marked = store.toggleMark(url: page, title: model.pageTitle)
        model.showToast(marked ? "已收藏" : "已取消收藏")
    }

    // MARK: - 底栏顶上那条 2pt 进度线（有活跃下载才出现）
    // 它只是「状态」，不是按钮 —— 所以不占一行、也不需要点。

    @ViewBuilder
    private var progressLine: some View {
        if downloads.activeCount > 0 {
            if activeTotal > 0 {
                ProgressView(value: Double(activeDone) / Double(activeTotal))
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            } else {
                // 分片下完了、还没开始转码时 total 是 0 —— 用不确定态动画，别显示「0%」
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
        }
    }

    private var activeJobs: [DownloadJob] { downloads.jobs.filter { $0.isActive } }
    private var activeTotal: Int { activeJobs.reduce(0) { $0 + $1.total } }
    private var activeDone: Int { activeJobs.reduce(0) { $0 + $1.done } }

    /// 卡片里的下载状态文字（进度条已经画在底栏上了，这里只报数）
    @ViewBuilder
    private var downloadStatus: some View {
        if activeJobs.isEmpty {
            Text("没有进行中的下载")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if activeTotal > 0 {
            Text("下载中 \(Int(Double(activeDone) / Double(activeTotal) * 100))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        } else {
            Text(activeJobs.first?.phase ?? "处理中")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }

    /// 卡片里的小胶囊开关：开着是实色，关着是浅底
    private func pill(_ icon: String, _ label: String,
                      on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(on ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "已开启" : "已关闭")
    }

    // MARK: - Toast

    /// 长按诊断条 —— 只在「长按诊断」开关打开、且刚长按过时出现：
    /// 8 秒自动消失，点一下立刻关。放在顶部是为了不压住视频画面。
    /// 开关一关，这里立刻什么都不显示（@AppStorage 会触发刷新）。
    @ViewBuilder private var lpDebugBanner: some View {
        if lpDebugOn, let t = model.lpDebug {
            Text(t)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.78),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.top, 116)
                .onTapGesture { model.dismissLPDebug() }
                .transition(.opacity)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = model.toast {
            Text(t)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.82), in: Capsule())
                .padding(.top, 70)
                .transition(.opacity)
                // 点一下就能收掉（尤其证书那条现在会停 8 秒）
                .onTapGesture { model.toast = nil }
        }
    }
}

// MARK: - 嗅探结果面板

struct SniffPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @Binding var isPresented: Bool
    @State private var picked: SniffItem?
    /// ★ v1.0.115 挑清晰度：要打开"挑清晰度"卡片的那一条（懒解析的入口）
    @State private var variantItem: SniffItem?
    /// ★ v1.0.127 预览：要"先看一眼"的那一条（点了播放器盖上来）
    @State private var previewItem: SniffItem?
    @State private var showAll = false
    /// ★ v1.0.109：0 = 视频，1 = 图片（两个独立列表）
    @State private var tab = 0

    /// ★ v1.0.110：视图页的两段 —— 视频在前、图片在后。
    ///   图片走的是**独立通道**（独立 60 条上限），所以两段互不挤占。
    private var videoGroups: [SniffGroup] {
        model.groups.filter { ["hls", "file", "dash", "blob"].contains($0.best.kind) }
    }
    /// 「其他」页：音频 / 文档 / HLS 分片（分片是"线索"不是成品，也归这儿）
    private var otherGroups: [SniffGroup] {
        model.groups.filter { ["audio", "doc", "segment"].contains($0.best.kind) }
    }
    private var visibleVideoGroups: [SniffGroup] {
        showAll ? videoGroups : Array(videoGroups.prefix(8))
    }
    private var visibleImageGroups: [SniffGroup] {
        showAll ? model.imageGroups : Array(model.imageGroups.prefix(8))
    }
    private var visibleOtherGroups: [SniffGroup] {
        showAll ? otherGroups : Array(otherGroups.prefix(8))
    }

    var body: some View {
        NavigationView {
            Group {
                // ★ v1.0.110：视图页 = 视频段 + 图片段（下面是原来的 List，未动结构）
                if tab == 1 {
                    otherArea
                } else if videoGroups.isEmpty && model.imageGroups.isEmpty {
                    emptyState
                } else {
                    List {
                        if model.groups.contains(where: { $0.best.playing }) {
                            Section {
                                Label("标「正在播放」的就是当前视频 —— 下载它就对了",
                                      systemImage: "play.circle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                        } else if let h = model.hint {
                            Section {
                                Label(h, systemImage: "info.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.mseSeen {
                            Section {
                                Label("这个页面用了 MSE（分片式加载），地址可能只以 blob: 形式出现",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                        }
                        if !videoGroups.isEmpty {
                            Section {
                                ForEach(visibleVideoGroups) { g in
                                    row(g.best, variants: g.total)
                                }
                                if videoGroups.count > visibleVideoGroups.count {
                                    Button {
                                        showAll = true
                                    } label: {
                                        Text("显示全部 \(videoGroups.count) 组（还有 \(videoGroups.count - visibleVideoGroups.count) 组没列出）")
                                            .font(.system(size: 13))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(videoGroups.count == model.items.count
                                         ? "视频 · 共 \(videoGroups.count) 条 · 点一条开始下载"
                                         : "视频 · 共 \(videoGroups.count) 个（合并了 \(model.items.count) 条近似地址）")
                                    Spacer()
                                    if !model.updatedText.isEmpty {
                                        Text("更新于 \(model.updatedText)")
                                    }
                                }
                            }
                        }
                        // ★ v1.0.110：图片段 —— 带缩略图，一眼能认出要下哪张
                        if !model.imageGroups.isEmpty {
                            Section {
                                ForEach(visibleImageGroups) { g in
                                    row(g.best, variants: g.total, thumb: true)
                                }
                                if model.imageGroups.count > visibleImageGroups.count {
                                    Button {
                                        showAll = true
                                    } label: {
                                        Text("显示全部 \(model.imageGroups.count) 张（还有 \(model.imageGroups.count - visibleImageGroups.count) 张没列出）")
                                            .font(.system(size: 13))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            } header: {
                                Text("图片 · 共 \(model.imageGroups.count) 张 · 点一张开始下载")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("嗅探结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // ★ v1.0.110：改成「视图 / 其他」—— 视图里是视频+图片（能看的），
                    //   其他里是音频/文档/分片。用户要的分类方式。
                    Picker("", selection: $tab) {
                        Text("视图").tag(0)
                        Text("其他").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 168)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.forceScan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                        Button { model.clearItems() } label: { Label("清空", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        // ★ v1.0.104：打开面板就扫一次。自动扫描默认关了 —— 那么「用户打开
        //   这个面板」本身就是「现在需要嗅探」的信号，代他扫一下最省事。
        .onAppear {
            model.scanQuietly()
            // ★ v1.0.110：打开面板就顺手扫一次图片 —— 图片段现在就在「视图」页里，
            //   不打开的话那一段永远是空的（以前图片是独立页签，点它才扫）。
            model.loadImages()
        }
        // 切到「其他」就不用收图片了（省跨进程开销），切回来再打开
        .onChange(of: tab) { t in
            if t == 0 { model.loadImages() } else { model.stopImages() }
        }
        .safeAreaInset(edge: .bottom) {
            if let p = picked {
                startBar(p)
            } else {
                Text("点某一条 → 这里会出现「开始下载」")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
            }
        }
        // ★ v1.0.115 挑清晰度：点小标签才弹这张卡片，而且**点开的那一刻**才去读清单
        // ★ v1.0.127：嗅探结果的"下载前预览" —— 先看一眼是不是正片，别下完才发现不对。
        //   走同一套播放器，但**带上 Referer/UA/Cookie**（防盗链站不带就 403）。
        //   键固定成 "preview"：**不污染真实任务的续看键**（各任务的进度是按任务 id 记的）。
        .fullScreenCover(item: $previewItem) { it in
            if let u = URL(string: it.url) {
                PlayerSheet(url: u,
                            title: it.fileName.isEmpty ? "预览" : it.fileName,
                            key: "preview",
                            headers: previewHeaders(it))
            }
        }
        .sheet(item: $variantItem) { it in
            VariantPickerSheet(model: model, url: it.url,
                               referrer: it.referrer, ua: it.ua, cookie: it.cookie)
        }
    }

    /// 「其他」页（v1.0.110）：音频 / 文档 / HLS 分片。
    @ViewBuilder
    private var otherArea: some View {
        if otherGroups.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("没有音频、文档或分片")
                        .font(.headline)
                    Text("这一页只抓到视频和图片。音频（mp3/m4a…）、文档（pdf/zip/doc…）和 HLS 分片（.ts）会出现在这里。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        } else {
            List {
                Section {
                    ForEach(visibleOtherGroups) { g in
                        row(g.best, variants: g.total)
                    }
                    if otherGroups.count > visibleOtherGroups.count {
                        Button {
                            showAll = true
                        } label: {
                            Text("显示全部 \(otherGroups.count) 条（还有 \(otherGroups.count - visibleOtherGroups.count) 条没列出）")
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("其他 · 共 \(otherGroups.count) 条 · 点一条开始下载")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("还没嗅到地址")
                    .font(.headline)
                ForEach(Array(panelTips.enumerated()), id: \.offset) { i, tip in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(tip)
                            .font(.system(size: 13.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private let panelTips = [
        "在页面里点一下播放，让视频真的开始加载（至少播几秒）。",
        "回到这里下拉刷新，或点右下角圆圈。",
        "长按视频画面也能直接叫出这个面板。",
        "要下的是标着 M3U8 的那一条。标 TS 的是分片，别选那个。",
        "如果只有 BLOB，说明地址藏在脚本里 —— 先让视频播一会儿再刷一次。"
    ]

    /// 一行嗅探结果。
    /// `thumb: true` 时左边带缩略图 —— **只有图片需要**：
    /// 图片看文件名根本认不出是哪张，视频看文件名就够
    ///（而且给视频截一帧得真去下载，成本完全不是一回事）。
    private func row(_ item: SniffItem, variants: Int, thumb: Bool = false) -> some View {
        Button {
            picked = item
        } label: {
            HStack(alignment: .top, spacing: 10) {
            if thumb { ThumbView(item: item) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorFor(item.kind), in: RoundedRectangle(cornerRadius: 4))
                    Text(item.fileName)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if item.playing {
                        // ★ 这就是用户要下的：当前正在播的那个视频
                        Label("正在播放", systemImage: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    } else if item.isRecent {
                        Text("新")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                    }
                    if picked?.id == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(item.url)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // 嗅探时间（真实时钟）+ 出现次数 + 同目录变体数
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5))
                    Text(item.timeText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Text("· \(item.relativeText)")
                        .font(.system(size: 11))
                    if item.hits > 1 {
                        Text("· 出现 \(item.hits > 999 ? "999+" : String(item.hits)) 次")
                            .font(.system(size: 11))
                    }
                    if variants > 1 {
                        Text("· 含 \(variants) 个清单")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(item.isRecent ? Color.accentColor : Color.secondary)

                Text("来源：\(item.src)\(item.host.isEmpty ? "" : " · \(item.host)")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    /// ★ v1.0.127：预览要带的请求头 —— 跟下载同一个道理，防盗链站不给 Referer 就 403。
    private func previewHeaders(_ it: SniffItem) -> [String: String]? {
        var h: [String: String] = [:]
        if !it.ua.isEmpty { h["User-Agent"] = it.ua }
        if !it.referrer.isEmpty { h["Referer"] = it.referrer }
        if !it.cookie.isEmpty { h["Cookie"] = it.cookie }
        return h.isEmpty ? nil : h
    }

    private func startBar(_ item: SniffItem) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(item.isDownloadable ? "可以下载" : "这一条不能直接下")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.isDownloadable ? .primary : .secondary)
                Spacer()
                Text("嗅探于 \(item.timeText)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("复制地址") { model.copy(item.url) }
                    .font(.system(size: 13))
            }
            HStack(spacing: 10) {
                // ★ v1.0.127 预览：用户要的形态是"**能看前几秒判断是不是正片**就够"。
                //   只给视频类 —— 图片/音频/文档没什么好"预览前几秒"的。
                if item.kind == "hls" || item.kind == "file" {
                    Button {
                        previewItem = item
                    } label: {
                        Label("预览", systemImage: "play.circle")
                            .font(.system(size: 12.5))
                    }
                    .buttonStyle(.bordered)
                }
                // ★ v1.0.115 挑清晰度：hls 才给这个入口（直链文件没有多档可选）。
                //   刻意做成"一个小标签"而不是把候选铺在页面上 —— 界面还是原来那么干净；
                //   选过一次就记住（标签上显示所选值），点「开始下载」不会被再拦一次。
                if item.kind == "hls" {
                    Button {
                        variantItem = item
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                            Text(pickedVariantLabel(item))
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    downloads.add(title: model.pageTitle.isEmpty ? item.fileName : model.pageTitle,
                                  url: effectiveURL(item),
                                  referrer: item.referrer,
                                  ua: item.ua,
                                  cookie: item.cookie,
                                  kind: DownloadJob.kind(fromSniff: item.kind))
                    isPresented = false
                } label: {
                    Label("开始下载", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!item.isDownloadable)
            }
        }
        .padding(14)
        .background(.thinMaterial)
    }

    /// 这条现在会用哪个地址下：选过清晰度就用它，否则用嗅探到的那条（= 自动，最高带宽）
    private func effectiveURL(_ item: SniffItem) -> String {
        model.variantPicked[item.url]?.url.absoluteString ?? item.url
    }

    /// 标签上写什么：没选过就是「自动」，选过就写所选档位
    private func pickedVariantLabel(_ item: SniffItem) -> String {
        guard let v = model.variantPicked[item.url] else { return "自动" }
        return BrowserModel.variantLabel(v)
    }

    private func colorFor(_ kind: String) -> Color {
        switch kind {
        case "hls": return .orange
        case "file": return .green
        case "dash": return .purple
        case "blob": return .blue
        case "segment": return .gray
        // ★ v1.0.109
        case "image": return .pink
        case "audio": return .teal
        case "doc": return .brown
        default: return .secondary
        }
    }
}

// MARK: - ★ v1.0.115 挑清晰度

/// 点「自动」那个小标签弹出的卡片。
///
/// 三条设计取舍（都有依据）：
///  1. **懒解析**：卡片弹出的那一刻才去读一次清单 —— 嗅探阶段不解析（页面几十条，全解析
///     既浪费请求、又容易拿到还没稳定的时效地址）。
///  2. **不猜"1080P"**：有分辨率就写分辨率，只有码率就写码率 + 一根相对长度的小条。
///     为什么：HEVC 低码率的可能是高清、AVC 高码率的可能只有 720P，猜错比不标更糟。
///  3. **选一次就记住**：选完标签变成所选值，之后点「开始下载」直接用，不再弹卡片打扰。
struct VariantPickerSheet: View {
    @ObservedObject var model: BrowserModel
    /// 要解析的清单地址（也是 `model` 里那几个字典的键）
    let url: String
    /// 读清单时要带的页面上下文（防盗链站不给就 404）—— 嗅探条目和长按菜单都能提供
    var referrer: String = ""
    var ua: String = ""
    var cookie: String = ""
    /// ★ v1.0.118：**选完档位之后干什么**。
    ///   · 嗅探面板那条路传 nil（只记住选择 —— 用户接着点「开始下载」，地址已经换成所选档）
    ///   · 长按菜单那条路传一个闭包（选完**立刻**开始下 —— 长按上本来就没有「开始下载」按钮，
    ///     用户提的需求：长按也要能挑档）
    ///   回调收到 nil = 用户选了「自动」。
    var onPick: ((M3U8Playlist.Variant?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var choices: [M3U8Playlist.Variant] { model.variantChoices[url] ?? [] }
    private var isLoading: Bool { model.variantLoading.contains(url) }
    private var errorText: String? { model.variantError[url] }
    private var maxBW: Int { max(choices.compactMap { $0.bandwidth }.max() ?? 1, 1) }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        model.variantPicked[url] = nil
                        onPick?(nil)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动（推荐）").font(.system(size: 14, weight: .medium))
                                Text("就是现在这套：挑带宽最高的那条")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.variantPicked[url] == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("码率不等于清晰度：有的站 720P 的码率比别家 1080P 还大，所以这里按码率从大到小排，分辨率只作参考。")
                }

                Section {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读清单…").foregroundStyle(.secondary)
                        }
                    } else if let e = errorText {
                        Text(e).font(.system(size: 13)).foregroundStyle(.secondary)
                    } else if choices.isEmpty {
                        Text("这条没有多清晰度可选").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, v in
                            Button {
                                model.variantPicked[url] = v
                                onPick?(v)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(BrowserModel.variantLabel(v))
                                            .font(.system(size: 14, weight: .medium))
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.primary.opacity(0.08))
                                                Capsule().fill(Color.accentColor.opacity(0.7))
                                                    .frame(width: g.size.width
                                                           * CGFloat(v.bandwidth ?? 0) / CGFloat(maxBW))
                                            }
                                        }
                                        .frame(height: 4)
                                        if let b = v.bandwidth, b > 0 {
                                            Text("\(b / 1000) kbps")
                                                .font(.system(size: 11).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if model.variantPicked[url]?.url == v.url {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(choices.isEmpty ? "可选清晰度" : "这个清单里有 \(choices.count) 档")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("挑清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        // ★ 懒解析就发生在这一刻（用户明确表示要看有哪些清晰度）
        .task { model.loadVariants(url: url, referrer: referrer, ua: ua, cookie: cookie) }
    }
}

// MARK: - 下载列表

/// 下载页顶部的四个分类按钮。
/// ★ v1.0.111：用户要的是「顶部四个分类按钮」，不是一长条按类型分段的列表。
/// 四个按钮固定就是这四个（视频 / 图片 / 文件 / 其他）：
///   · 「文件」= 文档那一类（PDF、压缩包、bin 这些）
///   · 「其他」= 音频，以及类别认不出来的（老记录）
enum DownloadFilter: String, CaseIterable, Identifiable {
    case video, image, doc, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .doc: return "文件"
        case .other: return "其他"
        }
    }

    func matches(_ k: DownloadJob.MediaKind) -> Bool {
        switch self {
        case .video: return k == .video
        case .image: return k == .image
        case .doc: return k == .doc
        case .other: return k == .audio
        }
    }
}

struct DownloadList: View {
    @ObservedObject var center: DownloadCenter
    @Binding var isPresented: Bool

    @State private var query = ""
    /// ★ v1.0.111：顶部四个分类按钮当前选中的那个（默认「视频」）。
    @State private var filter: DownloadFilter = .video

    // ── ★ v1.0.127 多选与批量 ──
    /// 多选模式（长按任意一条进入）
    @State private var selecting = false
    /// 选中的任务。按 **id** 记，不按下标 —— 过滤/排序一变下标就错位了
    @State private var picked = Set<UUID>()
    /// 批量操作的进度提示（存相册/导出都是串行的，得让用户看到走到哪了）
    @State private var batchNote: String?
    /// 批量导出：当前正在弹保存的那个 / 剩下的 / 已完成 / 总数
    /// （用户要的形态是"**逐个弹保存**"，一个文件一次）
    @State private var exportURL: SheetURL?
    @State private var exportRest: [URL] = []
    @State private var exportDone = 0
    @State private var exportTotal = 0

    /// 搜索过滤（按标题或原始地址）+ 分类过滤。
    /// ★ 过滤后左滑删除必须**按对象**删、不能按下标删 —— 过滤后的下标跟
    ///   center.jobs 的下标不是一回事，按下标删会删错人。
    private var shownJobs: [DownloadJob] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = center.jobs.filter { filter.matches($0.mediaKind) }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q) || $0.sourceURL.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if center.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("还没有下载任务")
                            .foregroundStyle(.secondary)
                        Text("下载好的视频留在程序里，\n需要时再点「存相册」或「存文件夹」。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    VStack(spacing: 0) {
                        // ★ v1.0.111：顶部四个分类按钮（视频 / 图片 / 文件 / 其他）。
                        //   以前是列表里按类型分成四段长条 —— 任务一多，想找某一类
                        //   得一路往下滚；现在点一下只看这一类。
                        Picker("分类", selection: $filter) {
                            ForEach(DownloadFilter.allCases) { f in
                                Text(f.label).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                        List {
                            Section {
                                storageBar
                            }
                            if shownJobs.isEmpty {
                                Section {
                                    Text(query.isEmpty
                                         ? "「\(filter.label)」这个分类下还没有东西"
                                         : "这一类里没搜到")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Section {
                                    ForEach(shownJobs) { job in
                                        JobRow(job: job, pip: center.pip)
                                            // ★ v1.0.127 多选态：盖一层透明拦截层 ——
                                            //   这样点整行就是"选中/取消"，**不会误触到行内的按钮**
                                            //   （播放、存相册那些按钮在多选时本来也不该生效）。
                                            .overlay {
                                                if selecting {
                                                    Color.clear
                                                        .contentShape(Rectangle())
                                                        .onTapGesture { togglePick(job) }
                                                        .overlay(alignment: .leading) {
                                                            Image(systemName: picked.contains(job.id)
                                                                  ? "checkmark.circle.fill" : "circle")
                                                                .font(.system(size: 20))
                                                                .foregroundStyle(picked.contains(job.id)
                                                                                 ? Color.accentColor : Color.secondary)
                                                                .padding(.leading, 8)
                                                        }
                                                }
                                            }
                                            // 长按任意一条 → 进多选（跟 iOS 相册一个手感）
                                            .onLongPressGesture(minimumDuration: 0.4) {
                                                guard !selecting else { return }
                                                selecting = true
                                                picked = [job.id]
                                            }
                                    }
                                    .onDelete { idx in
                                        // ★ 按**对象**删：过滤后的下标和 center.jobs 不是一回事
                                        let victims = idx.compactMap {
                                            shownJobs.indices.contains($0) ? shownJobs[$0] : nil
                                        }
                                        for j in victims { center.remove(j) }
                                    }
                                } header: {
                                    Text("\(filter.label) · \(shownJobs.count) 个")
                                }
                            }
                            Section {
                            } footer: {
                                HStack {
                                    Text(query.isEmpty
                                         ? "共 \(center.jobs.count) 个任务"
                                         : "筛出 \(shownJobs.count) 个 · 共 \(center.jobs.count) 个")
                                    Spacer()
                                    Text("占用 \(DownloadJob.sizeText(center.usedSpace))")
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .searchable(text: $query, prompt: "搜标题或地址")
                    }
                    // ★ v1.0.127 多选：底部操作条（只在多选态出现，平时完全不占地方）
                    .safeAreaInset(edge: .bottom) {
                        if selecting { batchBar }
                    }
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            // ★ iOS 15 的老坑：`.toolbar { }` 里**不能写 if**（v1.0.97 实错过）——
            //   条件必须写在 ToolbarItem 内部。
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selecting { Button("取消") { exitSelecting() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selecting {
                        Button("完成") { exitSelecting() }     // 退出多选
                    } else {
                        Button("完成") { center.save(); isPresented = false }
                    }
                }
            }
            // ★ v1.0.127 批量导出：逐个弹保存（一个文件一次），保存完自动弹下一个
            .sheet(item: $exportURL) { one in
                DocumentExporter(url: one.url, onFinish: { _ in
                    exportDone += 1
                    // 稍等一下再弹下一个 —— sheet 自己还在收尾，立刻换会让它弹不出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if exportRest.isEmpty {
                            batchNote = "已导出 \(exportDone)/\(exportTotal)"
                            selecting = false
                            picked.removeAll()
                        } else {
                            exportURL = SheetURL(url: exportRest.removeFirst())
                        }
                    }
                })
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - ★ v1.0.127 多选与批量

    /// 底部操作条：删除 / 存相册 / 导出，都是"对选中的那些做"
    private var batchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("已选 \(picked.count) 个")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                Button(role: .destructive) { batchDelete() } label: {
                    Label("删除", systemImage: "trash").font(.system(size: 12.5))
                }
                .buttonStyle(.bordered)
                Button { batchSavePhotos() } label: {
                    Label("存相册", systemImage: "photo.on.rectangle").font(.system(size: 12.5))
                }
                .buttonStyle(.bordered)
                Button { batchExport() } label: {
                    Label("导出", systemImage: "folder").font(.system(size: 12.5))
                }
                .buttonStyle(.bordered)
            }
            .disabled(picked.isEmpty)

            if let batchNote {
                Text(batchNote).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var pickedJobs: [DownloadJob] {
        center.jobs.filter { picked.contains($0.id) }
    }

    private func togglePick(_ job: DownloadJob) {
        if picked.contains(job.id) { picked.remove(job.id) } else { picked.insert(job.id) }
    }

    private func exitSelecting() {
        selecting = false
        picked.removeAll()
        batchNote = nil
    }

    /// 批量删除：走跟单条删除**同一条路**（连文件一起删，不留垃圾）
    private func batchDelete() {
        let victims = pickedJobs
        guard !victims.isEmpty else { return }
        for j in victims { center.remove(j) }
        batchNote = "已删除 \(victims.count) 个"
        exitSelecting()
    }

    /// 批量存相册：**串行**逐个存（相册写入一次只能一个），并把进度显示出来
    private func batchSavePhotos() {
        let list = pickedJobs.filter { $0.canSaveToPhotos }
        guard !list.isEmpty else {
            batchNote = "选中的里面没有能存相册的（要图片或视频）"
            return
        }
        let total = list.count
        Task { @MainActor in
            var ok = 0
            for (i, j) in list.enumerated() {
                batchNote = "正在存相册 \(i + 1)/\(total)…"
                await j.saveToPhotos()
                if j.savedToPhotos { ok += 1 }
            }
            batchNote = "已存相册 \(ok)/\(total)"
            selecting = false
            picked.removeAll()
        }
    }

    /// 批量导出：收集文件地址，交给上面那张 sheet 逐个弹保存
    private func batchExport() {
        let urls = pickedJobs.compactMap { $0.exportURL() }
        guard !urls.isEmpty else {
            batchNote = "选中的里面没有能导出的文件"
            return
        }
        exportTotal = urls.count
        exportDone = 0
        exportRest = Array(urls.dropFirst())
        batchNote = "开始导出 \(urls.count) 个，逐个选保存位置…"
        exportURL = SheetURL(url: urls[0])
    }

    /// 顶部存储条：这个 App 占了多少、设备还剩多少。
    /// 分母取「占用 + 可用」—— 这样这条子反映的是「本 App 在整机可用空间里的分量」，
    /// 而不是一个没参照物的百分比。
    private var storageBar: some View {
        let used = center.usedSpace
        let free = Self.deviceFreeSpace
        let total = max(1, used + free)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("下载占用 \(DownloadJob.sizeText(used))")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("设备可用 \(DownloadJob.sizeText(free))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(used), total: Double(total))
                .progressViewStyle(.linear)
        }
        .padding(.vertical, 2)
    }

    /// 设备可用空间（拿不到就 0，界面会显示「—」）
    static var deviceFreeSpace: Int64 {
        let u = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// 让 URL 可以直接当 sheet 的触发源（.sheet(item:)）。
/// 上一版用「isPresented 布尔 + 可选 URL」两个独立状态，弹出瞬间内容判 nil
/// → 空视图 → 白屏。用 item 模式后这两个状态合成一个，不可能再错位。
struct SheetURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    /// 只是转交给播放器用（播放时给下载保活窗让位）。
    /// 故意用裸 let 而不是 @ObservedObject：这里不需要订阅画中画的每次变动，
    /// 订阅了反而会让列表每一行都跟着重绘。
    let pip: PiPProgress
    /// ★ v1.0.118：**订阅"看到哪儿了"** —— 进度记录以前是纯静态的，写进去没有任何通知，
    ///   这一行的 body 不会重画 → 缩略图底部那条进度线永远不出现（用户实测报的就是这个）。
    ///   这里只是订阅（值本身不参与布局），线照旧从 `watch.fraction(...)` 取。
    /// ★ v1.0.133：续看总开关关着时 `fraction` 直接返回 nil，这条线自然不画。
    @ObservedObject private var watch = WatchProgress.shared
    @State private var playSheet: SheetURL?
    @State private var exportSheet: SheetURL?
    /// ★ v1.0.119：分享这个文件（系统分享面板）
    @State private var shareSheet: SheetURL?
    /// ★ v1.0.111：图片的「查看」入口（下好的图片点开看大图）
    @State private var viewSheet: SheetURL?
    @State private var showLog = false
    /// 缩略图（转码成功后抽的那一帧）。读盘一次就存下来，
    /// 不放在 body 里每次重算都读 —— 列表滚动时会很难看。
    @State private var thumbImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 左缩略图 + 右信息：列表里一眼能认出是哪个片子
            HStack(alignment: .top, spacing: 10) {
                thumb

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if job.isActive {
                            Spacer(minLength: 8)
                            // 大号总百分比：整条流程（下载+拼接+转码）
                            Text("\(Int((job.overall * 100).rounded()))%")
                                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                    }

                    Text(JobRecord.formatter.string(from: job.createdAt))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)

                    if job.finished && !job.fileMissing {
                        HStack(spacing: 10) {
                            if job.duration > 0 { meta("clock", DownloadJob.durationText(job.duration)) }
                            if job.fileSize > 0 { meta("internaldrive", DownloadJob.sizeText(job.fileSize)) }
                            if let r = job.resolution, !r.isEmpty { meta("film", r) }
                        }
                    }
                }
            }

            if job.isActive {
                ProgressView(value: job.overall)
            }

            HStack(spacing: 5) {
                // ★ v1.0.109：非视频的成品标一下类型 —— 只看文件名看不出是图还是音频
                if job.mediaKind != .video {
                    Image(systemName: job.mediaKind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(job.phase)
                    .font(.system(size: 12))
                    .foregroundStyle(job.failed != nil ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                if job.isActive {
                    if !job.speedText.isEmpty {
                        Text(job.speedText)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if job.total > 0 {
                        Text("\(job.done)/\(job.total)")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if job.fileMissing {
                Label("文件已经不在了（可能被系统清理或删掉）", systemImage: "xmark.octagon")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else if job.finished && job.failed == nil && !job.mp4Ready && job.mediaKind == .video {
                // ★ v1.0.110：加 `mediaKind == .video` —— 图片/音频/文档本来就不转码，
                //   以前图片下载成功也会挂这条黄字（"MP4 没转出来"），纯误报。
                // ★ v1.0.111：再加 `job.failed == nil` —— 类别改由建卡时记下的 kind 判定后，
                //   "失败且一个产物都没产出"的视频任务也会算成 .video，别在红字下面再挂一条黄字。
                Label("MP4 没转出来 · 原因在「过程记录」里", systemImage: "info.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }

            if let n = job.notice {
                Text(n)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
            }

            // 进行中 → 暂停；已暂停/被中断 → 继续；失败 → 重试。
            // 文案分开是给用户看的语义，底层都是「保留已下分片，从断点接着来」。
            if job.isActive {
                HStack(spacing: 8) {
                    Button {
                        job.pause()
                    } label: {
                        Label("暂停", systemImage: "pause.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    // ★ v1.0.127 边下边播：下载中也能先看几段（复用上面那个播放器）。
                    //   v1.0.130：按钮的**出现条件放宽**成"有 ≥2 个连续分片" ——
                    //   格式不支持（fMP4/加密流）放到点击后用一句话解释，
                    //   不然用户只会看到"按钮莫名不见了"，像功能坏了。
                    if job.livePreviewReady {
                        Button {
                            if let u = job.livePreviewURL() {
                                playSheet = SheetURL(url: u)
                            } else {
                                job.show("这条现在播不了：" + (job.livePreviewBlockReason() ?? "原因不明"))
                            }
                        } label: {
                            Label("边下边播", systemImage: "play.circle")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if !job.finished {
                // ★ v1.0.107：判据从「paused 或 failed」改成「**只要没完成**」——
                //   以前恢复出来的任务可能三个标志都不满足（既没完成也没失败），
                //   于是「继续/重试」一个都不显示，用户只能删任务。
                Button {
                    job.resumeDownload()
                } label: {
                    Label(job.paused ? "继续" : "重试",
                          systemImage: job.paused ? "play.circle.fill" : "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            // 操作按钮
            if job.finished && !job.fileMissing {
                HStack(spacing: 8) {
                    // ★ v1.0.109：只有视频才给「播放」—— 图片/音频/文档没得播
                    if job.mediaKind == .video, job.localPlaybackURL() != nil {
                        Button {
                            // ★ 每次现取地址 —— 本机服务端口每次启动都可能变，
                            //   用存下来的旧地址就是白屏的根源之一
                            if let u = job.localPlaybackURL() {
                                showLog = false
                                playSheet = SheetURL(url: u)
                            } else {
                                job.show("这个文件现在播不了")
                            }
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if job.mediaKind == .video {
                        // 本地没东西可播（比如文件被删了），退回原始在线地址，
                        // 仍然走我们自己的播放器 —— 而不是丢给 Safari
                        Button {
                            if let u = URL(string: job.sourceURL) {
                                playSheet = SheetURL(url: u)
                            } else {
                                job.show("地址不合法")
                            }
                        } label: {
                            Label("在线播放", systemImage: "play")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else if job.mediaKind == .image {
                        // ★ v1.0.111：图片没得"播"，给「查看」—— 点开看大图。
                        //   以前图片下完在列表里只有一行字，想确认下的是哪张图都没辙。
                        Button {
                            if let u = job.exportURL() {
                                viewSheet = SheetURL(url: u)
                            } else {
                                job.show("文件不在了")
                            }
                        } label: {
                            Label("查看", systemImage: "photo")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        Task { await job.saveToPhotos() }
                    } label: {
                        Label(job.savedToPhotos ? "已存相册" : "存相册",
                              systemImage: job.savedToPhotos ? "checkmark.circle.fill" : "photo.on.rectangle")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!job.canSaveToPhotos)

                    Button {
                        if let u = job.exportURL() {
                            exportSheet = SheetURL(url: u)
                        } else {
                            job.show("文件不在了")
                        }
                    } label: {
                        Label("存文件夹", systemImage: "folder")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    // ★ v1.0.119：分享（系统分享面板）—— 跟"存文件夹"并排，
                    //   两者不冲突：存文件夹是直接选位置，分享是发给别的 App / 存到文件。
                    Button {
                        if let u = job.exportURL() {
                            shareSheet = SheetURL(url: u)
                        } else {
                            job.show("文件不在了")
                        }
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if job.exportURL() != nil {
                    if job.mediaKind == .audio || job.mediaKind == .doc {
                        Text("相册只收图片和视频，这个用「存文件夹」保存。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if job.mediaKind == .video && !job.canSaveToPhotos {
                        Text("相册不认 .ts，要等 MP4 转出来才能存相册；「存文件夹」可以保存原文件。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !job.notes.isEmpty {
                Button {
                    showLog.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showLog ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(showLog ? "收起过程记录" : "过程记录")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showLog {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(job.notes.enumerated()), id: \.offset) { _, n in
                        Text(n)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(n.hasPrefix("✗") ? .red :
                                             (n.hasPrefix("✓") ? .green : .secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 3)
        // ══ 白屏的最终修法 ══
        // 上一版是 .sheet(isPresented:) + 内容里判另一个可选状态：
        //   .sheet(isPresented: $playing) { if let u = playTarget { ... } }
        // SwiftUI 在触发 sheet 的瞬间就会求值内容闭包，那时 playTarget 可能
        // 还没写进去 → 内容为空 → **纯白一整屏**（正是用户看到的样子）。
        // 改成 .sheet(item:)：URL 本身就是触发源，有值才有 sheet，
        // "弹出了但内容是空的"这种情况从结构上不可能发生。
        // 播放器用 fullScreenCover（不是 sheet）：sheet 顶部会露出后面一截、
        // 四角是圆的，看着就不是"全屏"。fullScreenCover 是铺满整块屏。
        .fullScreenCover(item: $playSheet) { s in
            // ★ v1.0.115 续看：把**任务 id** 传进去当进度记录的键
            //   （用 id 而不是文件名：转码会把 .ts 换成 .mp4，名字会变，id 不会；
            //    同一条任务"本地播 / 在线播"也共用同一份进度）
            PlayerSheet(url: s.url, title: job.title, pip: pip,
                        key: job.id.uuidString)
        }
        .sheet(item: $exportSheet) { s in
            DocumentExporter(url: s.url, onFinish: { ok in
                job.show(ok ? "已保存到你选的位置" : "已取消")
            })
        }
        // ★ v1.0.119：分享这个文件（系统面板里能"存储到文件"、发微信、AirDrop）
        .sheet(item: $shareSheet) { s in
            ActivityView(items: [s.url])
        }
        // ★ v1.0.111：图片查看器（跟播放器一样用 fullScreenCover，铺满整块屏）
        .fullScreenCover(item: $viewSheet) { s in
            ImageViewerSheet(url: s.url, title: job.title)
        }
    }

    /// 左侧缩略图（16:9）。
    /// · 视频：转码成功后抽的那一帧（`thumbName`）
    /// · 图片（★ v1.0.111）：**直接用下好的那张图本身**当缩略图 ——
    ///   以前只有视频抽帧这一条路，图片一律是占位图标（用户报的"下完了没缩略图"）。
    ///   走 ThumbLoader 的降采样，不把原图整张解码进内存。
    /// · 抽不到 / 还没下完：显示占位图标（按类别选图标，图片不再是"胶片"）
    private var thumb: some View {
        // 触发重新取图的钥匙：产物名 / 类别 / 抽帧名，任意一个变了就重取一次
        let key = "\(job.thumbName ?? "-")|\(job.mediaKind.key)|\(job.outputName ?? "-")"
        return ZStack {
            Color(.tertiarySystemFill)
            if let img = thumbImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: job.isActive ? "arrow.down.circle" : job.mediaKind.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 104, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        // ★ v1.0.115 续看：看过多少 —— 缩略图底边一条 3pt 细线。
        //   只在"看过一点、又没看完"时出现（看过 / 没看过都不画）；不是新控件、不占地方。
        // ★ v1.0.118：走 `watch`（订阅过的实例）—— 否则这一行不重画，线不出现。
        .overlay(alignment: .bottom) {
            if let f = watch.fraction(for: job.id.uuidString, duration: job.duration) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.4)
                        Color.white.opacity(0.92).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 1)
                .padding(.bottom, 1)
            }
        }
        .task(id: key) {
            thumbImage = nil
            if let u = job.thumbURL {
                thumbImage = UIImage(contentsOfFile: u.path)
                return
            }
            if job.mediaKind == .image, let f = job.exportURL() {
                thumbImage = await ThumbLoader.loadLocal(f)
            }
        }
    }

    private func meta(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(text).font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

/// 图片查看器（★ v1.0.111）。
/// 为什么必须降采样：一张 4000×3000 的图整张解码约 48MB，
/// 而查看器正好是最容易吃到整图的地方 —— 一律只解到目标尺寸（ThumbLoader.loadLocal）。
/// 手势：双指缩放、双击放大/还原，右上角「完成」关掉。
struct ImageViewerSheet: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var img: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in
                                scale = min(max(lastScale * v, 1), 6)
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                        }
                    }
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                    Text("这张图读不出来了")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if img != nil {
                    Text(scale > 1 ? "双指缩放 · 双击还原" : "双指缩放 · 双击放大")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 16)
                }
            }
        }
        .task {
            // 1600px 够看清细节，又不至于把内存顶上去
            if let got = await ThumbLoader.loadLocal(url, maxPx: 1600) {
                img = got
            } else {
                failed = true
            }
        }
    }
}

// MARK: - 局域网共享

/// 同一 Wi-Fi 下，电脑浏览器打开一个地址就能看到、下载手机里下好的视频。
///
/// 口令只是门牌（挡同一 Wi-Fi 下瞎扫端口的陌生人），不是加密 ——
/// 所以界面上必须说清楚「用完记得关」，而且关掉就换新口令。
/// 手机自己的播放器走回环地址，不受口令影响。
struct LanShareView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloads: DownloadCenter

    @State private var url: URL?
    @State private var problem: String?
    @State private var copied = false
    @State private var davCopied = false        // WebDAV 地址复制过了
    @State private var tokenCopied = false      // 口令复制过了

    var body: some View {
        NavigationView {
            List {
                // 注意：这里不能写成 `if let url` —— 会把 @State 的 url 遮蔽成 let，
                // 下面「关闭共享」里的 url = nil 就编译不过（CI 抓到的就是这个）
                if let link = url {
                    Section {
                        Text(link.absoluteString)
                            .font(.system(size: 14, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = link.absoluteString
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制地址",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    } header: {
                        Text("在电脑浏览器里打开这个地址")
                    } footer: {
                        Text("电脑和手机要在同一个 Wi-Fi。地址里那串口令是门牌：同一 Wi-Fi 下拿到地址的人都能下载，所以用完记得关掉。")
                    }

                    // ── WebDAV：把手机挂成电脑上的一个盘（能拖进去、能改名能删）──
                    if let dav = LocalHTTPServer.shared.davURL {
                        Section {
                            Text(dav.absoluteString)
                                .font(.system(size: 14, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = dav.absoluteString
                                davCopied = true
                            } label: {
                                Label(davCopied ? "已复制" : "复制 WebDAV 地址",
                                      systemImage: davCopied ? "checkmark" : "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = LocalHTTPServer.shared.token
                                tokenCopied = true
                            } label: {
                                Label(tokenCopied ? "已复制" : "复制口令（当密码用）",
                                      systemImage: tokenCopied ? "checkmark" : "key")
                            }
                        } header: {
                            Text("挂成电脑上的一个盘（WebDAV）")
                        } footer: {
                            Text("电脑上装个 WebDAV 客户端（Windows 推荐 RaiDrive 免费版，也可用 Cyberduck）：地址填上面那个，用户名随便填，密码填这串口令。连上后手机就出现在「此电脑」里 —— 能拖文件进去、改名、删除。")
                        }
                    }

                    Section("怎么用") {
                        bullet("会自动弹一个小窗保活 —— 有它，切到别的 App 或锁屏，电脑照样能连（小窗要留着，别划掉）。")
                        bullet("代价就一条：小窗在的时候，手机别处的声音（音乐、视频）会被暂停 —— 它得占着播放通道。不想共享了就点下面的「关闭共享」，小窗会跟着收掉。")
                        bullet("浏览器方式（只读）：电脑上点文件名即开始下载。mp4 一般能直接在线播放；m3u8 建议下载后用播放器打开。")
                        bullet("WebDAV 方式（能读能写）：手机在电脑里就像一个 U 盘。注意 —— 拿到地址和口令的人都能改删文件，用完记得关。")
                        bullet("电脑打不开时：先确认手机连的是 Wi-Fi（只有蜂窝网时不开局域网），再看系统设置里有没有允许这个 App 访问「本地网络」。")
                    }

                    Section {
                        Button(role: .destructive) {
                            downloads.stopSharing()
                            url = nil
                            problem = nil
                            copied = false
                        } label: {
                            Label("关闭共享", systemImage: "stop.circle")
                        }
                    } footer: {
                        Text("关掉后地址立刻失效，下次开启会换一个新口令；没有下载在跑的话，保活小窗会跟着收掉。")
                    }
                } else {
                    Section {
                        Label(problem ?? "没能开启共享", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                        Button { openSettings() } label: {
                            Label("打开系统设置", systemImage: "gear")
                        }
                        Button { start() } label: {
                            Label("再试一次", systemImage: "arrow.clockwise")
                        }
                    } header: {
                        Text("没能开启")
                    } footer: {
                        Text("最常见的原因：手机没连 Wi-Fi，或者系统拒绝了「本地网络」权限。")
                    }
                }
            }
            .navigationTitle("共享给电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { if url == nil { start() } }
    }

    private func start() {
        copied = false
        problem = nil
        guard downloads.startSharing() != nil else {
            url = nil
            problem = LocalHTTPServer.shared.lastError ?? "本机 HTTP 服务起不来"
            return
        }
        url = LocalHTTPServer.shared.lanURL
        if url == nil {
            problem = "服务起来了，但没找到局域网地址 —— 手机可能没连 Wi-Fi"
        }
    }

    private func openSettings() {
        guard let u = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(u)
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(.system(size: 15, weight: .bold))
            Text(t).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 说明

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("这是干什么的") {
                    Text("这个 App 自带一个浏览器。网页视频的真实地址只存在于「加载它的那个会话里」，所以要在自己的浏览器里看、在自己的进程里嗅，才拿得到。嗅到之后下载、自动转成 MP4 —— 视频**留在程序内**，需要时你自己决定存到相册还是某个文件夹。不需要任何解锁和付费。")
                        .font(.system(size: 13.5))
                }
                Section("怎么用") {
                    step(1, "在上面地址栏输入视频站地址，进去。")
                    step(2, "点一下播放，让视频真的开始加载（重要：先播几秒）。")
                    step(3, "长按视频画面，或点右下角圆圈 → 弹出嗅探结果。")
                    step(4, "按嗅探时间选最新那条标着 M3U8 的 → 开始下载。")
                    step(5, "下完自动转成 MP4。要保存就点「存相册」或「存文件夹」。")
                }
                Section("嗅探结果怎么看") {
                    bullet("每条都标了嗅探时间（几点几分几秒 + “刚刚 / 3 分钟前”），刚出来的会带红色「新」标记并排在最前面 —— 这样才能确定点的是刚抓到的那条。")
                    bullet("同一个地址被反复看到时，会显示「出现 N 次」，说明它更可能是真正在用的那个。")
                    bullet("下拉或点右上角 ⋯ → 重新扫描，可以强制再扫一遍。")
                }
                Section("视频存在哪") {
                    bullet("下载和转好的文件都留在 App 自己的私有目录里，不会自动出现在系统「文件」App 中。")
                    bullet("「存相册」= 存进系统相册（需要相册写入权限，第一次会问）。")
                    bullet("「存文件夹」= 弹出系统的存储面板，你自己选放在哪个文件夹，系统会复制一份过去，程序内的原件不受影响。")
                    bullet("在下载列表里左滑删除，会把这个任务和它的文件一起删掉。")
                }
                Section("下载时切后台") {
                    bullet("先点底部的「PIP 后台下载」→ 确认后会出现一个画中画小窗（里面是下载进度）。有这个窗口，切到别的 App 或锁屏，下载都会继续跑。")
                    bullet("为什么非要先点一下：iOS 在 App 进后台的那一刻会作废画布层，那时候才去起画中画必然失败（报「操作已中断」）。所以必须趁 App 还在前台时开好。")
                    bullet("不想后台下载就不点它 —— 切后台下载会暂停，已下好的分片保留，回来点一次会接着下。")
                    bullet("别把 App 从多任务里上滑杀掉，那样连画中画一起没。")
                }
                Section("共享给电脑") {
                    bullet("点工具条上的 Wi-Fi 图标 → 同一 Wi-Fi 的电脑用浏览器打开显示的那个地址，就能看到、下载手机里的视频。")
                    bullet("地址里带一串随机口令，是挡住同一个 Wi-Fi 下陌生人扫端口的；但它不是加密，拿到地址的人都能下 —— 用完点「关闭共享」，下次开启会换新口令。")
                    bullet("关掉后手机自己的播放完全不受影响（播放走本机地址，不需要口令）。")
                    if let ip = LocalHTTPServer.lanIPAddress() {
                        bullet("手机当前的局域网地址是 \(ip)（换 Wi-Fi 会变）。")
                    }
                }
                Section("已知限制") {
                    bullet("转 MP4 是「只换容器、不重新编码」，所以很快、画质无损。只有少数格式不规范的流才需要走备用方案。")
                    bullet("转不成时会保留 .ts 原文件。那个格式 iOS 系统播放器和相册都不认，可以用「存文件夹」导出后用 VLC / nPlayer 打开。")
                    bullet("每一步成没成都会记在下载条目的「过程记录」里，出问题点开看一眼定位得很快。")
                    bullet("DRM 加密的付费影片拿不到，这个任何工具都做不到。")
                    bullet("有些站的地址是脚本算出来的、或走了第三方解析，可能嗅不到 —— 换个线路或等视频多播一会儿再试。")
                    bullet("个别站会检测「是不是 App 内置浏览器」，那种站打不开也正常。")
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func step(_ i: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(i)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(t).font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(.system(size: 15, weight: .bold))
            Text(t).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
