import SwiftUI

/// 按网站记的名单管理页（`kind` 区分是哪一组）。
///
/// 现在只有一组：`.adCleanOn` —— **广告清理只对名单里的站生效**。
/// （v1.0.238 从"默认全清理 + 按站豁免"**反转**过来，用户原话"弊端太大"。）
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
                    Text("**加进来的站要刷新一次才生效** —— 清理脚本是页面加载时注入的，"
                         + "已经打开的那个页面得重载。")
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
