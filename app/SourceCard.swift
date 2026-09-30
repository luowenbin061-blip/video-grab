import SwiftUI
import UIKit

/// 选片用的**卡片**（「合并视频」和「压画质」两处共用）。
///
/// ★ 用户 2026-09-30：「选择列表能不能做成**图标格式**，不要做成列表格式，
///   并且都带上缩略图来供用户更好的识别」。
///   原来那版（v1.0.162）是"列表 + 每行一张小图"——他还是觉得不好认。
///   这版改成**网格里的卡片**：一张大缩略图 + 片名 + 时长/大小，一眼扫过去就能挑。
///
/// ★ 缩略图读取复用 `ThumbLoader`（**降采样**读，别把整张图解进内存）。
struct SourceCard: View {
    let title: String
    let detail: String
    /// 有缩略图就给（下载任务转 MP4 时抽的那一帧；图片就是那张图本身）
    let thumbURL: URL?
    /// 没有缩略图时的占位图标（"film" / "photo"）
    let icon: String
    let on: Bool
    let tap: () -> Void

    @State private var img: UIImage?
    @State private var loadedKey: String?

    private var key: String { thumbURL?.path ?? "-" }

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    cover
                    // ★ 选中标：有图的时候直接压在图上，得给个阴影才看得见
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(on ? Color.accentColor : Color.white)
                        .background(Circle().fill(on ? Color.white : Color.black.opacity(0.35)))
                        .padding(5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: key) {
            // 换片才重读（降采样读）
            guard loadedKey != key else { return }
            loadedKey = key
            guard let u = thumbURL else { img = nil; return }
            img = await ThumbLoader.loadLocal(u, maxPx: 320)
        }
    }

    /// 16:9 封面。抽不到图就显示占位图标（跟下载页一个规矩）
    private var cover: some View {
        ZStack {
            Rectangle().fill(Color(.tertiarySystemFill))
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fill)
        .clipped()
    }
}


extension DownloadJob {
    /// 卡片要用的缩略图地址（有就给）—— 合并页和压缩页共用同一套取法
    var cardThumbURL: URL? {
        guard let t = thumbName, JobStore.exists(named: t) else { return nil }
        return JobStore.file(named: t)
    }
}
