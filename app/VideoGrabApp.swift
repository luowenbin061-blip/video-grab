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
/// ★★ v1.0.273：**"系统当前外观"的桥** —— 专治"跟随系统"档对**已呈现的 sheet** 不生效。
///
/// ══ 用户实测（v1.0.272）══
/// 三档里**深色 / 浅色切换都即时生效**，**只有"跟随系统"不生效** ——
/// 选了它，**设置卡片不变浅**，退出重开才变（用户原话）。
///
/// ══ 原因（确定性）══
/// `ThemeBound` 给 sheet 传的是 `AppTheme.system.scheme` = **`nil`**，
/// 而 `preferredColorScheme(nil)` 的语义是**"我不指定"** —— SwiftUI **不会因此重绘
/// 已经呈现出来的** sheet（它只在"无 → 有"或"值发生变化"时才推）。
/// 深浅两档传的是**明确值**，所以能立即重绘；"跟随系统"传 nil → **值没变化** →
/// sheet 保持上一个主题不动。（重开设置时 sheet 重建，才重新继承到正确外观。）
///
/// ══ 解法：永远不给 nil ══
/// "跟随系统"时改传**系统当前的明确模式**（本类持有）。取值来源 =
/// `UIWindowScene.traitCollection` —— **scene 级** trait，**不受 window 的
/// `overrideUserInterfaceStyle` 影响**，所以拿到的永远是"系统真值"。
///
/// ══ 刷新时机 ══
/// ① 每次 `ThemeApplier.apply`（即用户切档时）；② 回前台时（`scenePhase` 变化）——
/// "跟随系统"档下用户去系统设置改外观，必然要切出再切回，回来就重新解析。
final class ThemeCenter: ObservableObject {
    static let shared = ThemeCenter()
    /// 系统当前模式（**明确值**，绝不为 nil）
    @Published var systemScheme: ColorScheme = .light
}

enum ThemeApplier {

    /// 立即设一次 + 下一帧再补一次（DP 建议：防"窗口/呈现还没就绪"的时序竞态）
    @MainActor
    static func apply(_ raw: String) {
        let theme = AppTheme(rawValue: raw) ?? .system
        set(theme.uiStyle)
        syncSystemScheme(theme)
        DispatchQueue.main.async {
            set(theme.uiStyle)
            syncSystemScheme(theme)     // ★ v1.0.273：下一帧再补一次
        }
    }

    /// ★ v1.0.273：把"系统当前模式"喂给 `ThemeCenter`
    /// （"跟随系统"档的 sheet 靠它拿到**明确值**，见 `ThemeCenter` 的说明）
    @MainActor
    private static func syncSystemScheme(_ theme: AppTheme) {
        ThemeCenter.shared.systemScheme = theme.scheme ?? currentSystemScheme()
    }

    /// 系统**真值**：取 **scene 级** trait —— 不受 window 的 override 影响
    @MainActor
    static func currentSystemScheme() -> ColorScheme {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene {
                return ws.traitCollection.userInterfaceStyle == .dark ? .dark : .light
            }
        }
        return .light
    }

    @MainActor
    private static func set(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}

/// ★★ v1.0.265：**面板（sheet / fullScreenCover）自己声明主题**。
///
/// 为什么必须逐层挂（用户实测第二轮逼出来的答案）：sheet 是**独立的呈现
/// （presentation）**，它有自己的外观环境 —— 挂在根视图上的 `preferredColorScheme`
/// **管不到它**（现象：在设置里切深色，**只有设置这张卡片不变**，退出去主页已经是深色）。
/// 上一版试过从 `window.overrideUserInterfaceStyle` 全局强制，实测**没救回来**
/// （被 SwiftUI 对每个呈现自己的外观管理盖掉）—— 所以改用这条**确定性**的路：
/// 每个面板的内容根上都挂一层，它自己有 `@AppStorage`，改主题必然当场生效。
struct ThemeBound: ViewModifier {
    @AppStorage(AppTheme.key) private var themeRaw = AppTheme.system.rawValue
    /// ★ v1.0.273：观察它 —— "跟随系统"档下系统外观变了，**已呈现的** sheet 才会跟着重绘
    @ObservedObject private var center = ThemeCenter.shared

    func body(content: Content) -> some View {
        // ★★ v1.0.273：**绝不给 nil**。
        //   `nil` 的语义是"我不指定"，SwiftUI **不会因此重绘已呈现的 sheet**
        //   —— 这正是"选跟随系统后设置卡片不变、要重开才变"的根因（用户实测）。
        //   "跟随系统"档改传 `center.systemScheme`（**明确的**系统值），值一变立即重绘。
        content.preferredColorScheme(AppTheme(rawValue: themeRaw)?.scheme ?? center.systemScheme)
    }
}

extension View {
    /// 给面板内容根挂主题（见 `ThemeBound` 的说明）
    func themeBound() -> some View { modifier(ThemeBound()) }
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
                .onChange(of: phase) { _ in
                    ScreenAwake.apply()
                    // ★ v1.0.273：回前台重新解析一次主题（含"系统当前外观"）——
                    //   "跟随系统"档下用户去系统设置改了外观，切回来时 sheet 要能立刻跟上；
                    //   顺带把 window 的 override 再落一次（幂等，防被系统清掉）。
                    ThemeApplier.apply(themeRaw)
                }
                // ★ v1.0.264：切换瞬间立即落到 UIKit trait（不等 SwiftUI 环境传播）——
                //   这正是"设置页当场变深色"的关键。
                .onChange(of: themeRaw) { raw in ThemeApplier.apply(raw) }
        }
    }
}
