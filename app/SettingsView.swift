import SwiftUI
import UIKit
import WebKit

/// 设置。所有开关都收在这一页里，不往主界面加按钮。
struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool

    @State private var confirmClearHistory = false
    @State private var showHelp = false
    @State private var note: String?
    /// ★ v1.0.149：清理临时文件进行中（防连点 + 按钮显示"清理中…"）
    @State private var isCleaning = false
    /// ★ v1.0.133：两个播放相关开关，都放在新起的「播放」Section 里。
    /// 键与 `WatchProgress.enabledKey` / `PlayerBox.autoLandscapeKey` 一致 —— 两边天然同步。
    /// **两个都默认关**（用户 2026-09-28 选的）。
    @AppStorage(WatchProgress.enabledKey) private var resumeEnabled = false
    @AppStorage(PlayerBox.autoLandscapeKey) private var autoLandscape = false
    /// ★ v1.0.159：后台播放声音（**默认开**）。
    /// 键与 `PlayerBox.backgroundAudioKey` 一致 —— 两边天然同步。
    /// 开着：播放中切到别的 App / 锁屏，画面丢掉、**声音接着放**；
    /// 关着：切走就停（iOS 默认行为），回来得重新点播放。
    /// ★ 为什么这个必须默认开：iOS 15 起 AVPlayer 默认策略是 `.automatic`，
    ///   一进后台就暂停 —— 那一刻没有音频在放，"后台音频"这张票立刻失效 →
    ///   进程被挂起/回收 → 用户回来时**播放器整块没了**（真机反馈就是这个现象）。
    @AppStorage(PlayerBox.backgroundAudioKey) private var bgAudio = true
    /// 播放小窗（App 里播放视频时切出去继续播）。
    /// 跟「下载保活」是两件事，所以是两个开关。
    @AppStorage("playerPiPEnabled") private var playerPiP = true
    /// ★ v1.0.160：压缩时用小窗保活（**默认开**）。
    /// 键与 `CompressQueue.keepAliveKey` 一致 —— 两边天然同步。
    /// 关掉 = 压的时候不能切走/锁屏（切走会被系统挂起，那一条会从头再来）。
    @AppStorage(CompressQueue.keepAliveKey) private var compressKeepAlive = true
    /// 长按视频弹下载菜单（默认开）。关掉 = 完全不接管长按，页面怎么长按都跟我们无关
    @AppStorage("lpLongPressDownload") private var lpDownload = true
    /// 长按诊断（默认关）：只在排查「长按没反应」时打开，会在屏幕顶部显示一行过程记录
    @AppStorage("lpDebug") private var lpDebug = false
    /// 嗅探按钮要不要一直待在屏幕上（默认关：不占地方）
    @AppStorage("sniffButtonResident") private var sniffResident = false

    /// ★ v1.0.209 网页广告清理总开关（默认开；键跟 AdClean.key 是同一个）
    @AppStorage(AdClean.key) private var adClean = true
    /// 后台自动嗅探（★ v1.0.104 起默认**关**）。关着时：不自动扫页面、不自动刷新结果，
    /// 但抓请求照旧、长按下载照旧。打开嗅探面板时会自动扫一次。
    @AppStorage("autoSniff") private var autoSniff = false
    /// ★ v1.0.197：同时下载数（0 = 不限）。DownloadCenter.maxConcurrentKey 同一个键。
    @AppStorage(DownloadCenter.maxConcurrentKey) private var maxConcurrent = 0
    /// 已经放行过的网站数（证书不被信任、但按设置一律放行）。进页面时读一次。
    @State private var trustedCount = 0
    /// 启动主页（v1.0.90）。**留空 = 每次打开只显示空白页**。
    @AppStorage("homePageURL") private var homePage = ""
    /// 回收站（v1.0.97）
    @State private var showTrash = false
    /// ★ v1.0.205：地址栏的搜索引擎（输的不是网址就拿去搜）
    @AppStorage(SearchEngine.key) private var searchEngine = SearchEngine.baidu.rawValue
    @AppStorage(SearchEngine.customKey) private var searchEngineCustom = ""
    /// ★ v1.0.164：全局回收站（书签 + 已删的下载文件）—— 单例，只订阅它的计数变化
    @ObservedObject private var bin = FileBin.shared

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("记录播放进度（下次接着看）", isOn: $resumeEnabled)
                        .onChange(of: resumeEnabled) { on in
                            // ★ v1.0.133：关掉时**一并清空**已有进度（用户 2026-09-28 选的）。
                            //   留着的话，下次再打开开关会突然冒出一堆"续看位置"，
                            //   中间隔了很久，早就想不起那是什么了。
                            WatchProgress.setEnabled(on)
                            if !on { note = "已关闭续看，之前记录的播放进度也一并清掉了。" }
                        }
                    Toggle("首次播放自动横屏", isOn: $autoLandscape)
                    Toggle("后台播放声音（切走/锁屏继续出声）", isOn: $bgAudio)
                } header: {
                    Text("播放")
                } footer: {
                    Text("**记录播放进度（默认关）** 开着：视频看到一半退出，下次打开会接着上次的位置继续，下载列表里也能看到一条细进度线。关着：每次从头播，不留任何记录。\n\n**首次播放自动横屏（默认关）** 开着：横向视频一打开就自动转成横屏；关着：保持竖屏播放，想横屏自己转手机（播放器里的全屏按钮照常能用）。\n\n**后台播放声音（默认开）** 开着：播放中切到别的 App 或锁屏，画面丢掉、声音继续放；关着：切走就暂停，回来要重新点播放。改完**下次打开播放器生效**。")
                }

                Section {
                    Toggle("下载保活（切后台下载不停）", isOn: pipBinding)
                    if let e = downloads.pip.lastError {
                        Text(e).font(.system(size: 12)).foregroundStyle(.orange)
                    } else if !downloads.pip.isSupported {
                        Text("这台设备不支持画中画。").font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("播放小窗（切出去继续播）", isOn: $playerPiP)
                    // ★ v1.0.160：压缩期间要不要弹小窗保活（用户点名要有这个开关）
                    Toggle("压缩时用小窗保活（切走也能压）", isOn: $compressKeepAlive)
                } header: {
                    Text("画中画")
                } footer: {
                    Text("下载保活：开了会立刻出现一个小窗，里面是下载进度；随时关小窗即可停用。\n播放小窗：在 App 里播视频时切到别的 App，画面缩成小窗继续播（也能直接点播放器上的画中画按钮）。\n压缩保活（默认开）：压画质省空间排队开压时会自动起小窗，切到别的 App 也能一直压；关掉的话**压的时候别切走、也别锁屏** —— 切走会被系统挂起，那一条会从头再来。\n两个小窗同时只能有一个 —— 播放时下载/压缩保活窗会先让位，播完自动还回来。")
                }

                Section {
                    // ★ v1.0.197：同时下载数 —— 超出上限的任务自动排队（先排先走）
                    Picker("同时下载", selection: $maxConcurrent) {
                        Text("1 个").tag(1)
                        Text("3 个").tag(3)
                        Text("5 个").tag(5)
                        Text("不限").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: maxConcurrent) { _ in
                        downloads.pump()      // 上限调大 → 排队中的立刻放出来
                    }
                } header: {
                    Text("下载")
                } footer: {
                    Text("同时下载的任务数，超出的自动排队等空位（先排先走，任务上会显示「排队中」）。\n"
                         + "改小只影响之后开跑的任务 —— 正在跑的不打断。\n"
                         + "重启 App 后，排队的会变成「已暂停」，点继续重新排队。")
                }

                Section {
                    Toggle("共享给电脑（同一 Wi-Fi）", isOn: shareBinding)
                    if downloads.lanOn, let u = LocalHTTPServer.shared.lanURL?.absoluteString {
                        Text(u)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    // ★ v1.0.102：口令可以固定 —— 电脑上存一次书签，以后开着共享点开就能用
                    Toggle("记住口令（电脑上存一次就不用再复制）", isOn: $fixedTokenOn)
                        .onChange(of: fixedTokenOn) { on in
                            if on {
                                LocalHTTPServer.shared.fixCurrentToken()
                            } else {
                                LocalHTTPServer.shared.forgetFixedToken()
                            }
                        }
                    if fixedTokenOn {
                        Button("换一个口令") {
                            if downloads.lanOn {
                                _ = LocalHTTPServer.shared.regenerateToken()
                                note = "口令换好了。地址已经变了 —— 电脑上那个书签要重新存一次。"
                            } else {
                                LocalHTTPServer.shared.forgetFixedToken()
                                LocalHTTPServer.shared.fixCurrentToken()
                                note = "换好了，下次开共享就用这串新的。"
                            }
                        }
                    }
                } header: {
                    Text("局域网共享")
                } footer: {
                    Text("手机里的视频通过本机地址给电脑下载，用完记得关掉。\n"
                         + "电脑上想存个书签、以后点开就能用 → 打开「记住口令」：地址从此不变"
                         + "（关掉共享时电脑打不开，重新打开就已经是同一个地址）。\n"
                         + "代价：固定之后，同一个 Wi-Fi 下曾经拿到过这个地址的人也能一直进 —— "
                         + "所以默认不开。")
                }

                // ★ v1.0.205：地址栏能搜了 —— 搜哪儿由这儿定
                Section {
                    Picker("搜索引擎", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { e in
                            Text(e.title).tag(e.rawValue)
                        }
                    }
                    if searchEngine == SearchEngine.custom.rawValue {
                        TextField("搜索链接模板（%@ 代表关键词）", text: $searchEngineCustom)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                    }
                } header: {
                    Text("搜索")
                } footer: {
                    Text("在地址栏里输的不是网址时，用它去搜（输中文、输一整句话都算）。\n"
                         + "自定义模板必须含 %@，例如 https://www.baidu.com/s?wd=%@")
                }

                Section("浏览数据") {
                    labeled("收藏", "\(store.marks.count) 条")
                    labeled("浏览历史", "\(store.history.count) 条")
                    Button {
                        showTrash = true
                    } label: {
                        HStack {
                            Text("回收站")
                            Spacer()
                            Text(binSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("清空浏览历史", role: .destructive) { confirmClearHistory = true }
                    Button("清除网页缓存") { clearWebCache() }
                    // ★ v1.0.101：以前失败的任务把分片一直留在磁盘上，却**没有任何清理入口**
                    Button {
                        cleanupTemp()
                    } label: {
                        HStack(spacing: 6) {
                            if isCleaning { ProgressView().controlSize(.small) }
                            Text(isCleaning ? "清理中…" : "清理下载临时文件")
                        }
                    }
                    .disabled(isCleaning)
                    // 标签存档：清了之后下次启动就是干净的空白页（组也一起没）
                    Button("清空标签存档（下次启动是空白页）", role: .destructive) {
                        model.wipeSavedTabs()
                    }
                }

                Section {
                    labeled("已放行的网站", "\(trustedCount) 个")
                    if let last = TrustedHosts.lastApproved {
                        labeled("最近一次放行", last.host)
                        labeled("时间", Self.stamp.string(from: last.at))
                    }
                    if trustedCount > 0 {
                        Button("忘掉所有已放行的网站", role: .destructive) {
                            TrustedHosts.forgetAll()
                            trustedCount = TrustedHosts.count
                            note = "已忘记。这些网站下次打开会再提醒你一次 —— 页面照常放行，我们从不拦网站。"
                        }
                    }
                } header: {
                    Text("证书")
                } footer: {
                    Text("有些网站的加密证书不被系统信任（过期 / 自签 / 身份对不上）。**这类网站我们一律照常打开**，只在第一次提醒你一句，之后不再打扰。\n\n「忘掉」之后，下次打开会重新提醒一次 —— 但页面照样能开，我们不会拦任何网站。")
                }

                Section {
                    TextField("留空 = 只显示空白页", text: $homePage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.system(size: 14))
                } header: {
                    Text("启动主页")
                } footer: {
                    Text("填了网址：每次打开程序**固定打开它**，不再把上次浏览的网页摆在最前面。\n留空：每次打开只显示空白页。\n\n两种情况**上次的标签都会被恢复**，只是待在后台 —— 从标签网格里点得到。")
                }

                Section {
                    Toggle("后台自动嗅探", isOn: $autoSniff)
                        .onChange(of: autoSniff) { _ in model.applyAutoSniffSetting() }
                    Toggle("嗅探按钮常驻屏幕", isOn: $sniffResident)
                } header: {
                    Text("嗅探")
                } footer: {
                    Text("**后台自动嗅探（默认关）** 开着：页面每 3 秒自己扫一遍，结果自动刷新。关着：不扫页面，你打开「嗅探结果」面板时会扫一次，面板右上角「⋯ → 重新扫描」也能手动扫。\n\n关掉**不影响任何下载能力** —— 长按视频照旧能下；页面发过哪些网址也照旧被记下来。关掉的只是「反复扫页面 + 反复上报」这一件事。\n\n上面那个只管页面上要不要留一个圆按钮，跟嗅探跑不跑无关。")
                }

                Section {
                    Toggle("网页广告清理", isOn: $adClean)
                        .onChange(of: adClean) { _ in model.applyAdCleanSetting() }
                    Button("本页恢复被隐藏的层") { model.restoreAdCleanOnThisPage() }
                } header: {
                    Text("网页广告清理")
                } footer: {
                    Text("清掉盖在页面上的浮层广告（插屏大图、赌场浮层这种），并拦住「点它的 X 反而跳走」。\n\n**只隐藏、不删原样** —— 关掉开关会立刻还原。\n\n万一某页被误清了（缺一块 / 整片灰）：页面顶部会出一条提示、点「撤销」就行；没看到那条就用上面这个按钮。\n\n**不会再自动把网站拉黑了** —— 旧版本会，那正是「某些站突然不清理了」的根源。\n\n做不到的：画成图片/画布里的广告、跨域子窗口里的广告。")
                }

                // 例外名单单独一个小 View（见文件末尾 AdCleanSkipList）—— 它自己管刷新，
                // 不用在这里找 Form 的收尾括号去挂 onAppear。
                AdCleanSkipList(model: model)
                // ★ v1.0.212：「点选清理」保存下来的规则（保存错了要能自己清掉）
                AdCleanRuleList(model: model)

                Section {
                    Toggle("长按视频弹下载菜单", isOn: $lpDownload)
                    Toggle("长按诊断", isOn: $lpDebug)
                } header: {
                    Text("长按下载")
                } footer: {
                    Text("上面那个管功能，下面那个只管排查 —— 两个互不影响。\n诊断开着时，每次长按会在屏幕顶部显示一行过程记录，8 秒自动消失，点一下立刻关掉。平时关着。")
                }

                Section {
                    Button {
                        if let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        }
                    } label: {
                        Label("打开系统设置（网络权限在这里）", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("网络")
                } footer: {
                    Text("国行 iPhone 第一次装 App 会弹一次「允许“视频抓取”使用数据?」—— 选「无线局域网与蜂窝网络」就行。\n**这个弹窗一辈子只弹一次**：要是当时点了“不允许”，系统不会再来问，得去「设置 → 蜂窝网络 → 使用无线局域网与蜂窝网络」里手动打开（上面那个按钮直接跳过去）。\n另外「共享给电脑」用的是**本地网络**权限，是另一个弹窗，也只问一次。")
                }

                Section {
                    Button { showHelp = true } label: {
                        Label("使用说明", systemImage: "questionmark.circle")
                    }
                }

                Section("关于") {
                    labeled("版本", Self.version)
                    Link("项目仓库",
                         destination: URL(string: "https://github.com/luowenbin061-blip/video-grab")!)
                }

                if let note {
                    Section { Text(note).font(.system(size: 13)) }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { trustedCount = TrustedHosts.count }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .alert("清空浏览历史？", isPresented: $confirmClearHistory) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clearHistory() }
            } message: {
                Text("全部删掉，删了就找不回来了。收藏不受影响。")
            }
            // 说明页自己带导航栏，所以用弹窗打开，别嵌进来（嵌了会套两层导航栏）
            .sheet(isPresented: $showHelp) { HelpView() }
            // ★ v1.0.164：书签 + 已删的下载文件合成**一个**入口、一张卡（用户要「全局」回收站）
            .sheet(isPresented: $showTrash) {
                RecycleBinView(store: store, downloads: downloads, isPresented: $showTrash)
            }
        }
    }

    // MARK: - 零件

    /// 回收站那一行右边的小字 —— 用户要「全局」一个入口，所以**书签和文件两样都要报**，
    /// 不然点进去之前根本不知道里面有什么。
    private var binSummary: String {
        let m = store.trash.count, f = bin.count
        if m == 0 && f == 0 { return "空" }
        var parts: [String] = []
        if m > 0 { parts.append("书签 \(m)") }
        if f > 0 { parts.append("文件 \(f)") }
        return parts.joined(separator: " · ")
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary)
        }
    }

    /// 画中画开关：这里点的时候 App 一定在前台 —— 正好符合「必须前台起画中画」的要求
    private var pipBinding: Binding<Bool> {
        Binding(get: { downloads.pip.isRunning },
                set: { on in
                    if on { downloads.pip.start() } else { downloads.pip.stop() }
                })
    }

    /// 固定口令开关（v1.0.102）。用 @AppStorage 直接绑 UserDefaults ——
    /// LocalHTTPServer 读的是同一个 key，两边天然一致。
    @AppStorage("vg.fixedTokenOn") private var fixedTokenOn = false

    private var shareBinding: Binding<Bool> {
        Binding(get: { downloads.lanOn },
                set: { on in
                    if on {
                        if downloads.startSharing() == nil {
                            note = "没能开启共享。先确认手机连着 Wi-Fi，并且系统设置里允许「视频抓取」访问本地网络。"
                        } else {
                            note = nil
                        }
                    } else {
                        downloads.stopSharing()
                        note = nil
                    }
                })
    }

    /// 清理下载临时分片（v1.0.101）。正在下载的任务会跳过 —— 清了会把它们弄坏。
    /// 成品视频、回收站、记录都不动。
    ///
    /// ★★ v1.0.149：挪到**后台线程** + 「清理中…」提示。
    ///   以前这条在**界面线程**上同步扫整个下载目录再逐个删 —— 临时分片多的时候
    ///   （几百上千个文件）整个设置页都是死的，用户报的"清除缓存时卡死"就是它。
    private func cleanupTemp() {
        guard !isCleaning else { return }        // 防连点：上一次还没完
        isCleaning = true
        let active = Set(downloads.jobs.filter { $0.isActive }.map { $0.id.uuidString })
        // ★ v1.0.160：正在压的那条，它的 `.partial` 还得用 —— 主线程先问一句再进后台
        let compressing = CompressQueue.shared.isRunning
        Task.detached(priority: .userInitiated) {
            let freed = JobStore.cleanupTemp(keeping: active, keepPartials: compressing)
            await MainActor.run {
                note = freed > 0
                    ? "已清理下载临时文件，释放约 \(max(1, freed / 1048576))MB"
                        + (active.isEmpty ? "。" : "（正在下载的 \(active.count) 个任务已跳过）")
                    : "没有需要清理的临时文件。"
                // ★ v1.0.154：清理改的是磁盘，顺手把"已用空间"刷新（下载列表那行才准）
                downloads.refreshUsedSpace()
                isCleaning = false
            }
        }
    }

    /// 只清缓存文件，**不动 Cookie** —— 免得一清就把各站的登录状态清掉
    private func clearWebCache() {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                note = "网页缓存已清除（Cookie 没动，登录状态还在）。"
            }
        }
    }

    /// "最近一次放行"的时间格式（短，够看就行）
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return v
    }
}

