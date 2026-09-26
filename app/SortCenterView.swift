import SwiftUI

/// 「整理顺序」（v1.0.99 重做版）。
///
/// ★★ 为什么推倒重来（v1.0.97 那版"拍平 + 两级拖拽"真机实测失败，五家会诊定位）：
///   1. 把「分组行」和「书签行」混在**同一层** → 落点语义歧义
///      （书签落在两个分组行之间，算谁的？我发明的"就近归属"跟用户直觉相反）。
///   2. `.environment(\.editMode, .constant(.active))` 让系统**无法退出编辑态** →
///      和 sheet 的下滑关闭手势打架 → 各种怪现象。
///   3. 落盘时**一次提交里发两次刷新**（marks 一次、groupOrder 一次）→
///      中间帧顺序自相矛盾 → 分组「跳回原位 / 跑到末尾」。
///
/// ★ 现在三条铁律：
///   · **一层里只放一种东西**：首页只有分组行，点进去只有该组的书签行；
///   · **EditMode 用 @State 绑定**（初值 .inactive，点「排序」才进），不用 .constant；
///   · **列表绑本地 @State 数组**，拖动只动本地；落盘时 store 里一次赋值（一次刷新）。
///   跨组移动不在这儿做 —— 沿用收藏页已有的「左滑 → 移到某个分组」。
struct SortCenterView: View {

    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool

    /// 本地镜像：拖动的对象是它，不是 store 里的数组（避免拖动中数据源被重算）
    @State private var order: [String] = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink {
                        GroupSortView(store: store, group: nil)
                    } label: {
                        HStack {
                            Text("我的收藏")
                            Spacer()
                            Text("\(store.marksIn(nil).count) 条")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("未分组")
                } footer: {
                    Text("「我的收藏」的位置是固定的（它不是分组），但里面书签的顺序可以排。")
                }

                Section {
                    ForEach(order, id: \.self) { g in
                        NavigationLink {
                            GroupSortView(store: store, group: g)
                        } label: {
                            HStack {
                                Text(g)
                                Spacer()
                                Text("\(store.marksIn(g).count) 条")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        store.setGroupOrder(order)      // 一次赋值 = 一次刷新
                    }
                } header: {
                    Text("分组顺序")
                } footer: {
                    Text("点「排序」后长按拖动。想调整某条书签属于哪个分组？去收藏页左滑那条书签选「移动」。")
                }

                if order.isEmpty {
                    Section {
                        Text("还没有分组。可以用「新建分组」建一个，或导入书签文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("整理顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editMode == .active ? "完成" : "排序") {
                        editMode = (editMode == .active ? .inactive : .active)
                    }
                    .disabled(order.count < 2)
                }
            }
            .onAppear { order = store.allGroups }
        }
    }
}

/// 第二层：**只排这一组内部**的顺序。
/// 这一层里全是书签行（没有混层），落点没有歧义。
struct GroupSortView: View {

    @ObservedObject var store: BookmarkStore
    let group: String?

    @State private var items: [Bookmark] = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            ForEach(items) { m in
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.label)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    if !m.host.isEmpty {
                        Text(m.host)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .onMove { from, to in
                items.move(fromOffsets: from, toOffset: to)
                store.setMarkOrder(items.map { $0.url }, inGroup: group)  // 一次赋值 = 一次刷新
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(group ?? "我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editMode == .active ? "完成" : "排序") {
                    editMode = (editMode == .active ? .inactive : .active)
                }
                .disabled(items.count < 2)
            }
        }
        .overlay {
            if items.isEmpty {
                Text("这一组还没有书签。\n可以用收藏页的「左滑 → 移动」把书签放进来。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .onAppear { items = store.marksIn(group) }
    }
}
