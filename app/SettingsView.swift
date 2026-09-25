import SwiftUI
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

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return v
    }
}
