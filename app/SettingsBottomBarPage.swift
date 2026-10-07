import SwiftUI
import UniformTypeIdentifiers

/// 「底部功能类设置」（v1.0.231）。
///
/// 用户定的六条：① 只做**拖动排序**（不增删）② 池子就是现有的那几个
/// ③ 第三段「长按快捷操作」先立入口、动作先不配 ④ 不做卡片与底栏的去重检查
/// ⑤ 入口放「网页设置」里 ⑥ 不做「恢复默认」。
///
/// ★ 为什么这页不用 `Form`：功能卡片是 **2 行 × 4 列** 的网格，而项目里
///   吃过"`LazyVGrid` 塞进 `List` 行里 → 宽度建议不可靠、只算一列"的亏
///   （见 `SheetKit.swift` 顶上）。这里改用 `ScrollView + VStack`，自己画
///   分组卡片 —— 既躲开那个坑，也跟实际界面长得一样（所见即所得）。
struct SettingsBottomBarPage: View {
    @AppStorage(UILayout.toolKey) private var toolRaw = UILayout.toolDefaultRaw
    @AppStorage(UILayout.barKey) private var barRaw = UILayout.barDefaultRaw

    /// 正在被拖的那一项。带区前缀（`t:` 功能卡片 / `b:` 底栏）——
    /// 两个区共用一个状态，但**不跨区换位**（卡片不能拖进底栏）。
    @State private var dragging: String?
    /// 第三段选中的底栏按钮（长按动作将来挂它身上）
    @State private var pickedLP: String?
    @State private var note: String?

    private var tools: [String] { UILayout.parse(toolRaw, UILayout.toolDefault) }
    private var bars: [String] { UILayout.parse(barRaw, UILayout.barDefault) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionGroup("功能卡片 · 按住拖动排序") {
                    VStack(spacing: 8) {
                        row(Array(tools.prefix(UILayout.toolColumns)), kind: "t")
                        row(Array(tools.dropFirst(UILayout.toolColumns)), kind: "t")
                    }
                }

                sectionGroup("底部功能栏 · 按住拖动排序") {
                    row(bars, kind: "b")
                }

                longPressGroup
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("底部功能类设置")
        .navigationBarTitleDisplayMode(.inline)
        // 拖到空白处松手 → 名字不会一直挂在半透明状态
        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            dragging = nil
            return true
        }
        .onDisappear { dragging = nil }
    }

    // MARK: - 三段

    private func row(_ keys: [String], kind: String) -> some View {
        HStack(spacing: 8) {
            ForEach(keys, id: \.self) { k in
                cell(k, kind: kind)
            }
        }
    }

    /// 一格：图标 + 名字。按住可以拖；拖到谁头上就跟谁换位。
    private func cell(_ k: String, kind: String) -> some View {
        let info = UILayout.label(of: k)
        let tag = kind + ":" + k
        let on = dragging == tag
        return VStack(spacing: 4) {
            Image(systemName: info.icon)
                .font(.system(size: 18))
            Text(info.name)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(on ? Color.accentColor.opacity(0.18)
                       : Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(on ? Color.accentColor : Color.primary)
        .contentShape(Rectangle())
        .onDrag {
            dragging = tag
            return NSItemProvider(object: k as NSString)
        }
        .onDrop(of: [UTType.text],
                delegate: MoveDrop(key: k, kind: kind,
                                   dragging: $dragging,
                                   raw: kind == "t" ? $toolRaw : $barRaw,
                                   fallback: kind == "t" ? UILayout.toolDefault
                                                         : UILayout.barDefault))
    }

    /// 第三段：长按快捷操作。
    /// ★ 这一版**只立入口**（能选按钮、能点加号），动作本身还没做 ——
    ///   所以点「添加」给一句明白话，不做成"点了没反应"的死按钮。
    private var longPressGroup: some View {
        sectionGroup("长按快捷操作") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(bars, id: \.self) { k in
                        Button {
                            pickedLP = k
                            note = nil
                        } label: {
                            lpCell(k)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    note = pickedLP == nil
                        ? "先在上面选一个按钮。"
                        : "长按动作还没做 —— 等定下来要配哪些，再一起加上。"
                } label: {
                    Label("添加长按动作", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                }

                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 第三段里那一格（**可选中、不可拖动**）—— 它的用途是"给哪一位配长按动作"。
    private func lpCell(_ k: String) -> some View {
        let info = UILayout.label(of: k)
        let on = pickedLP == k
        return VStack(spacing: 4) {
            Image(systemName: info.icon)
                .font(.system(size: 17))
            Text(info.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(on ? Color.accentColor.opacity(0.15)
                       : Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(on ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .foregroundStyle(on ? Color.accentColor : Color.primary)
        .contentShape(Rectangle())
    }

    /// 分组卡片：小标题 + 白底圆角内容（模仿 Form 的分组观感）
    private func sectionGroup<C: View>(_ title: String,
                                       @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 拖动重排的落点：**拖过谁就跟谁换位**（`dropEntered` 里实时改顺序），
/// 松手只是收尾。所以拖动过程中就能看到顺序在变，不用等松手。
private struct MoveDrop: DropDelegate {
    let key: String
    let kind: String
    @Binding var dragging: String?
    @Binding var raw: String
    let fallback: [String]

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d.hasPrefix(kind + ":") else { return }
        let from = String(d.dropFirst(2))
        guard from != key else { return }
        raw = UILayout.move(raw, fallback, from: from, to: key)
    }

    /// 松手那一刻：不管落在哪，都先把"正在拖"的状态收掉。
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
