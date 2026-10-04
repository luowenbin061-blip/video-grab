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
///
/// ★★ v1.0.220：拿两家（亚瑟 / 李白）的设置页截图逐项对齐**观感**。四处改动：
///    · **摘要只留两行**（其余 6 行删掉）—— 我上一版给每一行都挂了摘要，
///      等于把刚砍掉的说明文字又搬回了顶层；两家基本都是光名字、没有摘要。
///      **只有「名字看不出里面装什么」的那两行才留**（通用设置 / 数据与清理）——
///      李白那版的「通用设置 → 手势密码」就是这个道理。
///    · 名称 15 → **17pt**（两家都是 17）；图标 28 → **30pt**（符号 15pt ≈ 一半）；
///      行内再补一点上下留白，把行撑到 ~56pt（两家都是这个高度）。
///    · ★ **没有摘要的行也要占一行的高度**（`sub.isEmpty ? " " : sub`）——
///      这条是外部审查提出、我原来没想到的：只给 2 行留摘要、其余删干净的话，
///      行高会变成"隔几行矮一下"，反而比原来更乱。**8 行高度一致才叫齐。**
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
                    navEntry("网页设置", "",
                             "globe", .blue) {
                        SettingsWebPage(model: model)
                    }
                    navEntry("播放设置", "",
                             "play.circle.fill", .red) {
                        SettingsPlayPage()
                    }
                    navEntry("下载设置", "",
                             "arrow.down.circle.fill", .green) {
                        SettingsDownloadPage(downloads: downloads)
                    }
                    navEntry("通用设置", "启动主页 · 搜索引擎",
                             "gearshape.fill", .orange) {
                        SettingsGeneralPage()
                    }
                }

                Section {
                    navEntry("数据与清理", "收藏 · 历史 · 回收站",
                             "folder.fill", .purple) {
                        SettingsDataPage(model: model, downloads: downloads, store: store)
                    }
                    navEntry("局域网共享", "",
                             "wifi", .teal) {
                        SettingsSharePage(downloads: downloads)
                    }
                }

                Section {
                    Button {
                        showHelp = true
                    } label: {
                        entryLabel("使用说明", "",
                                   "questionmark.circle.fill", .indigo)
                    }
                    // 不写这句，默认样式的按钮只让文字那一小块可点（整行点不动）
                    .buttonStyle(.plain)

                    navEntry("关于", "",
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

    // MARK: - 顶层那一行（只有一种长相：图标 + 名字 + 可选一行小字）

    private func entryLabel(_ title: String, _ sub: String,
                            _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 17))
                // ★★ 没摘要的行**也占一行的高度**：8 行高度一致，才不会有"隔几行矮一下"的节奏。
                //   （用空格而不是空串 —— 空串在 SwiftUI 里不保证占高。）
                Text(sub.isEmpty ? " " : sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
