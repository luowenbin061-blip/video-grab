import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 工具箱 —— 都只作用于当前网页。
///
/// 截图那一项已按用户要求删除（实测对自用场景没用）。
/// 翻译**暂缓**（用户说了后面再说）：之前那条「跳到百度翻译」是跳出去翻、
/// 不是原地翻译，不算数；真正的原地翻译方案已经调研完（注入 JS 收集文字 →
/// 批量调翻译接口 → 原地替换），等以后要做时直接照那个方案开工。
///
/// ★ 这里必须显式写 @MainActor：BrowserModel 是 @MainActor 类型，
///   用 @ObservedObject / @StateObject 包住它的 View 会被自动推断成 @MainActor，
///   但本页用的是裸 `let model: BrowserModel`，拿不到那层推断 →
///   直接调 model.presentFind() 会被判成 non-isolated 而编译不过。
@MainActor
struct ToolboxView: View {
    let model: BrowserModel
    /// 导入的视频要进下载列表 —— 这是工具箱里第一个不依赖网页的工具
    let center: DownloadCenter
    /// 导入书签要写进收藏（v1.0.90）
    var store: BookmarkStore
    @Binding var isPresented: Bool
    /// 打开「嗅探结果」面板 —— 面板在主页那层，所以由那边传进来
    let onOpenSniff: () -> Void

    @State private var note: String?
    @State private var showImportSource = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    /// 导入书签的文件选择器（v1.0.90）
    @State private var showBookmarkPicker = false
    /// ★ v1.0.119：分享本页
    @State private var shareItem: SheetURL?
    /// ★ v1.0.124：点「导出 PDF」先问一句 —— 只要 PDF，还是顺带也转一张图片
    @State private var showPDFOptions = false

    // ★ v1.0.119：这两个开关直接读 UserDefaults（@AppStorage）——
    //   这样"已开/已关"的字样会跟着状态自己变，不用把整个 BrowserModel 订阅进来。
    @AppStorage("desktopUA") private var desktopUA = false
    @AppStorage("noImageMode") private var noImage = false

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    cell("magnifyingglass", "页内查找", .blue) { find() }
                    cell("antenna.radiowaves.left.and.right", "嗅探结果", .orange,
                         detail: sniffDetail) { onOpenSniff() }
                    cell("square.and.arrow.down.on.square", "导入视频", .green) {
                        showImportSource = true
                    }
                    cell("book.closed.fill", "导入书签", .purple) {
                        showBookmarkPicker = true
                    }

                    // ★ v1.0.119 新增四格
                    // 说明：桌面模式 / 无图模式都是「开关」——副标题直接写当前状态，
                    // 点一下切换（不是进二级页面）。
                    cell("desktopcomputer", "桌面模式", .indigo,
                         detail: desktopUA ? "已开 · 点一下关" : "已关 · 点一下开") {
                        model.toggleDesktopUA()
                    }
                    cell("eye.slash", "无图模式", .gray,
                         detail: noImage ? "已开 · 不下载图片" : "已关 · 点一下开") {
                        model.toggleNoImage()
                    }
                    cell("square.and.arrow.up", "分享本页", .blue) { share() }

