import SwiftUI
import UIKit
import WebKit

// ═══════════════════════════════════════════════════════════════════════════
// 设置页的二级页（v1.0.218）
//
// ★★ 为什么拆：原来 **一页 15 个 Section 全平铺**，每个开关下面还挂 2~4 行说明 ——
//    想找一个开关要一路往下滚，也看不出"一共有哪几类"。
//    对标李白 / 亚瑟改成「**顶层只有入口，细节在二级页**」。
//
// ★★ 说明文字的原则（用户 2026-10-04 定的三条之二）：
//    **能靠命名讲清楚的，就别写说明。** footer 只留两样东西：
//      ① 名字看不出来的**后果 / 坑**（如"关掉会把已记录的进度一并清掉"）
//      ② 反直觉的点（如"关掉自动嗅探不影响下载能力"）
//    其余的（"开着会怎样、关着会怎样"那种铺陈）全砍。
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - 共用零件

/// 二级页行首那个彩色圆角小方块（白色符号）—— 对标李白 / 亚瑟的设置页。
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        // ★ v1.0.220：28 → **30pt**（对齐两家），里面的符号 15pt ≈ 方块的一半
        //   （Apple 设置图标就是这个比例）。
        //   圆角保持 8 + `.continuous`（squircle）：外部审查建议过 5.25（按 Apple 原生比例算的），
        //   但**我们的验收标准是亚瑟 / 李白** —— 那两家的圆角明显更大，所以不动。
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 「左边名字 / 右边值」那一行。
func settingsKVRow(_ k: String, _ v: String) -> some View {
    HStack {
        Text(k)
        Spacer()
        Text(v).foregroundStyle(.secondary)
    }
}

/// 设置页共用的小工具（时间格式 / 版本号）。
enum SettingsMeta {
    /// 「最近一次放行」的时间（短，够看就行）
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - 网页设置

/// 网页设置：广告清理 / 嗅探 / 长按 / 页面呈现 / 证书
struct SettingsWebPage: View {
    @ObservedObject var model: BrowserModel

    @AppStorage(AdClean.key) private var adClean = true
    @AppStorage("autoSniff") private var autoSniff = false
    @AppStorage("sniffButtonResident") private var sniffResident = false
    @AppStorage("lpLongPressDownload") private var lpDownload = true
    @AppStorage("lpDebug") private var lpDebug = false
    @AppStorage("desktopUA") private var desktopUA = false
    @AppStorage("noImageMode") private var noImage = false

    @State private var trustedCount = 0
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Toggle("网页广告清理", isOn: $adClean)
                    .onChange(of: adClean) { _ in model.applyAdCleanSetting() }
            } footer: {
                Text("误清了某个网站（页面缺一块、放不出来）→ 关掉它再刷新一次。")
            }

            Section {
                Toggle("后台自动嗅探", isOn: $autoSniff)
                    .onChange(of: autoSniff) { _ in model.applyAutoSniffSetting() }
                Toggle("嗅探按钮常驻屏幕", isOn: $sniffResident)
            } footer: {
                Text("关掉「自动嗅探」不影响下载 —— 长按照旧能下、页面发过的网址照旧被记下来，只是不再自动刷新结果。")
            }

            Section {
                Toggle("长按视频弹下载菜单", isOn: $lpDownload)
                Toggle("长按诊断", isOn: $lpDebug)
            } footer: {
                Text("「诊断」只在排查「长按没反应」时打开：每次长按会在屏幕顶部显示一行过程记录。")
            }

            // ★ 这两个原来在「工具箱」里是用 `model.toggleXxx()` 切的（那个方法是**反转**），
            //   所以这里**绝不能**写成 `.onChange { model.toggleXxx() }` ——
            //   @AppStorage 会先把新值写进 UserDefaults，toggle 再反转一次 → 开关自己弹回去。
            //   正解：Binding 的 set 里**先比较再 toggle**（值真变了才动）。
            Section {
                Toggle("桌面版网站", isOn: Binding(
                    get: { desktopUA },
                    set: { on in if on != desktopUA { model.toggleDesktopUA() } }))
                Toggle("无图模式", isOn: Binding(
                    get: { noImage },
                    set: { on in if on != noImage { model.toggleNoImage() } }))
            } footer: {
                Text("桌面版：让网站按电脑版加载（有些站桌面版功能更全）。\n无图模式：图片不下载，省流量。")
            }

