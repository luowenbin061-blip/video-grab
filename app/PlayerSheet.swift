import AVKit
import SwiftUI

/// 用系统播放器放视频。
///
/// 传进来的地址要么是「本机 HTTP 上的 m3u8」，要么是原始在线地址 ——
/// 不能是本地 .ts / 本地 .m3u8，那两种 AVPlayer 都不接受（见 Exporter 顶部说明）。
struct PlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}
