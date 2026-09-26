import AVFoundation

/// 全局音频会话。这个 App 不做「后台放音乐」这种事，但**两件要紧的事**都离不开它：
///
///  1. **App 内播放要有声音。**
///     iOS 默认的会话类别是 soloAmbient，**会被侧面的静音拨片静掉**。
///     相册 / 文件 App 设的是 playback，所以同一条视频在那边有声音、在我们这里有声音差 ——
///     这正是「导出来有声音、在 App 里没声音」的原因，跟文件本身无关。
///
///  2. **画中画必须有一个 active 的 playback 会话才可能就绪。**
///     WWDC 2021「What's new in AVKit」：*configure your app's audio session category
///     for playback* and enable the PiP background mode。
///     实践指南说得更直白：*even for videos without audio*，不设 movie playback，
///     App 进后台时画中画窗口就是打不开 —— 我们这个画中画正好一个音轨都没有。
///
/// 用引用计数：播放器（PlayerSheet）和画中画各算一个持有者，谁都不许把对方正在用的会话关掉。
/// 最后一个持有者走了才真正让出（并通知别的 App，让它们的音频恢复）。
///
/// 线程：只在主线程调用（SwiftUI 生命周期 / 画中画回调都在主线程）。
enum AppAudio {

    private static var holders = 0

    /// 最近一次配置失败的原因 —— 绝不吞掉（本项目的老教训）
    private(set) static var lastError: String?

    /// 需要出声、或需要画中画时调用。可以和 release() 配对多次。
    static func acquire() {
        holders += 1
        guard holders == 1 else { return }        // 已经配过了，别重复 setActive

        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback)
            try s.setActive(true)
            lastError = nil
        } catch {
            lastError = "音频会话没起来：\(error.localizedDescription)"
        }
    }

    /// 被来电 / 闹钟 / Siri 打断之后，系统会把会话置成 **inactive**。
    /// 恢复播放前必须**重新激活一次** —— 不然会出现「画面在动、但没有声音」。
    ///
    /// ★ 只在确实持有会话时做（holders > 0）：否则等于平白去抢别人的音频，
    ///   用户正在听歌会被我们掐掉。
    static func reactivate() {
        guard holders > 0 else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            lastError = nil
        } catch {
            lastError = "音频会话没能恢复：\(error.localizedDescription)"
        }
    }

    /// 不再需要时调用；最后一个持有者走了才真正让出
    static func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 给画中画失败时的诊断信息用：把会话现状说清楚
    static func describe() -> String {
        if let e = lastError { return e }
        let s = AVAudioSession.sharedInstance()
        return "\(s.category.rawValue)/\(s.isOtherAudioPlaying ? "有其它音频" : "独占")"
    }
}
