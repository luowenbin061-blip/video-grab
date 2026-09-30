import SwiftUI
import UIKit

/// 选片用的**图标卡片**（「合并视频」和「压画质」两处共用）。
///
/// ★★ 用户 2026-09-30 18:38 给了验收标准（相册/文件那种**图标格式**）：
///   **缩略图居中 + 名称居中 + 一行小字**，排成网格；**没有大卡片底色**。
///   之前那版是"封面撑满整格 + 文字左对齐 + 白色卡片底" —— 不是他要的。
///
/// ★★ 上一版还有一个**致命写法**（就是"缩略图撑满整屏"的根因）：
///   给 `ZStack{ 底 + Image().resizable().scaledToFill() }` 挂一个
///   **16:9 的 `aspectRatio` + `.fill`** —— 在**高度不受限**的上下文里，
///   `.fill` 会拿图片的**原始尺寸**当理想尺寸，封面于是被撑到几千点高，
///   把整格撑爆（用户截图：图片糊满屏幕）。
///   **改法：高度写死、宽度跟随格子**（下面 `coverH`）。确定、不可能被内容撑开。
struct SourceCard: View {
    let title: String
    let detail: String
    /// 有缩略图就给（下载任务转 MP4 时抽的那一帧；图片就是那张图本身）
    let thumbURL: URL?
    /// 没有缩略图时的占位图标（"film" / "photo"）
    let icon: String
    let on: Bool
    let tap: () -> Void

    /// 缩略图那块的高度 —— **写死**，宽度跟着格子走（3 列时约 104×60 ≈ 16:9）
    private let coverH: CGFloat = 60

    @State private var img: UIImage?
    @State private var loadedKey: String?

    private var key: String { thumbURL?.path ?? "-" }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 5) {
                cover
                Text(title)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: key) {
            // 换片才重读（降采样读，别把整张图解进内存）
            guard loadedKey != key else { return }
            loadedKey = key
            guard let u = thumbURL else { img = nil; return }
            img = await ThumbLoader.loadLocal(u, maxPx: 320)
        }
    }

    /// 缩略图（就是"图标"那一块）：居中、固定高度、圆角；选中套一圈亮边
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        // ★★ 先定高、再撑满宽 —— 顺序和写法都不能改（改回 aspectRatio(.fill) 就会重演撑爆）
        .frame(height: coverH)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 2.5)
        )
        .overlay(alignment: .topTrailing) {
            // ★ 选中标：压在缩略图右上角（有图时得有个底才看得清）
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(on ? Color.accentColor : Color.white)
                .background(Circle().fill(on ? Color.white : Color.black.opacity(0.35)))
                .padding(4)
        }
    }
}

extension DownloadJob {
    /// 卡片要用的缩略图地址（有就给）—— 合并页和压缩页共用同一套取法
    var cardThumbURL: URL? {
        guard let t = thumbName, JobStore.exists(named: t) else { return nil }
        return JobStore.file(named: t)
    }
}
