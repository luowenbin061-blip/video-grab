import Foundation

/// 「证书不被系统信任、但我们已经放行」的域名名单。
///
/// ★ 语义（v1.0.87 按用户要求重定）：**已经提醒过了，别再提醒。**
///   用户的原话：「不能影响我正常访问」「首次访问可以有提示，我选择了仍然访问后
///   下次就不能再提示我」「不拦截网站加载……到底选不选择访问的权利还是在用户」。
///   所以这里**不是**"黑名单"，而是"提醒过一次的记账本" —— 页面从来不会被拦下来。
///
/// ★ 为什么必须**存盘**：这份名单以前只活在内存里（`BrowserModel.trustedHosts`），
///   App 一重启就忘光 —— 同一个站下次打开又被问一遍，正好违反上面那句要求。
///   现在写进 UserDefaults，一次决定永久有效。
enum TrustedHosts {

    private static let key = "vgTrustedCertHosts"

    private static let lastHostKey = "vgTrustedCertLastHost"
    private static let lastAtKey = "vgTrustedCertLastAt"

    /// 进程内缓存一份，别为每次 TLS 握手都去读 UserDefaults
    private static var cache: Set<String>?

    /// 最近一次放行的网站 + 时间（设置页显示）。
    ///
    /// ★ 为什么要记这个：那条"已放行"的顶部提示只活几秒 —— 万一没看到，
    ///   用户要能**事后查证**"到底放行过没有"。这也让"提示没出现"这类问题可判定：
    ///   设置里显示"刚刚 · <域名>"就说明检测到了、只是提示没看到；
    ///   什么都不显示就说明检测那一层就没走到。
    static var lastApproved: (host: String, at: Date)? {
        let d = UserDefaults.standard
        guard let h = d.string(forKey: lastHostKey), !h.isEmpty else { return nil }
        return (h, Date(timeIntervalSince1970: d.double(forKey: lastAtKey)))
    }

    private static func load() -> Set<String> {
        if let c = cache { return c }
        let s = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        cache = s
        return s
    }

    /// 名单里有几个（设置页显示用）
    static var count: Int { load().count }

    static func contains(_ host: String) -> Bool {
        load().contains(host.lowercased())
    }

    /// 记下这个域名 —— **返回 true 表示"第一次见"**，调用方据此决定要不要提醒一句。
    /// 已经记过就返回 false（也就是"安静放行"）。
    @discardableResult
    static func add(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        var s = load()
        if s.contains(h) { return false }
        s.insert(h)
        cache = s
        let d = UserDefaults.standard
        d.set(Array(s), forKey: key)
        d.set(h, forKey: lastHostKey)
        d.set(Date().timeIntervalSince1970, forKey: lastAtKey)
        return true
    }

    /// 用户后悔了：全部忘掉。下次打开会重新提醒一次 —— 但页面**照样放行**，我们从不拦。
    static func forgetAll() {
        cache = []
        let d = UserDefaults.standard
        d.removeObject(forKey: key)
        d.removeObject(forKey: lastHostKey)
        d.removeObject(forKey: lastAtKey)
    }
}
