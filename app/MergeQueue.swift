import Foundation

/// 「合并视频」的后台任务 —— **照抄压缩队列那套模式**：状态活在单例里，**窗口关了不丢、任务照跑**。
///
/// 为什么必须这样（用户 2026-09-30 实测报的）：任务跑在 `Task` 里，**本来就不随窗口销毁**；
/// 但进度原来存在那张卡片的 `@State` 里 —— **窗口一关进度就没了**，
/// 用户看到的是"任务在跑、界面没了、不知道跑到哪、也不知道跑完没有"。
///
/// 所以：状态搬到这里（单例），窗口只负责**读它**。
@MainActor
final class MergeQueue: ObservableObject {

    static let shared = MergeQueue()

    enum RunState {
        case idle, running, done, failed

        var isLive: Bool { self == .running }
    }

    @Published private(set) var state: RunState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var phase: String = ""
    /// "还要 3 分钟"
    @Published private(set) var etaText: String?
    @Published private(set) var failure: String?
    /// 刚做完的成品名（界面用来提示"已进下载列表"）
    @Published private(set) var lastOutput: String?

    private var startedAt: Date?

    var isRunning: Bool { state == .running }
    /// 工具箱那格的角标（跟压画质那格一个套路）
    var badgeCount: Int { state.isLive ? 1 : 0 }

    /// 成品登记回调 —— 界面注入一次即可。
    /// ★ 闭包捕获的是 `DownloadCenter`（引用类型），**卡片销毁了也照样有效**。
    ///   参数：(成品文件名, 用来当标题的首条片名)
    var onFinished: ((String, String) -> Void)?

    /// 起一个合并任务（**已经在跑就不重复起**）
    func start(sources: [Merger.Source], outputName: String, output: URL) {
        guard !isRunning, sources.count >= 2 else { return }
        state = .running
        progress = 0
        phase = "正在准备…"
        etaText = nil
        failure = nil
        lastOutput = nil
        startedAt = Date()

        Task { [weak self] in
            do {
                // ★ v1.0.201：改走 `mergeSmart` —— 规格真一致时先"只搬运不重编码"
                //   （零损失、秒级），并**校验成品时长**，对不上自动退回重编码。
                //   以前这里写死 `mergeByReencoding` → 参数一样也白重编一次（有损）。
                try await Merger.mergeSmart(sources, output: output) { p, msg in
                    // ffmpeg 的回调不一定在主线程 → 跳回去再改状态
                    Task { @MainActor in
                        guard let self else { return }
                        self.progress = p
                        self.phase = msg
                        self.etaText = self.eta(for: p)
                    }
                }
                guard let self else { return }
                self.state = .done
                self.progress = 1
                self.phase = "合并完成"
                self.etaText = nil
                self.lastOutput = outputName
                self.onFinished?(outputName, sources.first?.title ?? "合并")
            } catch {
                guard let self else { return }
                self.state = .failed
                self.failure = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// 用"已用时间 × 剩余比例"估还要多久。
    /// ★ 不依赖 ffmpeg 额外报数据（那要加 `-progress` 文件），够用且简单。
    private func eta(for p: Double) -> String? {
        guard let t0 = startedAt, p > 0.02, p < 0.99 else { return nil }
        let used = Date().timeIntervalSince(t0)
        guard used > 2 else { return nil }              // 太早算出来的数会乱跳，先不给
        let total = used / p                            // 按当前速度外推的总时长
        return CompressPlan.etaText(doneSec: used, totalSec: total, speed: 1)
    }

    func clearFailure() { failure = nil }

    /// 界面关掉时把"已完成/已失败"这种终态收掉（**进行中绝不动**）
    func tidyIfFinished() {
        guard !isRunning else { return }
        if state == .done || state == .failed {
            state = .idle
            progress = 0
            phase = ""
            etaText = nil
        }
    }
}
