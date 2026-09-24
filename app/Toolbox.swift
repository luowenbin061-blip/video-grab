import SwiftUI
import UIKit

/// 工具箱：截图 / 页内查找 / 翻译 —— 都只作用于当前网页。
/// 三个动作都是「先收起这张卡片再动手」：卡片盖着的时候网页那层不是最新画面。
struct ToolboxView: View {
    let model: BrowserModel
    @Binding var isPresented: Bool

    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("当前网页") {
                    Button { shoot() } label: {
                        item("camera", "截图当前页面", "存到系统相册")
                    }
                    Button { find() } label: {
                        item("magnifyingglass", "页内查找", "系统原生查找条，和 Safari 一样")
                    }
                    Button { translate() } label: {
                        item("character.book.closed", "翻译整个网页", "跳到百度整页翻译")
                    }
                }

                if let note {
                    Section { Text(note).font(.system(size: 13)) }
                }

                Section("说明") {
                    Text("翻译是「跳出去」用百度的整页翻译，不是把文字原地替换 —— 看完点底栏的后退就能回到原网页。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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

    private func item(_ icon: String, _ title: String, _ sub: String) -> some View {
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
    }

    // MARK: - 三个动作

    private func shoot() {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)      // 等卡片收干净再截
            guard let img = await model.snapshotImage() else {
                model.showToast("截图失败：没拿到画面")
                return
            }
            do {
                try await Saver.toPhotos(image: img)
                model.showToast("截图已存进相册")
            } catch {
                model.showToast("存相册失败：\(error.localizedDescription)")
            }
        }
    }

    private func find() {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !model.presentFind() {
                model.showToast("页内查找要 iOS 16 以上")
            }
        }
    }

    private func translate() {
        guard let page = model.currentURL else {
            note = "还没有打开网页。"
            return
        }
        guard var comp = URLComponents(string: "https://fanyi.baidu.com/transpage") else {
            note = "链接拼不出来。"
            return
        }
        comp.queryItems = [
            URLQueryItem(name: "query", value: page),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: "zh"),
            URLQueryItem(name: "source", value: "url"),
        ]
        guard let u = comp.url else {
            note = "链接拼不出来。"
            return
        }
        isPresented = false
        model.load(u.absoluteString)
    }
}
