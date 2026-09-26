import SwiftUI
import UniformTypeIdentifiers

/// 收藏 / 历史 —— 一个页面两个 tab（需求里就是这么写的）。
/// 点某一条 → 在浏览器里打开它。
struct BookmarksView: View {
    @ObservedObject var store: BookmarkStore
    @Binding var isPresented: Bool
    var onOpen: (String) -> Void

    @State private var tab = 0                 // 0 = 收藏，1 = 历史
    @State private var confirmClear = false
    /// 导入书签（v1.0.90）—— 工具箱里有入口，这里也放一个：整理书签时就该在收藏页顺手能点
    @State private var showPick = false
    @State private var note: String?

    // MARK: 分组管理（v1.0.94）
    @State private var showRename = false
    @State private var renameTarget = ""      // 正在改名的哪个分组
    @State private var renameText = ""
    @State private var showCreate = false
    @State private var showMove = false
    @State private var movingURL = ""         // 正在移动哪一条书签
    @State private var deleteTarget: String?  // 正在删哪个分组（非 nil = 弹确认框）

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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showPick = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入书签")
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showCreate = true } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("新建分组")
                    .disabled(tab != 0)
                }
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
            .sheet(isPresented: $showPick) {
                FilePickerBox(onPicked: { files in importBookmarks(files) },
                              types: [.html, .json])
            }
            // ── 分组管理（v1.0.94）──
            .sheet(isPresented: $showRename) {
                NameSheet(title: "重命名分组", initial: renameText, placeholder: "分组名") { n in
                    store.renameGroup(renameTarget, to: n)
                }
            }
            .sheet(isPresented: $showCreate) {
                NameSheet(title: "新建分组", initial: "", placeholder: "分组名") { n in
                    if !store.createGroup(n) { note = "分组名重复或为空，没建成。" }
                }
            }
            .sheet(isPresented: $showMove) {
                MoveSheet(groups: store.allGroups, current: movingFrom) { target in
                    store.moveMark(url: movingURL, to: target)
                }
            }
            // 删分组：用户要求"每次问我一下" —— 所以给两个明确选项（一起删 / 只解散）
            .confirmationDialog(
                "删除分组「\(deleteTarget ?? "")」？",
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("一起删掉（连里面 \(deleteCount) 条书签）", role: .destructive) {
                    if let g = deleteTarget { store.deleteGroup(g, alsoDelete: true) }
                    deleteTarget = nil
                }
                Button("只解散分组（书签回到「我的收藏」）") {
                    if let g = deleteTarget { store.deleteGroup(g, alsoDelete: false) }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("删了就找不回来了。「只解散」不会丢书签。")
            }
        }
    }

    /// 导入书签：解析 → 去重 → 存，然后把结果写在列表上方
    private func importBookmarks(_ files: [SavedFile]) {
        guard let f = files.first else { return }
        guard let data = try? Data(contentsOf: f.url) else {
            note = "这个文件读不出来。"; return
        }
        let entries = BookmarkImporter.parse(data)
        guard !entries.isEmpty else {
            note = "没从这个文件里读到书签。" + BookmarkImporter.diagnose(data)
            return
        }
        let r = store.importMarks(entries)
        note = "导入完成：新增 \(r.added) 条"
            + (r.updated > 0 ? "，修正分组 \(r.updated) 条" : "")
            + (r.skipped > 0 ? "，跳过 \(r.skipped) 条（重复或地址无效）" : "") + "。"
        tab = 0
    }

    // MARK: - 两组（手动收藏 / 导入的书签）

    /// 手动收藏的（没有文件夹信息）
    private var myMarks: [Bookmark] { store.marks.filter { $0.folder == nil } }

    /// 导入的书签按**文件夹路径**分组 —— 一个文件夹一段，标题就是它在导出文件里的路径。
    /// ★ v1.0.93：以前是"全都塞进一个组、只在每行小字写文件夹名"，
    ///   用户说不像他的导出文件；现在真按文件夹分段（书签栏 / 书签栏 / AI …）。
    private struct FolderGroup: Identifiable {
        var id: String { folder }
        let folder: String
        let marks: [Bookmark]
    }

    private var importedGroups: [FolderGroup] {
        let items = store.marks.filter { $0.folder != nil }
        let by = Dictionary(grouping: items) { $0.folder ?? "" }
        var names = Set(by.keys)
        // ★ 手动新建的分组**还没有书签也要列出来** —— 否则刚建完就看不到，以为没建成
        names.formUnion(store.customGroups)
        names.remove("")
        return names.sorted().map { k in
            FolderGroup(folder: k, marks: (by[k] ?? []).sorted { $0.title < $1.title })
        }
    }

    /// 要删的那个分组里有几条（写进确认框，别让人瞎点）
    private var deleteCount: Int { deleteTarget.map { store.count(inGroup: $0) } ?? 0 }

    /// 正在移动的那条现在在哪个分组（移动列表里打勾用）
    private var movingFrom: String? {
        store.marks.first { $0.url == movingURL }?.folder
    }

    private var currentCount: Int {
        tab == 0 ? store.marks.count : store.history.count
    }

    // MARK: - 两个列表

    @ViewBuilder
    private var marksList: some View {
        if store.marks.isEmpty && store.customGroups.isEmpty {
            empty("还没有收藏。\n用功能卡片里的「收藏网址」把当前页存下来，或点左上角导入书签。")
        } else {
            List {
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !myMarks.isEmpty {
                    Section("我的收藏 \(myMarks.count)") {
                        ForEach(myMarks) { m in markRow(m) }
                    }
                }
                // 导入的书签：**一个文件夹一段**；标题右边「⋯」可以改名 / 删整组
                ForEach(importedGroups) { g in
                    Section {
                        if g.marks.isEmpty {
                            Text("这个分组还没有书签 —— 左滑任意一条选「移动」放进来。")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(g.marks) { m in markRow(m) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(g.folder)
                            Text("\(g.marks.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            groupMenu(g.folder)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 分组标题右边那个「⋯」
    private func groupMenu(_ name: String) -> some View {
        Menu {
            Button {
                renameTarget = name
                renameText = name
                showRename = true
            } label: {
                Label("重命名分组", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = name
            } label: {
                Label("删除分组", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .accessibilityLabel("管理分组 \(name)")
    }

    /// 一条书签：左滑出「删除 / 移动」
    /// （以前只有 .onDelete 的删除；现在把两个动作都挂在左滑上，手指习惯不变）
    private func markRow(_ m: Bookmark) -> some View {
        row(title: m.label, host: m.host, extra: m.folder == nil ? m.timeText : "") {
            open(m.url)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.removeMark(url: m.url)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                movingURL = m.url
                showMove = true
            } label: {
                Label("移动", systemImage: "folder")
            }
            .tint(.blue)
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

/// 只问一个名字的小卡片。
/// ★ 故意**不用 `.alert` + TextField** —— 那个 API 是 iOS 16 起，我们的部署目标是 15.0。
private struct NameSheet: View {
    let title: String
    let initial: String
    let placeholder: String
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationView {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 15))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { onDone(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { text = initial }
    }
}

/// 选一个目标分组（nil = 我的收藏）
private struct MoveSheet: View {
    let groups: [String]
    let current: String?
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Button { onPick(nil); dismiss() } label: {
                    HStack {
                        Text("我的收藏（不归任何分组）")
                        Spacer()
                        if current == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(groups, id: \.self) { g in
                    Button { onPick(g); dismiss() } label: {
                        HStack {
                            Text(g)
                            Spacer()
                            if current == g { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("移到哪个分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
