import SwiftUI

/// 首页 —— 新标签页（地址栏还空着的时候）显示的东西。
///
/// 为什么要有它：新标签是每天第一眼看到的地方，原来是**一片空白**，
/// 想干什么都得先敲地址。现在把常用网站 + 常用功能摆在这儿，一眼就能点。
///
/// ★ 两条硬规则（用户明确要的）：
///   1) **放什么由用户自己加**（网址、功能都能加）；
///   2) 设置里填了「主页地址」时，**新标签直接开那个网址，这张首页不出现**。
struct HomePageView: View {
    @ObservedObject var store: HomeStore
    /// 点网址格子
    let onOpenURL: (String) -> Void
    /// 点功能格子
    let onFeature: (HomeFeature) -> Void

    @State private var showAdd = false
    @State private var renaming: HomeItem?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 18) {
                ForEach(store.items) { it in
                    cell(it)
                }
                addCell
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .onAppear { store.refreshMissingIcons() }      // 补齐还没抓到图标的
        .sheet(isPresented: $showAdd) {
            AddHomeSheet(store: store)
        }
        .alert("改个名字", isPresented: Binding(get: { renaming != nil },
                                              set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let it = renaming { store.rename(it, to: renameText) }
                renaming = nil
            }
        }
    }

    // MARK: - 一格

    @ViewBuilder
    private func cell(_ it: HomeItem) -> some View {
        Button {
            if it.kind == .url {
                onOpenURL(it.value)
            } else if let f = HomeFeature(rawValue: it.value) {
                onFeature(f)
            }
        } label: {
            VStack(spacing: 6) {
                iconBox(it)
                Text(label(of: it))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 长按 → 系统原生菜单（跟书签那边一致；不做自制菜单）
        .contextMenu {
            Button {
                renameText = label(of: it)
                renaming = it
            } label: {
                Label("改名字", systemImage: "pencil")
            }
            Button {
                store.moveToTop(it)
            } label: {
                Label("移到最前", systemImage: "arrow.up.to.line")
            }
            Button(role: .destructive) {
                store.remove(it)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func label(of it: HomeItem) -> String {
        if !it.title.isEmpty { return it.title }
        if let f = HomeFeature(rawValue: it.value) { return f.title }
        return it.value
    }

    /// 54×54 的圆角方格：抓到 favicon 就显示它，否则首字母色块 / 功能图标
    @ViewBuilder
    private func iconBox(_ it: HomeItem) -> some View {
        ZStack {
            if let img = store.icon(for: it) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(9)
            } else if it.kind == .url {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Self.tint(for: it.value))
                Text(HomeStore.initial(for: it))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
            } else if let f = HomeFeature(rawValue: it.value) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                Image(systemName: f.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                Image(systemName: "questionmark")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 54, height: 54)
    }

    private var addCell: some View {
        Button {
            showAdd = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Image(systemName: "plus")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 54, height: 54)
                Text("添加")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加")
    }

    /// 没抓到图标时的底色：按地址算，同一个站永远是同一个颜色（不闪、不随机）
    static func tint(for url: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red]
        var h = 0
        for u in url.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}

/// 「添加」卡片：上面加网址，下面加功能。
/// 两类共用一个入口 —— 页面上就只有一个「＋」。
struct AddHomeSheet: View {
    @ObservedObject var store: HomeStore
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var note: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    TextField("网址（例如 ted.com）", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("名字（可留空）", text: $name)
                    Button {
                        if store.addURL(url, title: name) {
                            dismiss()
                        } else {
                            note = "这个地址不合法，或者已经加过了。"
                        }
                    } label: {
                        Label("加到首页", systemImage: "plus.circle.fill")
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("加一个网址")
                } footer: {
                    if let note {
                        Text(note).foregroundStyle(.orange)
                    } else {
                        Text("名字留空就用网站域名；图标会自动去抓（抓不到就用首字母）。")
                    }
                }

                Section {
                    ForEach(HomeFeature.allCases) { f in
                        let added = store.items.contains {
                            $0.kind == .feature && $0.value == f.rawValue
                        }
                        Button {
                            store.addFeature(f)
                            dismiss()
                        } label: {
                            HStack {
                                Label(f.title, systemImage: f.icon)
                                Spacer(minLength: 6)
                                if added {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(added)
                    }
                } header: {
                    Text("加一个功能")
                } footer: {
                    Text("这些就是我们自己的功能，点了等于直接跳过去。已经加过的（打勾）不用重复加。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("添加到首页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
