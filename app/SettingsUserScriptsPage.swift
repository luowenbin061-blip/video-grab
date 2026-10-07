import SwiftUI
import UniformTypeIdentifiers

/// 「用户脚本」（v1.0.233）—— 设置 → 网页设置 → 用户脚本。
///
/// ★ 用户 2026-10-07 定的：名字叫「用户脚本」，界面里的提示用「JS 脚本」；
///   **要能自己导入**；先把最想要的那件事（自动播放网页视频）做成第一个内置脚本。
///
/// ★ 界面上不写大段说明（他定的规矩：靠命名自明）——
///   只有两个"名字看不出来的后果"要讲一句：
///     ① 开关只对**新打开的网页**生效（已经打开的页面要重载）；
///     ② 脚本出错**只影响它自己**，不会连累别的脚本和 App。
struct SettingsUserScriptsPage: View {
    @ObservedObject private var store = UserScriptStore.shared

    @State private var showPaste = false
    @State private var showFilePicker = false
    @State private var pasteText = ""
    @State private var pasteError: String?
    @State private var detail: UserScript?
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                if store.scripts.isEmpty {
                    Text("还没有脚本").foregroundStyle(.secondary)
                }
                ForEach(store.scripts) { s in
                    row(s)
                }
            } header: {
                Text("脚本")
            } footer: {
                Text("开关只对**新打开的网页**生效 —— 已经打开的页面要重载一次。")
            }

            Section {
                Button("粘贴脚本代码") {
                    pasteText = ""
                    pasteError = nil
                    showPaste = true
                }
                Button("从「文件」导入 .js") { showFilePicker = true }
            } footer: {
                Text("认油猴那套头部（@name / @match / @description）；没写 @match 就对所有网站生效。")
            }

            if let note {
                Section { Text(note).font(.system(size: 13)) }
            }
        }
        .navigationTitle("用户脚本")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { s in
            NavigationView { UserScriptDetailPage(script: s) }
        }
        .sheet(isPresented: $showPaste) { pasteSheet }
        .sheet(isPresented: $showFilePicker) {
            FilePickerBox(onPicked: { files in importFiles(files) },
                          types: [.javaScript, .plainText])
        }
    }

    // MARK: - 列表里的一行

    private func row(_ s: UserScript) -> some View {
        HStack(spacing: 12) {
            Button {
                detail = s
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.name).foregroundStyle(.primary)
                        if s.builtin {
                            Text("内置")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(s.desc.isEmpty ? s.scopeText : s.desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(get: { s.enabled },
                                     set: { store.setEnabled(s.id, $0) }))
                .labelsHidden()
        }
    }

    // MARK: - 导入

    private var pasteSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $pasteText)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                if let e = pasteError {
                    Text(e)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("粘贴脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { doPaste() }
                        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func doPaste() {
        do {
            let r = try store.importCode(pasteText)
            note = "已导入「\(r.name)」。"
            showPaste = false
        } catch {
            pasteError = error.localizedDescription
        }
    }

    private func importFiles(_ files: [SavedFile]) {
        guard let f = files.first else { return }
        // ★ 编码要宽容：用户传过来的 .js 可能是 UTF-8 带 BOM，也可能压根不是 UTF-8
        let raw = (try? Data(contentsOf: f.url)) ?? Data()
        var text = String(data: raw, encoding: .utf8)
            ?? String(data: raw, encoding: .utf16)
            ?? String(data: raw, encoding: .isoLatin1)
        if var t = text {
            if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
            text = t
        }
        guard let src = text else {
            note = "这个文件读不出文字内容。"
            return
        }
        do {
            let r = try store.importCode(src)
            note = "已导入「\(r.name)」。"
        } catch {
            note = error.localizedDescription
        }
    }
}

// MARK: - 一条脚本的详情

/// 看代码；导入的还能改、能删；**内置的只能看**（它是功能本体，删了这个功能就没了）。
struct UserScriptDetailPage: View {
    let script: UserScript

    @ObservedObject private var store = UserScriptStore.shared
    @Environment(\.presentationMode) private var mode

    @State private var code = ""
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                settingsKVRow("生效范围", script.scopeText)
                if !script.desc.isEmpty { Text(script.desc) }
            }

            Section {
                if editing {
                    TextEditor(text: $code)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 260)
                } else {
                    ScrollView {
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                }
            } header: {
                Text("JS 脚本")
            } footer: {
                Text("脚本跑在网页自己的环境里，出错只影响这一条 —— 不会连累 App。")
            }

            if !script.builtin {
                Section {
                    if editing {
                        Button("保存修改") { store.updateCode(script.id, code); editing = false }
                    } else {
                        Button("编辑代码") { editing = true }
                    }
                    Button("删除这个脚本", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(script.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { code = store.sourceCode(of: script) }
        .alert("删除「\(script.name)」？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                store.remove(script.id)
                mode.wrappedValue.dismiss()
            }
        } message: {
            Text("删了就找不回来了（可以重新导入）。")
        }
    }
}