/// 「不清理的网站」名单（设置页里那一节）。
///
/// ★ 为什么单独拎出来：`AdClean.skipHosts` 读的是 UserDefaults，**不是 SwiftUI 状态** ——
///   删掉一条之后列表不会自己重画。所以要拿 `@State` 抄一份、在 `onAppear` 里刷新。
///   单独一个 View 就能把 `onAppear` 挂在自己身上，不用去改主设置页 Form 的结构。
private struct AdCleanSkipList: View {

    @ObservedObject var model: BrowserModel
    @State private var hosts: [String] = AdClean.skipHosts

    var body: some View {
        if hosts.isEmpty {
            EmptyView()
        } else {
            Section {
                ForEach(hosts, id: \.self) { h in
                    HStack {
                        Text(h).font(.system(size: 13))
                        Spacer()
                        Button("恢复清理") {
                            AdClean.removeSkip(h)
                            model.applyAdCleanSkipList()
                            hosts = AdClean.skipHosts
                            model.showToast("已恢复清理：\(h)")
                        }
                        .font(.system(size: 13))
                    }
                }
                // ★ v1.0.212：一键清空 —— 专门用来救**被旧版本自动塞满**的名单
                Button("清空这份名单（\(hosts.count) 个）") {
                    model.clearAdCleanSkipList()
                    hosts = AdClean.skipHosts
                }
                .font(.system(size: 13))
                .foregroundStyle(.red)
            } header: {
                Text("不做自动清理的网站（\(hosts.count) 个）")
            } footer: {
                Text("这些网站不会**自动**清理（你手动用「清理浮层」还是可以的）。\n\n**如果里面有一堆你没加过的站，那就是旧版本自动塞进去的** —— 点上面那个红色按钮一次清掉，问题就没了。")
            }
            .onAppear { hosts = AdClean.skipHosts }
        }
    }
}

