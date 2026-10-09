import SwiftUI

/// ★★ v1.0.243：网页弹窗询问的**软菜单**（下拉那种，就近展开在点击位置附近）。
///
/// 用户给的参考截图就是它 —— 明确不要"挡在屏幕正中间的居中对话框"（那是系统 `.alert`
/// 的样子）。这个卡片：
///   · 出现在**你点的那块地方**附近（位置由 `BrowserModel.popupAnchor` 给）；
///   · 一列选项，左对齐，带分隔线；
///   · 顶上一条浅灰的说明（标题 + 地址），地址最多两行、中间省略。
///   · **没有"取消"这一项** —— 点卡片外面任意处即关闭（跟截图一致）。
struct PopupMenuCard: View {

    let info: PopupAskInfo
    /// 选了哪一项
    let onPick: (PopupAnswer) -> Void

    /// 卡片宽度（由界面按屏宽算好传进来）
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // ── 说明区（浅灰底）──
            VStack(alignment: .leading, spacing: 3) {
                Text("当前网页触发了弹出式窗口")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(info.url)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))

            row("当前窗口加载", .inPlace)
            divider
            row("新窗口打开", .newTab)
            divider
            row("后台窗口打开", .background)
        }
        .frame(width: width)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 8)
        // 整卡可点（免得点在行与行之间的分隔线上没反应）
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
    }

    private func row(_ title: String, _ answer: PopupAnswer) -> some View {
        Button {
            onPick(answer)
        } label: {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
