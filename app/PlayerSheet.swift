import AVKit
import SwiftUI

/// 用系统播放器放本地文件。
/// 下载完能直接在 App 里看一眼，不用先跑去「文件」App。
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
