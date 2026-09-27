import SwiftUI

@main
struct VideoGrabApp: App {

    init() {
        // ★ v1.0.119：无图模式的拦截规则是**异步编译**的（WebKit 就这么设计的）——
        //   在这里先编译好，等用户去拨开关时就能同步拿到规则、当次加载就生效。
        NoImageMode.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
