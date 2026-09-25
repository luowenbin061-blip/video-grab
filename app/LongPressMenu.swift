import SwiftUI
import UIKit

/// 长按视频命中的内容。原生手势探测成功后填这个，界面据此弹菜单。
/// 地址为空 = 没命中视频（那就什么都不弹，页面照旧）。
struct LongPressMenuInfo: Identifiable, Equatable {
    let id = UUID()
    /// 手指在网页视图里的位置 —— 用来把菜单摆到手指附近
    var point: CGPoint
    /// 视频真实地址
    var url: String
    /// 标题（视频标题优先，没有就用页面标题）
    var title: String
    /// 域名（预览卡上显示的是这个）
    var host: String
}

/// 长按视频弹出来的菜单。
///
/// 为什么是自己画的，不用系统那个：Safari 那套「长按 → 预览卡 + Download」是 WebKit 私有的
/// 长按菜单（只给 Safari 和它的扩展），自研 App 拿不到 —— 详见 notes/VideoGrab.md。
/// 所以这里照截图把两张卡画出来：上面白卡（摄像机图标 + 域名，居中竖排），
/// 下面毛玻璃行卡（标题行 + Download 行）。
struct LongPressMenuView: View {
    let info: LongPressMenuInfo
    /// 点 Download
    let onDownload: () -> Void
    /// 点标题行 → 打开嗅探列表（默认播放器那套行为，能看到这个页面的所有候选地址）
    let onOpenList: () -> Void
    /// 点别处 / 收起
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // 背后压暗一层：跟系统长按菜单一样，视线集中在卡片上；点它收起
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 16) {
                previewCard
                actionCard
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 上面那张预览卡（照截图：白卡 + 居中摄像机图标 + 域名）

    private var previewCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Color(white: 0.35))
            Text(info.host.isEmpty ? "视频" : info.host)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168)
        .background(Color(UIColor.systemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
    }

    // MARK: - 下面那张行卡（标题行 + Download 行）

    private var actionCard: some View {
        VStack(spacing: 0) {
            row(icon: "video.fill",
                text: info.title.isEmpty ? "查看本页视频地址" : info.title,
                trailing: nil,
                action: onOpenList)
            Divider().padding(.leading, 46)
            row(icon: "arrow.down.circle.fill",
                text: "Download",
                trailing: "square.and.arrow.up",
                action: onDownload)
        }
        .frame(width: 272)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.20), radius: 16, y: 8)
    }

    private func row(icon: String, text: String, trailing: String?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
