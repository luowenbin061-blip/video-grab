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
/// ★ v1.0.118：**改成可观察的单例**。
///   以前这里是纯 `enum` + 静态字典 —— 进度写进去了，但**没有任何"我变了"的通知**，
///   于是下载列表里那一行的进度线不会重画：用户播完切回来，线永远不出现
///   （用户实测原话「缩略图底部那条线我没看到」）。根因就是这个，不是没画。
///   现在：单例 + `@Published`，谁在观察（列表行）谁就跟着刷新。
///   对外**仍然保留 static 方法**，播放器那几处调用一个字都不用改。
///
/// ★ v1.0.133：加了**总开关**（设置 → 播放 → 「记录播放进度」），按用户要求**默认关**。
///   关着时：不读进度（每次从头播）、不写进度（不产生新文件）。
///   用户还要求"关掉就把已有进度一并清空" —— 见 `setEnabled(_:)`，
///   由设置页在"从开到关"的那一刻调用，把 `watch.json` 删掉。
///   所以关掉之后**界面上的进度线也不会再有**（数据都没了，本来就画不出来）。
///
/// 只在主线程调用（播放器、列表都在主线程）。
final class WatchProgress: ObservableObject {

    static let shared = WatchProgress()

    /// 总开关的 UserDefaults 键（`SettingsView` 用 @AppStorage 绑同一个键，两边天然一致）
    static let enabledKey = "resumeEnabled"

    /// 总开关：关着 → 全都不读不写。
    /// 读 UserDefaults 是常数开销，但这里还是缓存一份 —— `remember()` 每 0.25 秒就会被叫一次。
    private static var enabledCache: Bool?

    static var isEnabled: Bool {
        if let c = enabledCache { return c }
        let v = UserDefaults.standard.bool(forKey: enabledKey)   // 没设过 = false（默认关）
        enabledCache = v
        return v
    }

    /// 设置页在开关变化时调（它同时会改 UserDefaults，这里只负责同步缓存 + 该清就清）
    static func setEnabled(_ on: Bool) {
        enabledCache = on
        if !on {
            // ★ 用户要求：关掉就**一并清空**已有进度（不是只停用）。
            //   理由：留着的话，下次再打开开关会突然冒出一堆"续看位置"，
            //   中间隔了很久，用户早不记得那是什么了。
            shared.wipe()
        }
    }

    /// 任务 id → 秒数
    @Published private(set) var store: [String: Double] = [:]
    private var lastFlush = Date.distantPast

    /// 文件位置（静态一份：`init` 里还不能碰 `shared`）
    private static var fileURL: URL { JobStore.dir.appendingPathComponent("watch.json") }

    /// 小于这个秒数不值得"续看"（刚打开就切走那种，别打扰）
    static let minResume: Double = 5

    private init() { store = Self.readFromDisk() }

    private static func readFromDisk() -> [String: Double] {
        guard let d = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }

    private func flush() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)   // 原子写 —— 写一半被杀也不会留坏文件
        lastFlush = Date()
    }

    // MARK: - 实例方法（列表就是观察这个实例）

    /// 上次看到第几秒（没有记录就是 0）。★ 开关关着时永远返回 0 —— 每次从头播。
    func position(for key: String) -> Double {
        guard Self.isEnabled else { return 0 }
        guard !key.isEmpty else { return 0 }
        return max(0, store[key] ?? 0)
    }

    /// 看过多少（0~1）。没记录、或时长短得不足挂齿 → nil（界面就不画那条线）
    func fraction(for key: String, duration: Double) -> Double? {
        guard Self.isEnabled else { return nil }
        guard duration > 1 else { return nil }
        let p = position(for: key)
        guard p > Self.minResume else { return nil }
        return min(1, p / duration)
    }

    /// 记一笔。
    /// ★ 接近结尾就**当作看完**（把记录删掉）—— 否则"最后 3 秒"会永远变成
    ///   "一打开就跳结尾"，那是比不做还烦的毛病。
    /// ★ 开关关着时直接返回 —— 不写新数据（用户要的就是"完全不记"）。
    func record(_ seconds: Double, for key: String, duration: Double) {
        guard Self.isEnabled else { return }
        guard !key.isEmpty, seconds.isFinite, seconds > 0 else { return }
        let dur = (duration.isFinite && duration > 0) ? duration : 0
        if dur > 0 {
            let tail = max(5, dur * 0.02)
            if seconds >= dur - tail {
                clear(for: key)
                return
            }
        }
        store[key] = seconds                    // @Published → 列表那一行跟着重画
        // 播放中别每几秒写一次盘 —— 节流到 20 秒一次；退出时再显式刷一次
        if Date().timeIntervalSince(lastFlush) > 20 { flush() }
    }

    /// 立刻落盘（退出播放器时用）
    func flushNow() { flush() }

    func clear(for key: String) {
        guard store.removeValue(forKey: key) != nil else { return }
        flush()
    }

    /// ★ v1.0.133：把所有进度清空（关掉总开关时用）。
    /// 内存清空 + 文件删掉 —— `@Published` 会让列表那一行跟着把进度线擦掉。
    func wipe() {
        store = [:]
        try? FileManager.default.removeItem(at: Self.fileURL)
        lastFlush = Date()
    }

    // MARK: - 静态入口（播放器沿用这套写法，不用改）

    static func position(for key: String) -> Double { shared.position(for: key) }
    static func fraction(for key: String, duration: Double) -> Double? {
        shared.fraction(for: key, duration: duration)
    }
    static func record(_ seconds: Double, for key: String, duration: Double) {
        shared.record(seconds, for: key, duration: duration)
    }
    static func flushNow() { shared.flushNow() }
    static func clear(for key: String) { shared.clear(for: key) }

    /// 秒数 → "12:30" / "1:02:03"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
