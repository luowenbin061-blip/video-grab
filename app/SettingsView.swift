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
    /// 播放小窗（App 里播放视频时切出去继续播）。
    /// 跟「下载保活」是两件事，所以是两个开关。
    @AppStorage("playerPiPEnabled") private var playerPiP = true
    /// 长按视频弹下载菜单（默认开）。关掉 = 完全不接管长按，页面怎么长按都跟我们无关
    @AppStorage("lpLongPressDownload") private var lpDownload = true
    /// 长按诊断（默认关）：只在排查「长按没反应」时打开，会在屏幕顶部显示一行过程记录
    @AppStorage("lpDebug") private var lpDebug = false
    /// 嗅探按钮要不要一直待在屏幕上（默认关：不占地方）
    @AppStorage("sniffButtonResident") private var sniffResident = false
    /// 已经放行过的网站数（证书不被信任、但按设置一律放行）。进页面时读一次。
    @State private var trustedCount = 0
    /// 启动主页（v1.0.90）。**留空 = 每次打开只显示空白页**。
    @AppStorage("homePageURL") private var homePage = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("下载保活（切后台下载不停）", isOn: pipBinding)
                    if let e = downloads.pip.lastError {
                        Text(e).font(.system(size: 12)).foregroundStyle(.orange)
                    } else if !downloads.pip.isSupported {
                        Text("这台设备不支持画中画。").font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("播放小窗（切出去继续播）", isOn: $playerPiP)
                } header: {
                    Text("画中画")
                } footer: {
                    Text("下载保活：开了会立刻出现一个小窗，里面是下载进度；随时关小窗即可停用。\n播放小窗：在 App 里播视频时切到别的 App，画面缩成小窗继续播（也能直接点播放器上的画中画按钮）。\n两个小窗同时只能有一个 —— 播放时下载保活窗会先让位，播完自动还回来。")
                }

                Section {
                    Toggle("共享给电脑（同一 Wi-Fi）", isOn: shareBinding)
                    if downloads.lanOn, let u = LocalHTTPServer.shared.lanURL?.absoluteString {
                        Text(u)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("局域网共享")
                } footer: {
                    Text("手机里的视频通过本机地址给电脑下载。地址带一串口令，用完记得关掉。")
                }

                Section("浏览数据") {
                    labeled("收藏", "\(store.marks.count) 条")
                    labeled("浏览历史", "\(store.history.count) 条")
                    Button("清空浏览历史", role: .destructive) { confirmClearHistory = true }
                    Button("清除网页缓存") { clearWebCache() }
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
                    Toggle("嗅探按钮常驻屏幕", isOn: $sniffResident)
                } header: {
                    Text("嗅探")
                } footer: {
                    Text("关掉（默认）那个按钮就不占屏幕了 —— 嗅探结果改从「功能」卡片或「工具箱」里打开。\n**后台嗅探一直在跑，跟这个按钮没关系**：显示这个开关只影响页面上要不要留那个圆按钮。")
                }

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
                    Text("国行 iPhone 第一次装 App 会弹一次「允许"视频抓取"使用数据?」—— 选「无线局域网与蜂窝网络」就行。\n**这个弹窗一辈子只弹一次**：要是当时点了"不允许"，系统不会再来问，得去「设置 → 蜂窝网络 → 使用无线局域网与蜂窝网络」里手动打开（上面那个按钮直接跳过去）。\n另外「共享给电脑」用的是**本地网络**权限，是另一个弹窗，也只问一次。")
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
        }
    }

    // MARK: - 零件

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
