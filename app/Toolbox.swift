import SwiftUI
import UIKit

/// 工具箱 —— 都只作用于当前网页。
///
/// 截图那一项已按用户要求删除（实测对自用场景没用）。
/// 翻译正在重做：之前那条「跳到百度翻译」是跳出去翻、不是原地翻译，不算数。
///
/// ★ 这里必须显式写 @MainActor：BrowserModel 是 @MainActor 类型，
///   用 @ObservedObject / @StateObject 包住它的 View 会被自动推断成 @MainActor，
///   但本页用的是裸 `let model: BrowserModel`，拿不到那层推断 →
///   直接调 model.presentFind() 会被判成 non-isolated 而编译不过。
@MainActor
struct ToolboxView: View {
    let model: BrowserModel
    @Binding var isPresented: Bool

    @State private var note: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button { find() } label: {
                        item("magnifyingglass", "页内查找", "系统原生查找条，和 Safari 一样")
                    }
                    Button { translateNotReady() } label: {
                        item("character.book.closed", "翻译整个网页",
                             "重做中：下一版改成原地翻译", dim: true)
                    }
                } header: {
                    Text("当前网页")
                } footer: {
                    Text("翻译正在重做 —— 之前那条「跳到百度翻译」是跳出去翻，不是原地翻译，不算数。下一版做「原地把页面文字翻成中文」，并且能一键切回原文。")
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
        note = "翻译正在重做：下一版改成「原地把页面文字翻成中文」，还能一键切回原文。"
    }
}
