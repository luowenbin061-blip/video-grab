import SwiftUI

/// 回收站（v1.0.97）。
///
/// 用户明确要的"后悔药"：删分组（一起删）、删单条书签、清空收藏 ——
/// 都先把书签扔进这里，确认不要了再清空。
/// 恢复时会**带着原来的分组名**放回去：原分组还在就自动归位；
/// 不在了也没事 —— 这条自带名字，列表里那个分组会自己"复活"。
struct TrashView: View {

    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool

    @State private var confirmEmpty = false
    @State private var note: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                if store.trash.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text("回收站是空的")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.trash) { it in
                            Button { restore(it) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(it.label)
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let f = it.folder, !f.isEmpty {
                                            Text(f)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("删于 " + it.timeText)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { restore(it) } label: {
                                    Label("恢复", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("全部恢复") {
                        store.restoreAll()
                        note = "已全部恢复（本来就在收藏里的不会重复加）"
                    }
                    .disabled(store.trash.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空", role: .destructive) { confirmEmpty = true }
                        .disabled(store.trash.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .alert("清空回收站？", isPresented: $confirmEmpty) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.emptyTrash()
                    note = "回收站已清空，这些书签真的没了。"
                }
            } message: {
                Text("这些书签就真的没了，找不回来。")
            }
        }
    }

    private func restore(_ it: TrashItem) {
        note = store.restore(it) ? "已恢复「\(it.label)」"
                                 : "这条地址已经在收藏里了，没重复加"
    }
}
