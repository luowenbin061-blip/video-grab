import Foundation

/// 「看到哪儿了」—— 续看用的进度记录。
///
/// 为什么要单独存一份（而不是塞进 `JobRecord`）：
///   · `records.json` 是**任务**的账本（下载阶段、产物、诊断）；"看到第几秒"是**播放**的事。
///     任务被删、文件重下，播放进度也该跟着走，别互相拖累。
///   · 也给"列表上那条细线"用，但它只是个附带好处。
///
/// ★ 键用**任务 id**，不是文件名：转码会把 `.ts` 换成 `.mp4`、名字会变，
///   但 id 是稳定的；同一条任务"本地播 / 在线播"也共用同一份进度。
///   代价：删掉任务再重下同一部片子 → 进度从头开始（这个可以接受，也没法更准）。
///
/// 只在主线程调用（播放器、列表都在主线程）。
enum WatchProgress {

    /// 任务 id → 秒数
    private static var store: [String: Double] = load()
    private static var lastFlush = Date.distantPast

    private static var url: URL { JobStore.dir.appendingPathComponent("watch.json") }

    /// 小于这个秒数不值得"续看"（刚打开就切走那种，别打扰）
    static let minResume: Double = 5

    private static func load() -> [String: Double] {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }

    private static func flush() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: url, options: .atomic)      // 原子写 —— 写一半被杀也不会留坏文件
        lastFlush = Date()
    }

    /// 上次看到第几秒（没有记录就是 0）
    static func position(for key: String) -> Double {
        guard !key.isEmpty else { return 0 }
        return max(0, store[key] ?? 0)
    }

    /// 看过多少（0~1）。没记录、或时长短得不足挂齿 → nil（界面就不画那条线）
    static func fraction(for key: String, duration: Double) -> Double? {
        guard duration > 1 else { return nil }
        let p = position(for: key)
        guard p > minResume else { return nil }
        return min(1, p / duration)
    }

    /// 记一笔。
    /// ★ 接近结尾就**当作看完**（把记录删掉）—— 否则"最后 3 秒"会永远变成
    ///   "一打开就跳结尾"，那是比不做还烦的毛病。
    static func record(_ seconds: Double, for key: String, duration: Double) {
        guard !key.isEmpty, seconds.isFinite, seconds > 0 else { return }
        let dur = (duration.isFinite && duration > 0) ? duration : 0
        if dur > 0 {
            let tail = max(5, dur * 0.02)
            if seconds >= dur - tail {
                clear(for: key)
                return
            }
        }
        store[key] = seconds
        // 播放中别每几秒写一次盘 —— 节流到 20 秒一次；退出时再显式刷一次
        if Date().timeIntervalSince(lastFlush) > 20 { flush() }
    }

    /// 立刻落盘（退出播放器时用）
    static func flushNow() { flush() }

    static func clear(for key: String) {
        guard store.removeValue(forKey: key) != nil else { return }
        flush()
    }

    /// 秒数 → "12:30" / "1:02:03"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
