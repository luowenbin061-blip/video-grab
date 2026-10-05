import UIKit

/// 触感反馈（震动）。
///
/// ★ 为什么单开一个类型：跟 `ScreenAwake` / `AdClean` 一样，它只是「一个开关 + 几个短动作」，
///   塞进已经很大的 `BrowserModel` / `ContentView` 里不值当。
///
/// ★ 用户 2026-10-05 拍板的四条：
///   ① **一个开关**，强度**固定最轻**（不用 medium / heavy）；
///   ② 范围 = **标准**：导航（后退/前进/刷新/停止）+ 切标签 + 确认（收藏/加下载/播放）+ 完成；
///   ③ **顺手做一个下拉刷新**（这是唯一新增的交互，也是本次唯一可能出问题的点）；
///   ④ **默认开**。
///
/// ★ 明确**不震**的地方（写下来免得以后手痒）：
///   · 长按菜单弹出 —— 系统（Haptic Touch）自己会震一下，再加就是**双重震**；
///   · 页面加载完成 —— 每页都震会烦到想关掉；
///   · 卡片弹出/关闭、地址栏联想、滚动 —— 太频繁，会让 App 显廉价。
///
/// ★★ 铁律（踩过，别再踩）：
///   · **不能**给这个 enum 整体挂 `@MainActor` —— 设置页那句 `@AppStorage(Haptics.key)`
///     是在**非隔离**上下文的属性初始化器里读 `key`，而 `@MainActor` 会把类型内的
///     `static let` 一起隔离 → 直接编不过（`ScreenAwake` 已经踩过一次，见那个文件）。
///     所以只给真正需要主线程的几个方法**单独**标。
///   · 生成器是**每次新建**的：`prepare()` 之后几秒就失效，常驻一个反而会"哑"。
///     这里都是低频操作，新建 + prepare 的延迟可以忽略。
enum Haptics {

    /// UserDefaults 键。设置页的 `@AppStorage` 用同一个键。
    static let key = "hapticFeedback"

    /// 默认**开**（用户定的）。读取写法跟 `ScreenAwake.isOn` 一致：
    /// 用 `object(forKey:)` 区分「没设过」和「设成 false」——
    /// 现在两者都算开，但以后万一想改默认值，这里不用重写。
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// 轻撞击 —— 用得最多的那种。导航类（后退/前进/刷新/停止）、
    /// 确认类（收藏 / 加入下载 / 开始播放 / 下拉刷新）都走它。
    @MainActor
    static func tap() {
        guard isOn else { return }
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    /// 选择反馈 —— 三种里**最轻**的。用在「切换离散的值」：切标签、关标签、新建标签。
    @MainActor
    static func select() {
        guard isOn else { return }
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    /// 任务成功（下载完成）。有节奏的一下，是唯一比"轻撞击"更有存在感的地方。
    @MainActor
    static func success() {
        guard isOn else { return }
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    /// 任务失败（下载失败）。
    @MainActor
    static func warning() {
        guard isOn else { return }
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }
}
