import SwiftUI

/// 收藏 / 历史 —— 一个页面两个 tab（需求里就是这么写的）。
/// 点某一条 → 在浏览器里打开它。
struct BookmarksView: View {
    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool
    var onOpen: (String) -> Void

    @State private var tab = 0                 // 0 = 收藏，1 = 历史
    @State private var confirmClear = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("收藏 \(store.marks.count)").tag(0)
                    Text("历史 \(store.history.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if tab == 0 { marksList } else { historyList }
            }
            .navigationTitle("收藏 / 历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空", role: .destructive) { confirmClear = true }
                        .disabled(currentCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .alert(tab == 0 ? "清空收藏？" : "清空历史？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    if tab == 0 { store.clearMarks() } else { store.clearHistory() }
                }
            } message: {
                Text("全部删掉，删了就找不回来了。")
            }
        }
    }

    private var currentCount: Int {
        tab == 0 ? store.marks.count : store.history.count
    }

    // MARK: - 两个列表

    @ViewBuilder
    private var marksList: some View {
        if store.marks.isEmpty {
            empty("还没有收藏。\n用功能卡片里的「收藏网址」把当前页存下来。")
        } else {
            List {
                ForEach(store.marks) { m in
                    row(title: m.label, host: m.host, extra: m.timeText) { open(m.url) }
                }
                .onDelete { idx in
                    // 先把要删的地址收集出来再删 —— 边删边按下标取会错位
                    let urls = idx.map { store.marks[$0].url }
                    urls.forEach { store.removeMark(url: $0) }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if store.history.isEmpty {
            empty("还没有浏览记录。\n打开过的网页会自动记在这里。")
        } else {
            List {
                ForEach(store.history) { h in
                    row(title: h.label, host: h.host,
                        extra: h.visits > 1 ? "\(h.timeText) · 看过 \(h.visits) 次" : h.timeText) {
                        open(h.url)
                    }
                }
                .onDelete { idx in
                    let urls = idx.map { store.history[$0].url }
                    urls.forEach { store.removeHistory(url: $0) }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 零件

    private func row(title: String, host: String, extra: String,
                     tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !host.isEmpty {
                        Text(host)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(extra)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(host)")
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ url: String) {
        isPresented = false
        onOpen(url)
    }
}
