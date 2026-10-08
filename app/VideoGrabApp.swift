import SwiftUI

@main
struct VideoGrabApp: App {

    /// 切后台 / 回前台会变 —— 回前台时把「保持屏幕常亮」再落一次
    /// （幂等、零成本；也能挡住"系统在后台期间把它清了"这种个别情况）
    @Environment(\.scenePhase) private var phase

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
                // ★ v1.0.222：「保持屏幕常亮」落到系统上（见 ScreenAwake）。
                //   挂在这里而不是 `init()` —— View 的回调在主线程，而 `UIApplication.shared`
                //   是主线程隔离的；写进 `App.init()` 有可能编不过（也不是同一个时机）。
                .onAppear { ScreenAwake.apply() }
                .onChange(of: phase) { _ in ScreenAwake.apply() }
        }
    }
}
