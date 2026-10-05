import UIKit

/// 「保持屏幕常亮」—— 开着时，App 在前台就不自动息屏。
///
/// ★ 为什么单开一个类型：跟 `NoImageMode` / `AdClean` 一样，它只是「一个开关 + 一个小动作」，
///   塞进已经很大的 `BrowserModel` 里不值当。
///
/// ★ 三条边界（动这块之前先知道）：
///   · **只在前台有效** —— 切到别的 App / 锁屏之后，系统照旧息屏。这是 iOS 机制，改不了。
///   · **播视频时本来就不会息屏**（系统行为）—— 所以这个开关真正的用处在
///     「看网页 / 等下载」的时候。
///   · `isIdleTimerDisabled` 是**进程级**的：设一次就一直有效，直到进程结束或再改回来；
///     所以启动时落一次、用户拨开关时再落一次就够了。
///
/// ★ 用户 2026-10-05 拍板的三条：放「通用设置」、**默认关**、**不写**耗电提示（名字够清楚）。
///
/// ★★ **不能**给这个 enum 挂 `@MainActor`：设置页里 `@AppStorage(ScreenAwake.key)` 是在
///   **非隔离**上下文的属性初始化器里读 `key`，而 `@MainActor` 会把类型内的 `static let`
///   一起隔离 → 那句直接编不过。所以只给 `apply()` 单独标。
enum ScreenAwake {

    /// UserDefaults 键。设置页的 `@AppStorage` 用同一个键。
    static let key = "keepScreenAwake"

    /// 默认**关**（省电优先）。
    /// 读取写法跟 `AdClean.isOn` 保持一致：用 `object(forKey:)` 区分「没设过」和「设成 false」——
    /// 现在两者都算关，但以后万一想改成默认开，这里不用重写。
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? false
    }

    /// 把开关状态落到系统上。**幂等** —— 启动时、拨开关时、回到前台时都可以随便调。
    ///
    /// ★ 只给这个方法标 `@MainActor`（不是整个 enum）：`UIApplication.shared` 是主线程隔离的，
    ///   而调用方（View 的 `onAppear` / `onChange`）本来就都在主线程。
    @MainActor
    static func apply() {
        UIApplication.shared.isIdleTimerDisabled = isOn
    }
}
