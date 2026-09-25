import SwiftUI
import UIKit

/// 标签页网格（对齐 Safari：整屏缩略图 + 底部「+ / N 个标签页 / 完成」）。
///
/// ★ 为什么要换成网格：原来是一条横向文字标签条，开几个之后名字全挤在一起，
///   根本认不出哪个是哪个。缩略图一眼就知道。
/// ★ 缩略图从哪来：只在该标签**正显示的时候**截一次存起来（见 BrowserModel.snapshotCurrent）
///   —— 后台/休眠的 WebView 截出来是空白。截过的会落盘，所以重启后网格里还有图。
/// ★ 头部那颗「组名 ▾」点开就是 Safari 的**标签页组**那一页（切组 / 新建 / 改名 / 删）。
struct TabGridView: View {

    @ObservedObject var model: BrowserModel
    @Binding var isPresented: Bool

    /// 正在看「标签页组」那一页
    @State private var showingGroups = false
    /// 正在改名的组（非空 = 弹改名面板）
    @State private var renaming: TabGroup?
    @State private var draftName = ""
    /// 正在确认要删的组
    @State private var deleting: TabGroup?

    /// 卡片宽度自适应：窄屏两列、宽屏三列。
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if showingGroups {
                groupsPage
            } else if model.tabSnapshot.isEmpty {
                emptyState
            } else {
                gridPage
            }

            Divider()
            bottomBar
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $renaming) { g in renameSheet(g) }
        .confirmationDialog("删掉「\(deleting?.displayName ?? "")」这个标签页组？",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删掉这个组（里面的标签一起关掉）", role: .destructive) {
                if let g = deleting,
                   let i = model.tabGroups.firstIndex(where: { $0.id == g.id }) {
                    model.deleteGroup(i)
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            if showingGroups {
                Button {
                    showingGroups = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("标签页").font(.system(size: 16))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showingGroups = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentGroup?.displayName ?? "标签页")
                            .font(.system(size: 16, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换标签页组")
            }

            Spacer()

            Button("完成") { isPresented = false }
                .font(.system(size: 16))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 网格页

    private var gridPage: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.tabSnapshot) { t in
                    card(t)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    private func card(_ t: TabSnapshot) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail(t)
                Button {
                    model.closeTab(id: t.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(7)
                .accessibilityLabel("关闭这个标签")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(t.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(t.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.switchTo(id: t.id)
            isPresented = false
        }
    }

    /// 缩略图区。固定的 4:3 —— 截图时也是按 4:3 取页面顶部（见 BrowserModel.shrink），
    /// 所以这里能刚好填满、不用裁。
    private func thumbnail(_ t: TabSnapshot) -> some View {
        ZStack {
            if let img = t.thumb {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.secondarySystemBackground)
                Image(systemName: "globe")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
            }
        }
        // 先撑满列宽、再按 4:3 收紧 —— 反过来写在某些宽度下会有布局警告
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(t.isCurrent ? Color.accentColor : Color.primary.opacity(0.10),
                        lineWidth: t.isCurrent ? 2 : 0.5)
        )
    }

    // MARK: - 标签页组那一页（对齐 Safari 的面板）

    private var groupsPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(model.tabGroups.enumerated()), id: \.element.id) { idx, g in
                        groupRow(idx, g)
                        if idx != model.tabGroups.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 0) {
                    actionRow("plus", "新建空标签页组") {
                        model.newGroup()
                        showingGroups = false
                    }
                    Divider().padding(.leading, 52)
                    actionRow("plus", "把这 \(model.tabCount) 个标签移到新标签页组") {
                        model.moveCurrentTabsToNewGroup()
                        showingGroups = false
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("同一个标签只属于一个组。切组就是换一组标签看 —— 每组会记住你上次看的是哪个。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(14)
        }
    }

    /// 一行组。★ 左边「切过去」和右边「⋯」是两个独立按钮（不是按钮套按钮 ——
    /// SwiftUI 里嵌套按钮会互相吃掉点击）。
    private func groupRow(_ idx: Int, _ g: TabGroup) -> some View {
        HStack(spacing: 0) {
            Button {
                model.switchGroup(idx)
                showingGroups = false
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: g.isPrivate ? "hand.raised.fill" : "square.on.square")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.displayName)
                            .font(.system(size: 15))
                            .lineLimit(1)
                        Text("\(g.tabIDs.count) 个标签页")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if idx == model.currentGroupIndex {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("重命名") {
                    draftName = g.name
                    renaming = g
                }
                Button("删掉这个组", role: .destructive) { deleting = g }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("这个组的更多操作")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
    }

    private func actionRow(_ icon: String, _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                Text(label)
                    .font(.system(size: 15))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func renameSheet(_ g: TabGroup) -> some View {
        NavigationView {
            Form {
                TextField("组名", text: $draftName)
                    .autocorrectionDisabled(true)
            }
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { renaming = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") {
                        if let i = model.tabGroups.firstIndex(where: { $0.id == g.id }) {
                            model.renameGroup(i, to: draftName)
                        }
                        renaming = nil
                    }
                }
            }
        }
    }

    // MARK: - 底栏（+ / N 个标签页 / 完成）

    private var bottomBar: some View {
        HStack {
            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(model.tabCount >= TabLimits.maxTabs)
            .opacity(model.tabCount >= TabLimits.maxTabs ? 0.3 : 1)
            .accessibilityLabel("新建标签页")

            Spacer()

            Text("\(model.tabCount) 个标签页")
                .font(.system(size: 15, weight: .medium))

            Spacer()

            Button("完成") { isPresented = false }
                .font(.system(size: 16))
                .frame(width: 44)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemGroupedBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有标签页")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text("点左下角「+」开一个新标签")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
