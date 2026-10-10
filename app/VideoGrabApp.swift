import SwiftUI

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

    static let key = "appColorScheme"
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
                // ★ v1.0.263：显示模式落到整个场景（含 sheet；fullScreenCover 另在
                //   PlayerSheet 内部也挂了一层 —— iOS 15/16 对 cover 的继承有已知坑）。
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.scheme)
                // ★ v1.0.222：「保持屏幕常亮」落到系统上（见 ScreenAwake）。
                //   挂在这里而不是 `init()` —— View 的回调在主线程，而 `UIApplication.shared`
                //   是主线程隔离的；写进 `App.init()` 有可能编不过（也不是同一个时机）。
                .onAppear { ScreenAwake.apply() }
                .onChange(of: phase) { _ in ScreenAwake.apply() }
        }
    }
}
