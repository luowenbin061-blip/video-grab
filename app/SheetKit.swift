import SwiftUI

/// 「卡片式表单页」的骨架 —— 给「压画质」「合并视频」两张卡用。
///
/// ★★ 为什么要从 `List` 换成 `ScrollView + VStack`（2026-09-30 用户**连报三轮**
///   「跟之前一模一样」，v1.0.181/182/183 都没修好）：
///
///   `LazyVGrid` 放进 `List` 的**行**里，行给出的宽度建议不可靠 ——
///   实测表现就是**网格只算出一列、缩略图撑满整屏**（用户截图）。
///   工具箱那一页用的是 `ScrollView + LazyVGrid`，3 列**一直正常** —— 所以照它来。
///
/// ★ 外观对齐原来的 `.insetGrouped`：灰底 + 圆角白卡 + 小标题在上、脚注在下。
struct SheetPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.top, 6)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// 一块「小标题 + 卡片 + 脚注」—— 原来 `Section { } header: { } footer: { }` 的替身。
///
/// 用法：
///   `SheetSection("标题", footer: "脚注") { 卡片里的内容 }`
///   不需要标题/脚注就省掉。
struct SheetSection<Content: View>: View {
    private let title: String?
    private let footer: Text?
    private let content: Content

    init(_ title: String? = nil, footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            if let footer {
                footer
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
    }
}

/// 卡片内的分隔线（左边留一点缩进，跟系统的分组列表一个观感）
struct SheetDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

extension View {
    /// 卡片里的一行：**撑满宽度 + 统一内边距**（原来 `List` 的行就是这个手感）。
    /// 放在 `SheetSection` 的卡片里用；放进按钮的 label 里，整行就都能点。
    func cardRow(top: CGFloat = 11, bottom: CGFloat = 11) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
    }
}
