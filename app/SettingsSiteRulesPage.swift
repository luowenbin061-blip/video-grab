import SwiftUI

/// 按网站记的"特殊待遇"名单管理页（两组共用这一页，靠 `kind` 区分）。
///
/// 两组：
///   · `.openInNewTab` —— 点链接弹窗里勾过"以后都用新标签"的站
///   · `.adCleanSkip`  —— 广告清理**不适用**的站（页面被误伤了，当场关掉）
///
/// ★ 只做"加 / 删 / 清空"三件事 —— 跟「网页黑名单」同一套交互，不另造花样。
struct SettingsSiteRulesPage: View {

    let kind: SiteRules.Kind

    @State private var input = ""
    @State private var items: [String] = []
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("example.com", text: $input)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(size: 15))
                    Button("添加") { add() }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("添加")
            } footer: {
                Text("填网址或域名都行 —— 一律按**域名**记，子域名一起算（加了 a.com，m.a.com 也算）。")
            }

            if items.isEmpty {
                Section {
                    Text("还没有").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(items, id: \.self) { it in
                        Text(it).font(.system(size: 15))
                    }
                    .onDelete { idx in
                        for i in idx { SiteRules.remove(items[i], from: kind) }
                        items = SiteRules.all(kind)
                    }
                } header: {
                    Text("已添加 \(items.count) 个")
                } footer: {
                    if kind == .adCleanSkip {
                        Text("**加进来的站要刷新一次才生效** —— 清理脚本是页面加载时注入的，"
                             + "已经打开的那个页面得重载。")
                    } else {
                        Text("下次点链接到这些站，直接开新标签，不再问你。")
                    }
                }
            }

            if !items.isEmpty {
                Section {
                    Button("全部清空", role: .destructive) {
                        SiteRules.forgetAll(kind)
                        items = SiteRules.all(kind)
                    }
                }
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = SiteRules.all(kind) }
    }

    private func add() {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if SiteRules.add(s, to: kind) {
            input = ""
            note = nil
            items = SiteRules.all(kind)
        } else {
            note = "「\(s)」要么已经在列表里了，要么不像一个网址（要含一个点，比如 example.com）"
        }
    }
}
