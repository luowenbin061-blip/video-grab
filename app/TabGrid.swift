import SwiftUI
import UIKit

/// 标签页网格（对齐 Safari：整屏缩略图 + 底部「+ / N 个标签页 / 完成」）。
///
/// ★ 为什么要换成网格：原来是一条横向文字标签条，开几个之后名字全挤在一起，
///   根本认不出哪个是哪个。缩略图一眼就知道。
/// ★ 缩略图从哪来：只在该标签**正显示的时候**截一次存起来（见 BrowserModel.snapshotCurrent）
///   —— 后台/休眠的 WebView 截出来是空白。截过的会一直在，所以网格里能马上看到。
struct TabGridView: View {

    @ObservedObject var model: BrowserModel
    @Binding var isPresented: Bool

    /// 卡片宽度自适应：窄屏两列、宽屏三列。
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.tabSnapshot.isEmpty {
                emptyState
            } else {
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

            Divider()
            bottomBar
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            Text("标签页")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("完成") { isPresented = false }
                .font(.system(size: 16))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 一张卡

    private func card(_ t: TabSnapshot) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail(t)
                // 关闭：跟 Safari 一样在卡片左上/右上角一个圆圈 ✕
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
                // 还没截过图（这个标签从没显示过，或者刚睡醒）→ 给个淡底 + 地球，
                // 别让卡片看着像坏了
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
            Text("点左下角「+」开一个新窗口")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
