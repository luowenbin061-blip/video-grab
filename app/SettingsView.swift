import SwiftUI

/// 设置 —— **顶层只列入口**，具体开关都在二级页里（见 `SettingsPages.swift`）。
///
/// ★★ v1.0.218 重做。原来是一页 **15 个 Section 全平铺**、每个开关下面还挂 2~4 行说明：
///    找一个开关要一路往下滚，也看不出"一共有哪几类"。
///    对标李白 / 亚瑟改成「**顶层只有入口，点进去才是细节**」。
///
///    用户 2026-10-04 定的三条：
///      ① 顶层越干净越好 —— **顶层不放开关**，一行一个入口；
///      ② 说明文字能砍就砍 —— 能靠命名讲清楚的就不写，
///         footer 只留「名字看不出来的后果 / 反直觉的点」；
///      ③ **功能一项都不删** —— 这一版纯粹是"搬家 + 折叠说明"。
struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool

    /// 使用说明**用弹窗打开**，不放进 NavigationLink —— `HelpView` 自带导航栏，
    /// 嵌进这一层会套出两条导航栏。
    @State private var showHelp = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    navEntry("网页设置", "广告清理 · 嗅探 · 长按 · 证书",
                             "globe", .blue) {
                        SettingsWebPage(model: model)
                    }
                    navEntry("播放设置", "续看进度 · 自动横屏 · 后台声音",
                             "play.circle.fill", .red) {
                        SettingsPlayPage()
                    }
                    navEntry("下载设置", "同时下载数 · 保活 · 压缩保活",
                             "arrow.down.circle.fill", .green) {
                        SettingsDownloadPage(downloads: downloads)
                    }
                    navEntry("通用设置", "启动主页 · 搜索引擎",
                             "gearshape.fill", .orange) {
                        SettingsGeneralPage()
                    }
                }

                Section {
                    navEntry("数据与清理", "收藏 · 历史 · 回收站 · 清缓存",
                             "folder.fill", .gray) {
                        SettingsDataPage(model: model, downloads: downloads, store: store)
                    }
                    navEntry("局域网共享", "共享给电脑 · 记住口令",
                             "wifi", .teal) {
                        SettingsSharePage(downloads: downloads)
                    }
                }

                Section {
                    Button {
                        showHelp = true
                    } label: {
                        entryLabel("使用说明", "怎么用 · 常见问题",
                                   "questionmark.circle.fill", .indigo)
                    }
                    // 不写这句，默认样式的按钮只让文字那一小块可点（整行点不动）
                    .buttonStyle(.plain)

                    navEntry("关于", "版本 · 网络权限 · 项目仓库",
                             "info.circle.fill", .gray) {
                        SettingsAboutPage()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .sheet(isPresented: $showHelp) { HelpView() }
        }
    }

    // MARK: - 顶层那一行（只有一种长相：图标 + 名字 + 一行小字）

    private func entryLabel(_ title: String, _ sub: String,
                            _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 11) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15))
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func navEntry<D: View>(_ title: String, _ sub: String,
                                   _ symbol: String, _ color: Color,
                                   @ViewBuilder dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            entryLabel(title, sub, symbol, color)
        }
    }
}
