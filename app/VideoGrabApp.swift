import SwiftUI
import UIKit

/// ★ v1.0.263：显示模式 —— **跟随系统**（默认，= 老行为）/ 浅色 / 深色。
///   通用设置 → 外观 里切；存 `@AppStorage`（UserDefaults），全局即时生效。
///   `scheme = nil` 正好是 `preferredColorScheme` "跟随系统" 的语义（零额外成本）。
///   （DP 复核：三项设计 —— 只做两项会让"选了深色"的人没有回头路；默认 system
///   与现状完全一致，不改现有行为。）
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` = 跟随系统（`preferredColorScheme(nil)` 的既定语义）
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 对应的 **UIKit** 强制值（见 `ThemeApplier`）
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let key = "appColorScheme"
}

/// ★★ v1.0.264：把显示模式落到 **UIKit trait** 上（`window.overrideUserInterfaceStyle`）。
///
/// ══ 为什么必须有它（用户实测两个问题，DP 复核定案）══
/// `preferredColorScheme` 只管 **SwiftUI 的环境**，管不到 UIKit 层，于是（用户系统=浅色、
/// App 内强制深色时）：
///   · 在设置里切深色 —— **设置页当场不变**，退出重进才变：sheet 是独立的
///     presentation，它有自己的 trait，不跟随 SwiftUI 环境；
///   · 下拉关闭弹出的卡片时 **四周闪白**：毛玻璃（UIVisualEffectView）在 opacity
///     动画期间处于 Apple 说的 "broken" 状态（官方明说：给 visual effect view 或其
///     父视图设 alpha < 1 会导致效果渲染不正确），此时它若按 **系统**（浅色）外观
///     渲染 → 闪白。trait 脱节把这个问题放大了。
/// 在 window 上强制之后，**窗口内所有内容**（含已呈现 / 新弹出的 sheet、系统控件、
/// 材质）立即跟随 —— Apple 文档明确（DP 复核确认）。
/// 与 `preferredColorScheme` 是**两层互补**（一个管 SwiftUI 环境、一个管 UIKit trait），
/// 值永远同源（都从 `AppTheme.key` 派生），不会打架。
enum ThemeApplier {

    /// 立即设一次 + 下一帧再补一次（DP 建议：防"窗口/呈现还没就绪"的时序竞态）
    @MainActor
    static func apply(_ raw: String) {
        let style = (AppTheme(rawValue: raw) ?? .system).uiStyle
        set(style)
        DispatchQueue.main.async { set(style) }
    }

    @MainActor
    private static func set(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}

@main
struct VideoGrabApp: App {

    /// 切后台 / 回前台会变 —— 回前台时把「保持屏幕常亮」再落一次
    /// （幂等、零成本；也能挡住"系统在后台期间把它清了"这种个别情况）
    @Environment(\.scenePhase) private var phase
    /// ★ v1.0.263：显示模式（通用设置 → 外观 里切）。老用户无此键 → system（= 现状）。
    @AppStorage(AppTheme.key) private var themeRaw = AppTheme.system.rawValue

    init() {
        // ★ v1.0.119：无图模式的拦截规则是**异步编译**的（WebKit 就这么设计的）——
        //   在这里先编译好，等用户去拨开关时就能同步拿到规则、当次加载就生效。
        NoImageMode.warmUp()

        // ★ v1.0.238：清掉广告清理**反转之前**的那几个键。
        //   老键存的是"**不**清理的站"，新口径是"**要**清理的站"—— 语义正好相反，
        //   没有正确的映射，只能丢（详见 `SiteRules.purgeLegacyKeys`）。
        SiteRules.purgeLegacyKeys()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // ★ v1.0.264：**根衬底** —— 卡片关闭 / 动画重绘的某一帧若露出窗口底，
                //   露出的也必须是当前主题的底色（原来是"露出啥算啥"，深色下就会闪白）。
                //   深色下等于纯黑（与现在的观感完全一致），浅色下等于白。
                .background(Color(.systemBackground).ignoresSafeArea())
                // ★ v1.0.263：显示模式落到整个场景（含 sheet；fullScreenCover 另在
                //   PlayerSheet 内部也挂了一层 —— iOS 15/16 对 cover 的继承有已知坑）。
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.scheme)
                // ★ v1.0.222：「保持屏幕常亮」落到系统上（见 ScreenAwake）。
                //   挂在这里而不是 `init()` —— View 的回调在主线程，而 `UIApplication.shared`
                //   是主线程隔离的；写进 `App.init()` 有可能编不过（也不是同一个时机）。
                .onAppear {
                    ScreenAwake.apply()
                    ThemeApplier.apply(themeRaw)      // ★ v1.0.264：首启动落一次 UIKit trait
                }
                .onChange(of: phase) { _ in ScreenAwake.apply() }
                // ★ v1.0.264：切换瞬间立即落到 UIKit trait（不等 SwiftUI 环境传播）——
                //   这正是"设置页当场变深色"的关键。
                .onChange(of: themeRaw) { raw in ThemeApplier.apply(raw) }
        }
    }
}
