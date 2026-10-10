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
    /// 需要跟用户说明一句时才有值（例如「已改用抓到的真实地址」）。
    /// 非空时在标题行下面显示一行小字 —— 平时不占地方。
    var hint: String? = nil

    // MARK: - 页面上下文（★ v1.0.106）
    //
    // 下载防盗链站的片子，请求里必须带 Referer / Cookie，否则服务器直接不给内容。
    // 这三个**由长按探测时从页面直接取回来**，随菜单带到下载 —— 不再依赖
    // 「嗅探结果里恰巧有同一条」（自动嗅探默认关之后那份结果常常是空的）。
    var referrer: String = ""
    var ua: String = ""
    var cookie: String = ""
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
    /// ★ v1.0.118：点「选择清晰度」—— 用户提的需求（嗅探面板那条路能挑档，长按这条路不能）。
    ///   点它 → 关菜单 + 弹挑档卡片；选完档位**立刻开始下**（长按上没有"开始下载"按钮）。
    let onPickQuality: () -> Void
    /// ★ v1.0.134：**点上面那张预览卡 = 用 App 内置播放器播**。
    ///
    /// 用户原话：「把长按下载里这个按钮增加一个调用内置播放器的功能，点击这个按钮就可以用
    /// 我们自己内置的播放器播放视频，而不是用网站的那个播放器，而且要做到适用于视频播放和直播播放」。
    ///
    /// ★ 为什么做成"点预览卡"而不是"再加一行"（用户追加要求「不要加按钮名字」）：
    ///   加一行就是多一块 UI、还多一行字；而上面那张大白卡本来就占着位置、又是**视频的示意**——
    ///   让它可点是最自然的，界面上一个字都不用加。卡上加一个小播放角标提示"这里能点"。
    let onPlay: () -> Void
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
    //
    // ★ v1.0.134：这张卡现在**可点** —— 点它 = 用 App 内置播放器播（`onPlay`）。
    //   按用户要求「不要加按钮名字」，所以没有任何文字提示；
    //   只在图标右侧叠一个小小的播放角标，让人知道这里能点（看一眼就懂，不占地方）。

    private var previewCard: some View {
        Button(action: onPlay) {
            VStack(spacing: 14) {
                ZStack {
                    Image(systemName: "video.fill")
                        .font(.system(size: 52, weight: .regular))
                        // ★ v1.0.263：原来写死 Color(white: 0.35)，深色模式下偏暗难读 → 语义色
                        .foregroundStyle(Color(.secondaryLabel))
                }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 下面那张行卡（标题行 + Download 行）

    private var actionCard: some View {
        VStack(spacing: 0) {
            // ★★ v1.0.150：标题行**可点 = 用内置播放器播**（用户指定的位置）。
            //   大预览卡上的 ▶ 小图标已去掉 —— 图标压在缩略图上，还把"播"的位置带偏了；
            //   现在播放的入口就在这一行：整行可点（远超 44px 点击标准），不加任何图标。
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 15))
                        .frame(width: 22)
                    Text(info.title.isEmpty ? "视频" : info.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 有情况才出现（例如「已改用抓到的真实地址」）—— 平时这一行不存在
            if let hint = info.hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider().padding(.leading, 46)

            row(icon: "arrow.down.circle.fill",
                text: "Download",
                trailing: "square.and.arrow.up",
                action: onDownload)

            Divider().padding(.leading, 46)

            // ★ v1.0.118：第二行 —— 挑档。
            //   上一行保持"点了就下"（快路径，绝大多数情况够用）；
            //   想挑清晰度/线路的，点这一行（多一步，但不打扰默认流程）。
            row(icon: "slider.horizontal.3",
                text: "选择清晰度",
                trailing: "chevron.right",
                action: onPickQuality)
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
