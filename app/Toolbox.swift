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
            note = "没从这个文件里读到书签。\n支持各家浏览器导出的「书签 HTML」，以及 Chromium 的书签 JSON。"
            return
        }
        let r = store.importMarks(entries)
        note = "导入完成：新增 \(r.added) 条"
            + (r.skipped > 0 ? "，跳过 \(r.skipped) 条（重复或地址无效）" : "")
            + "。到「收藏 / 历史」里看（导入的单独归一组）。"
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

}