            Section {
                settingsKVRow("已放行的网站", "\(trustedCount) 个")
                if let last = TrustedHosts.lastApproved {
                    settingsKVRow("最近一次放行", last.host)
                    settingsKVRow("时间", SettingsMeta.short.string(from: last.at))
                }
                if trustedCount > 0 {
                    Button("忘掉所有已放行的网站", role: .destructive) {
                        TrustedHosts.forgetAll()
                        trustedCount = TrustedHosts.count
                        note = "已忘记。下次打开会再提醒一次 —— 页面照常放行。"
                    }
                }
            } header: {
                Text("证书")
            } footer: {
                Text("证书不被系统信任的网站一律照常打开，只在第一次提醒一句。")
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle("网页设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { trustedCount = TrustedHosts.count }
    }
}

// MARK: - 播放设置

/// 播放设置：续看进度 / 横屏 / 后台声音 / 播放小窗
struct SettingsPlayPage: View {
    @AppStorage(WatchProgress.enabledKey) private var resumeEnabled = false
    @AppStorage(PlayerBox.autoLandscapeKey) private var autoLandscape = false
    @AppStorage(PlayerBox.backgroundAudioKey) private var bgAudio = true
    @AppStorage("playerPiPEnabled") private var playerPiP = true

    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Toggle("记录播放进度（下次接着看）", isOn: $resumeEnabled)
                    .onChange(of: resumeEnabled) { on in
                        // 关掉时**一并清空**已有进度：留着的话，下次再打开开关会突然冒出一堆
                        // "续看位置"，中间隔了很久，早就想不起那是什么了。
                        WatchProgress.setEnabled(on)
                        if !on { note = "已关闭续看，之前记录的播放进度也一并清掉了。" }
                    }
                Toggle("首次播放自动横屏", isOn: $autoLandscape)
                Toggle("后台播放声音（切走 / 锁屏继续出声）", isOn: $bgAudio)
            } footer: {
                Text("「后台播放声音」改完**下次打开播放器**生效。")
            }

