import UIKit

/// 强制转屏。
///
/// 为什么要自己控方向：用户要的是「点播放就全屏 + 画面上有个横屏按钮」。
/// 而**系统自己那套全屏是一层我们插不进按钮的界面**（公开接口没有往里加东西的入口），
/// 所以播放器改成「我们自己铺满整屏」——视觉上就是全屏，按钮归我们放，转向也归我们要。
///
/// iOS 16 起有公开接口；iOS 15 上没有（那时按钮点了没反应，本机是 16.6 没问题）。
enum ScreenOrientation {

    static func lock(_ mask: UIInterfaceOrientationMask) {
        guard #available(iOS 16.0, *) else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        // 还要让根控制器重新问一次「支持哪些方向」，少了这步不生效
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    static func landscape() { lock(.landscape) }
    static func portrait() { lock(.portrait) }
}