/// 「点选清理保存下来的规则」管理（设置页里那一节）。
///
/// ★ 这是"点选保存"带来的责任：保存错了得能自己清掉，否则那个站会一直缺一块。
private struct AdCleanRuleList: View {

    @ObservedObject var model: BrowserModel
    @State private var hosts: [String] = AdClean.ruleHosts

    private func refresh() { hosts = AdClean.ruleHosts }

    var body: some View {
        if hosts.isEmpty {
            EmptyView()
        } else {
            Section {
                ForEach(hosts, id: \.self) { h in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h).font(.system(size: 13))
                            Text("\((AdClean.savedRules[h] ?? []).count) 条规则")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("清除") {
                            model.clearAdCleanRules(for: h)
                            refresh()
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                    }
                }
                Button("全部清空（\(hosts.count) 个网站）") {
                    model.clearAllAdCleanRules()
                    refresh()
                }
                .font(.system(size: 13))
                .foregroundStyle(.red)
            } header: {
                Text("点选清理保存的规则（\(hosts.count) 个网站）")
            } footer: {
                Text("这些是你**用「点选清理」亲手删过**的东西 —— 刷新页面时它们会在**画出来之前**就被隐藏。\n\n如果某页因此缺了一块，在这里把那个站「清除」掉就好。")
            }
            .onAppear { refresh() }
        }
    }
}