            Section {
                Toggle("播放小窗（切出去继续播）", isOn: $playerPiP)
            } footer: {
                Text("切到别的 App 时画面缩成小窗继续播（也能直接点播放器上的画中画按钮）。")
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle("播放设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 下载设置

/// 下载设置：并发数 / 下载保活 / 压缩保活
struct SettingsDownloadPage: View {
    @ObservedObject var downloads: DownloadCenter

    @AppStorage(DownloadCenter.maxConcurrentKey) private var maxConcurrent = 0
    @AppStorage(CompressQueue.keepAliveKey) private var compressKeepAlive = true

    var body: some View {
        Form {
            Section {
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
            } footer: {
                Text("超出的自动排队；改小只影响之后开跑的任务，正在跑的不打断。")
            }

            Section {
                Toggle("下载保活（切后台下载不停）", isOn: pipBinding)
                if let e = downloads.pip.lastError {
                    Text(e).font(.system(size: 12)).foregroundStyle(.orange)
                } else if !downloads.pip.isSupported {
                    Text("这台设备不支持画中画。").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("开着会立刻出现一个小窗（里面是下载进度），关掉那个小窗即可停用。")
            }

            Section {
                Toggle("压缩保活（切走也能压）", isOn: $compressKeepAlive)
            } footer: {
                Text("关掉的话，压的时候**别切走、别锁屏** —— 会被系统挂起，那一条从头再来。")
            }
        }
        .navigationTitle("下载设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 下载保活：这里点的时候 App 一定在前台 —— 正好符合「必须前台起画中画」的要求。
    private var pipBinding: Binding<Bool> {
        Binding(get: { downloads.pip.isRunning },
                set: { on in
                    if on { downloads.pip.start() } else { downloads.pip.stop() }
                })
    }
}

// MARK: - 通用设置

/// 通用设置：启动主页 / 搜索引擎
struct SettingsGeneralPage: View {
    @AppStorage("homePageURL") private var homePage = ""
    @AppStorage(SearchEngine.key) private var searchEngine = SearchEngine.baidu.rawValue
    @AppStorage(SearchEngine.customKey) private var searchEngineCustom = ""

    var body: some View {
        Form {
            Section {
                TextField("留空 = 只显示空白页", text: $homePage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.system(size: 14))
            } header: {
                Text("启动主页")
            } footer: {
                Text("填了网址：每次打开固定打开它。\n两种情况上次的标签都会恢复，只是待在后台。")
            }

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
                Text("地址栏里输的不是网址时，用它去搜。自定义模板必须含 %@。")
            }
        }
        .navigationTitle("通用设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据与清理

/// 数据与清理：收藏 / 历史 / 回收站 / 各种清理
struct SettingsDataPage: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var store: BookmarkStore
    /// 全局回收站（书签 + 已删的下载文件）—— 单例，只订阅它的计数变化
    @ObservedObject private var bin = FileBin.shared

    @State private var confirmClearHistory = false
    @State private var showTrash = false
    @State private var note: String?
    /// 清理临时文件进行中（防连点 + 按钮显示"清理中…"）
    @State private var isCleaning = false

    var body: some View {
        Form {
            // ★ 注意别写成 `Section("浏览数据") { ... } footer: { ... }` ——
            //   带标题的那个便利 init **没有 footer 参数**，编译报
            //   "generic parameter 'Content' could not be inferred"。统一用 header: 写。
            Section {
                settingsKVRow("收藏", "\(store.marks.count) 条")
                settingsKVRow("浏览历史", "\(store.history.count) 条")
                Button {
                    showTrash = true
                } label: {
                    HStack {
                        Text("回收站")
                        Spacer()
                        Text(binSummary).foregroundStyle(.secondary)
                    }
                }
                Button("清空浏览历史", role: .destructive) { confirmClearHistory = true }
                Button("清除网页缓存") { clearWebCache() }
                Button {
                    cleanupTemp()
                } label: {
                    HStack(spacing: 6) {
                        if isCleaning { ProgressView().controlSize(.small) }
                        Text(isCleaning ? "清理中…" : "清理下载临时文件")
                    }
                }
                .disabled(isCleaning)
                Button("清空标签存档（下次启动是空白页）", role: .destructive) {
                    model.wipeSavedTabs()
                }
            } header: {
                Text("浏览数据")
            } footer: {
                Text("「清空标签存档」下次启动就是干净的空白页（标签组也一起没）。")
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle("数据与清理")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清空浏览历史？", isPresented: $confirmClearHistory) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearHistory() }
        } message: {
            Text("全部删掉，删了就找不回来了。收藏不受影响。")
        }
        .sheet(isPresented: $showTrash) {
            RecycleBinView(store: store, downloads: downloads, isPresented: $showTrash)
        }
    }

    /// 回收站那一行右边的小字 —— 书签和文件两样都要报，不然点进去之前不知道里面有什么。
    private var binSummary: String {
        let m = store.trash.count, f = bin.count
        if m == 0 && f == 0 { return "空" }
        var parts: [String] = []
        if m > 0 { parts.append("书签 \(m)") }
        if f > 0 { parts.append("文件 \(f)") }
        return parts.joined(separator: " · ")
    }

    /// 清理下载临时分片。正在下载的会跳过 —— 清了会把它们弄坏。
    /// 成品视频、回收站、记录都不动。
    /// ★ 挪到后台线程 + 「清理中…」提示：以前在界面线程上同步扫整个下载目录再逐个删，
    ///   临时分片多的时候（几百上千个）整个设置页都是死的。
    private func cleanupTemp() {
        guard !isCleaning else { return }        // 防连点：上一次还没完
        isCleaning = true
        let active = Set(downloads.jobs.filter { $0.isActive }.map { $0.id.uuidString })
        // 正在压的那条，它的 `.partial` 还得用 —— 主线程先问一句再进后台
        let compressing = CompressQueue.shared.isRunning
        Task.detached(priority: .userInitiated) {
            let freed = JobStore.cleanupTemp(keeping: active, keepPartials: compressing)
            await MainActor.run {
                note = freed > 0
                    ? "已清理下载临时文件，释放约 \(max(1, freed / 1048576))MB"
                        + (active.isEmpty ? "。" : "（正在下载的 \(active.count) 个任务已跳过）")
                    : "没有需要清理的临时文件。"
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
}

// MARK: - 局域网共享

/// 局域网共享：把手机里的视频给电脑下载
struct SettingsSharePage: View {
    @ObservedObject var downloads: DownloadCenter

    /// 固定口令开关。用 @AppStorage 直接绑 UserDefaults ——
    /// LocalHTTPServer 读的是同一个 key，两边天然一致。
    @AppStorage("vg.fixedTokenOn") private var fixedTokenOn = false
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Toggle("共享给电脑（同一 Wi-Fi）", isOn: shareBinding)
                if downloads.lanOn, let u = LocalHTTPServer.shared.lanURL?.absoluteString {
                    Text(u)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
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
            } footer: {
                Text("手机里的视频通过本机地址给电脑下载，用完记得关掉。\n"
                     + "「记住口令」= 地址从此不变（电脑上存一次书签就行）；"
                     + "代价是同一 Wi-Fi 下拿到过它的人也能一直进，所以默认不开。")
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle("局域网共享")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shareBinding: Binding<Bool> {
        Binding(get: { downloads.lanOn },
                set: { on in
                    if on {
                        if downloads.startSharing() == nil {
                            note = "没能开启共享。先确认手机连着 Wi-Fi，"
                                 + "并且系统设置里允许「视频抓取」访问本地网络。"
                        } else {
                            note = nil
                        }
                    } else {
                        downloads.stopSharing()
                        note = nil
                    }
                })
    }
}

// MARK: - 关于

/// 关于：版本 / 网络权限 / 项目仓库
struct SettingsAboutPage: View {
    var body: some View {
        Form {
            Section {
                settingsKVRow("版本", SettingsMeta.version)
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u)
                    }
                } label: {
                    Label("打开系统设置（网络权限在这里）",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
            } footer: {
                Text("第一次装 App 的联网弹窗**一辈子只弹一次**；当时点了「不允许」的话，"
                     + "从上面这个按钮进去打开。")
            }

            Section {
                Link("项目仓库",
                     destination: URL(string: "https://github.com/luowenbin061-blip/video-grab")!)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
