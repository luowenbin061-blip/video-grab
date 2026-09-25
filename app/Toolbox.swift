import SwiftUI
import UIKit

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
    @Binding var isPresented: Bool
    /// 打开「嗅探结果」面板 —— 面板在主页那层，所以由那边传进来
    let onOpenSniff: () -> Void

    @State private var note: String?
    @State private var showImportSource = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button { find() } label: {
                        item("magnifyingglass", "页内查找", "系统原生查找条，和 Safari 一样")
                    }
                    Button { translateNotReady() } label: {
                        item("character.book.closed", "翻译整个网页",
                             "暂缓：以后再做（要原地翻译，不是跳出去翻）", dim: true)
                    }
                } header: {
                    Text("当前网页")
                } footer: {
                    Text("翻译暂缓 —— 之前那条「跳到百度翻译」是跳出去翻，不是原地翻译，不算数。要做就做「原地把页面文字翻成中文、还能一键切回原文」那种，等以后再说。")
                }

                Section {
                    Button { onOpenSniff() } label: {
                        item("antenna.radiowaves.left.and.right", "嗅探结果",
                             model.items.isEmpty
                             ? "这个页面暂时没嗅到地址（一直点着刷新时它会自己补上）"
                             : "这个页面嗅探到 \(model.items.count) 条地址，点开看/下载")
                    }
                } header: {
                    Text("嗅探")
                } footer: {
                    Text("嗅探一直在后台跑（看页面请求、资源加载记录、页面变量、页面里的播放器元素），跟你看不看这个列表无关。")
                }

                Section {
                    Button { showImportSource = true } label: {
                        item("square.and.arrow.down.on.square", "导入视频",
                             "从相册或「文件」选视频放进下载列表，可多选")
                    }
                } header: {
                    Text("导入")
                } footer: {
                    Text("导入的视频和下载的放在一起。系统能播的原样收下；播不了的自动转成 MP4。")
                }

                if let note {
                    Section { Text(note).font(.system(size: 13)) }
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
        }
    }

    private func item(_ icon: String, _ title: String, _ sub: String,
                      dim: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15))
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(dim ? Color.secondary : Color.primary)
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

    private func translateNotReady() {
        note = "翻译暂缓了。要做就做「原地把页面文字翻成中文、还能一键切回原文」那种 —— 等你说开工再做。"
    }
}
