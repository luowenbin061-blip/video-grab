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
    /// ★ v1.0.127 备份：点"备份数据"先问一句（备份 / 恢复）
    @State private var showBackupOptions = false
    /// 从备份恢复：选那个 json 文件
    @State private var showRestorePicker = false
    /// 备份好了 → 直接弹**文件夹选择器**（用户要的是"存到哪儿"，不是再点一次分享面板）
    @State private var backupSheet: SheetURL?

    // ★ v1.0.119：这两个开关直接读 UserDefaults（@AppStorage）——
    //   这样"已开/已关"的字样会跟着状态自己变，不用把整个 BrowserModel 订阅进来。
    @AppStorage("desktopUA") private var desktopUA = false
    @AppStorage("noImageMode") private var noImage = false

    var body: some View {
        NavigationView {
            ScrollView {
                // ★★ v1.0.150：3 列 × 3 行 —— 9 个工具正好对称，卡片等高；
                //   状态不再用副标题长文（参差不齐的根源），改用图标角标：
                //   嗅探结果 = 数量徽标；桌面/无图模式 = 开着时绿点。
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    cell("magnifyingglass", "页内查找", .blue) { find() }
                    cell("antenna.radiowaves.left.and.right", "嗅探结果", .orange,
                         badge: model.items.count) { onOpenSniff() }
                    cell("square.and.arrow.down.on.square", "导入视频", .green) {
                        showImportSource = true
                    }
                    cell("book.closed.fill", "导入书签", .purple) {
                        showBookmarkPicker = true
                    }

                    // ★ v1.0.119 新增四格
                    // 说明：桌面模式 / 无图模式都是「开关」——副标题直接写当前状态，
                    // 点一下切换（不是进二级页面）。
                    cell("desktopcomputer", "桌面模式", .indigo, isOn: desktopUA) {
                        model.toggleDesktopUA()
                        // ★ desktopUA 是本视图的 @AppStorage（不是 model 的）——v1.0.150 就写错了
                        note = desktopUA ? "桌面模式已开" : "桌面模式已关"
                    }
                    cell("eye.slash", "无图模式", .gray, isOn: noImage) {
                        model.toggleNoImage()
                        note = noImage ? "无图模式已开（图片不下载）" : "无图模式已关"
                    }
                    cell("square.and.arrow.up", "分享本页", .blue) { share() }

                    // ★ v1.0.122：导出 PDF —— WebKit 自己排版的**矢量** PDF，一次成型。
                    //   ★ v1.0.124：原来的「截长图」（逐屏截图再拼）**已删** ——
                    //     那条路一直拼不干净（接缝、固定栏重复、有些页干脆截不动），
                    //     而 PDF 能转出干净的长图，等于把它替代掉了。
                    //     点这格会问一句：只要 PDF，还是顺带也转一张图片。
                    cell("doc.richtext", "导出 PDF", .red) { showPDFOptions = true }

                    // ★ v1.0.127 备份 / 恢复 —— 这是个单机 App（没 iCloud、没账号），
                    //   重装 IPA / 换机 / 手滑删了 App，攒的书签·记录·首页·进度就全没了。
                    //   点开弹一句"备份 还是 恢复"，不在这一页上摊两个按钮。
                    cell("externaldrive.badge.timemachine", "备份数据", .cyan) { showBackupOptions = true }
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
            // ★ v1.0.127 备份 / 恢复：两件事一个入口
            .confirmationDialog("数据备份", isPresented: $showBackupOptions,
                                titleVisibility: .visible) {
                Button("备份数据（存一个文件）") { doBackup() }
                Button("从备份恢复（会覆盖现在数据）") { showRestorePicker = true }
                Button("取消", role: .cancel) {}
            } message: {
                // ★ 必须是**单个字面量**：Text(拼接出来的 String) 不渲染 markdown，会露出 **
                Text("打包：书签、下载记录、首页入口、播放进度、已放行网站、设置。**不含 Cookie**（登录态不外带）。\n恢复前会自动把当前数据另存一份，能回滚。")
            }
            .sheet(isPresented: $showRestorePicker) {
                FilePickerBox(onPicked: { files in doRestore(files) }, types: [.json])
            }
            // ★ v1.0.131：备份包好了 → 直接让你选文件夹存出去（跟「存文件夹」同一个选择器）
            .sheet(item: $backupSheet) { s in
                DocumentExporter(url: s.url, onFinish: { ok in
                    note = ok ? "备份已保存到你选的位置（App 内还留了最近一份）" : "已取消保存。"
                })
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
                      badge: Int? = nil, isOn: Bool = false,
                      tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(color)
                    .frame(height: 28)
                    .overlay(alignment: .topTrailing) {
                        if let badge, badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 9, y: -5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isOn {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .offset(x: 7, y: -3)
                        }
                    }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// ★ v1.0.119 分享本页 / ★ v1.0.132 修：**不要先关工具箱**。
    /// 原因跟备份那次一模一样：`isPresented = false` 会把工具箱这个 View 一起销毁，
    /// 挂在上面的分享面板就没人响应了（现象是"点了没反应"）。
    /// 分享不需要"网页视图在最前面"，直接弹就行 —— 「从备份恢复」一直是这么干的，没问题。
    private func share() {
        guard let s = model.currentURL, let u = URL(string: s) else {
            note = "还没打开网页，没得分享。"
            return
        }
        shareItem = SheetURL(url: u)
    }

    /// ★ v1.0.127 备份 / v1.0.131 改：生成 JSON → **直接弹文件夹选择器**让你挑存哪儿。
    ///   上一版走的是系统分享面板（还得在里面点一次"存储到文件"才能选目录）——
    ///   用户的原话是"为什么没让我选文件夹"，那就一步到位，跟「存文件夹」一个手感。
    private func doBackup() {
        do {
            let d = try DataBackup.exportData()
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            // 顺手把上一次留在 App 里的备份清掉（它只当"最近一份"，不该越攒越多）
            if let old = try? FileManager.default.contentsOfDirectory(atPath: JobStore.dir.path) {
                for n in old where n.hasPrefix("VideoGrab备份-") && n.hasSuffix(".json") {
                    try? FileManager.default.removeItem(
                        at: JobStore.file(named: n))
                }
            }
            let u = JobStore.file(named: "VideoGrab备份-\(f.string(from: Date())).json")
            try d.write(to: u, options: .atomic)
            // ★★ v1.0.132 这里踩过一个坑，别再改回去：
            //   我原来先写 `isPresented = false`（把工具箱这个 sheet 关掉），350ms 后再设 backupSheet ——
            //   **工具箱这个 View 已经随 sheet 关闭被销毁了**，挂在上面的 .sheet(item:) 根本没人响应
            //   → 用户看到的就是"点了备份，压根没弹选择器"。
            //   对比：下载页的「存文件夹」要关掉外层是因为要"网页视图在最前面"；备份是纯文件操作，不需要关。
            //   （「从备份恢复」一直能弹，就是因为它没关自己。）
            backupSheet = SheetURL(url: u)
        } catch {
            note = "备份失败：\(error.localizedDescription)"
        }
    }

    /// ★ v1.0.127 恢复：**覆盖**当前数据（覆盖前 DataBackup 会自动留一份可回滚）
    private func doRestore(_ files: [SavedFile]) {
        guard let f = files.first, let d = try? Data(contentsOf: f.url) else {
            note = "这个文件读不出来。"
            return
        }
        do {
            note = try DataBackup.restore(from: d)
        } catch {
            note = error.localizedDescription
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