                    // ★ v1.0.122：导出 PDF —— WebKit 自己排版的**矢量** PDF，一次成型。
                    //   ★ v1.0.124：原来的「截长图」（逐屏截图再拼）**已删** ——
                    //     那条路一直拼不干净（接缝、固定栏重复、有些页干脆截不动），
                    //     而 PDF 能转出干净的长图，等于把它替代掉了。
                    //     点这格会问一句：只要 PDF，还是顺带也转一张图片。
                    cell("doc.richtext", "导出 PDF", .red,
                         detail: "可顺带转图片") { showPDFOptions = true }
                }
                .padding(16)

                if let note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("工具箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .confirmationDialog("从哪里导入？", isPresented: $showImportSource,
                                titleVisibility: .visible) {
                Button("从相册（可多选）") { showPhotoPicker = true }
                Button("从「文件」（可多选）") { showFilePicker = true }
                Button("取消", role: .cancel) {}
            }
            // ★ v1.0.124：导出 PDF 前的两个形态 —— 用户按场合自己挑
            //   （发 PDF 文件 vs 直接发能看的图）
            .confirmationDialog("整页保存", isPresented: $showPDFOptions,
                                titleVisibility: .visible) {
                Button("只要 PDF（矢量）") { exportPDF(asImage: false) }
                Button("PDF + 图片（能发微信、存相册）") { exportPDF(asImage: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("PDF 的字能选中、能搜索；图片是转出来的长图，能在聊天里直接看。")
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPickerBox { files in
                    center.addImported(files)
                    if !files.isEmpty { isPresented = false }   // 收起卡片，让用户看到导入进度
                }
            }
            .sheet(isPresented: $showFilePicker) {
                FilePickerBox { files in
                    center.addImported(files)
                    if !files.isEmpty { isPresented = false }
                }
            }
            // ★ 导入书签：只认 .html / .json 两种（各家浏览器导出的就是这两种）
            .sheet(isPresented: $showBookmarkPicker) {
                FilePickerBox(onPicked: { files in
                    importBookmarks(files)
                }, types: [.html, .json])
            }
            // ★ v1.0.119：分享本页（系统分享面板）
            .sheet(item: $shareItem) { s in
                ActivityView(items: [s.url])
            }
        }
    }

    /// 嗅探那格的副标题：有结果就报条数，没有就说一句实话
    private var sniffDetail: String {
        model.items.isEmpty ? "这个页面暂时没嗅到" : "\(model.items.count) 条地址"
    }

    /// 一个功能格：大图标 + 短标题（**故意不放长说明** —— 一行字最省地方）
    private func cell(_ icon: String, _ title: String, _ color: Color,
                      detail: String? = nil,
                      tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(color)
                    .frame(height: 30)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 导入书签：解析 → 去重 → 写进收藏，然后把结果说出来
    private func importBookmarks(_ files: [SavedFile]) {
        guard let f = files.first else { return }
        guard let data = try? Data(contentsOf: f.url) else {
            note = "这个文件读不出来。"
            return
        }
        let entries = BookmarkImporter.parse(data)
        guard !entries.isEmpty else {
            note = "没从这个文件里读到书签。\n" + BookmarkImporter.diagnose(data)
            return
        }
        let r = store.importMarks(entries)
        note = "导入完成：新增 \(r.added) 条"
            + (r.updated > 0 ? "，修正分组 \(r.updated) 条" : "")
            + (r.skipped > 0 ? "，跳过 \(r.skipped) 条（重复或地址无效）" : "")
            + "。到「收藏 / 历史」里看（按原文件夹分组）。"
    }

    // MARK: - 动作

    /// 页内查找：先收起这张卡片，等网页那层回到前台再把系统查找条调出来
    private func find() {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let why = model.presentFind() {
                model.showToast(why)          // 起不来说明真实原因，不再一律甩锅系统版本
            }
        }
    }

    /// ★ v1.0.119：分享本页 —— 同样先收起卡片，避免两层 sheet 抢动画
    private func share() {
        guard let s = model.currentURL, let u = URL(string: s) else {
            note = "还没打开网页，没得分享。"
            return
        }
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            shareItem = SheetURL(url: u)
        }
    }

    /// ★ v1.0.122 / v1.0.124：导出 PDF（asImage = 顺带也转一张图片）。
    /// 先收起卡片（渲染要网页视图在最前面），结果由主界面弹分享面板
    /// （见 BrowserModel.pagePDFResult → ContentView.onChange）
    private func exportPDF(asImage: Bool) {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            model.exportPagePDF(asImage: asImage)
        }
    }

}
