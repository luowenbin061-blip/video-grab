import SwiftUI
import WebKit

/// 设置。所有开关都收在这一页里，不往主界面加按钮。
struct SettingsView: View {
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool

    @State private var confirmClearHistory = false
    @State private var showHelp = false
    @State private var note: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("画中画保活（切后台下载不停）", isOn: pipBinding)
                    if let e = downloads.pip.lastError {
                        Text(e).font(.system(size: 12)).foregroundStyle(.orange)
                    } else if !downloads.pip.isSupported {
                        Text("这台设备不支持画中画。").font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("后台保活")
                } footer: {
                    Text("开启后立刻出现一个画中画小窗，里面就是下载进度。回前台不会自动关掉它，随时关小窗即可停用。")
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
