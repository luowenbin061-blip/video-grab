import Foundation

/// 首次打开时**主动碰一下网络**，把国行设备的「允许"XX"使用数据?」弹窗提前引出来。
///
/// ★ 为什么需要它（用户 2026-09-26 反馈）：
///   国行 iPhone 从 iOS 10 起有一个"联网权限"：新装的 App 第一次联网时系统会弹
///   「允许"XX"使用数据?」（关闭 / 仅无线局域网 / 无线局域网与蜂窝移动）。
///   但这个弹窗**只在 App 真的去联网时才弹** ——
///   而 v1.0.91 把启动改成了"空白页 / 主页"，启动时根本不会发请求，
///   于是弹窗一直不出现，要等用户去开网页才弹（用户的原话：希望打开程序就弹）。
///
/// ★ 边界（老实说）：
///   · 这个弹窗**只在国行设备**上存在，别的地区不会有 —— 那也不会有副作用；
///   · **一辈子只弹一次**：用户点了"不允许"之后系统不再弹，只能去
///     `设置 → 蜂窝网络 → 使用无线局域网与蜂窝网络` 手动开
///     （所以设置页里放了一个跳过去的入口）。
///   · 有些设备/系统版本本身就不弹（网上有 iOS 10 的已知问题记录）——
///     这种情况下我们做不了什么。
///
/// ★ 为什么"成功过就不再碰"而不是"只碰一次"：
///   万一第一次是没网、或者被拒，下次启动会再试一次 —— 不成功就再试，成功就闭嘴。
enum NetWarmup {

    private static let key = "vgNetWarmupDone"

    /// 探测用的地址：越小越好。用 HEAD 只要响应头。
    private static let probe = URL(string: "https://www.apple.com/library/test/success.html")!

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task.detached(priority: .utility) {
            var req = URLRequest(url: probe)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 6
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode < 500 {
                    UserDefaults.standard.set(true, forKey: key)   // 通了 → 以后不再打扰
                }
            } catch {
                // 被拒 / 当时没网 → 不标记，下次启动再试一次（无害）
            }
        }
    }
}
