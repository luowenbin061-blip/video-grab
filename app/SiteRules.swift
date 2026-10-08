import Foundation

/// ★ v1.0.236：**按站点记的"特殊待遇"名单** —— 两条需求的存储与口径共用这一处。
///
/// 现在两组：
///   · `openInNewTab` —— 「这个站以后都用新标签打开」（点链接弹窗时勾"别再问我"）
///   · `adCleanSkip`  —— 「这个站不清理广告」（页面被误伤时当场关掉）
///
/// ══ 三条口径（跟 `BlockList` 保持一致，**别各写一套**）══
///   · **按域名记，不按具体页面** —— 页面地址带一堆参数（`?id=123&t=xxx`），
///     按页面记永远记不全，豁免也会莫名其妙失效。
///   · 归一化：转小写 → 去协议 / 去路径 → **去开头的 `www.` / `m.` / `wap.`** → 去端口。
///     去掉那几个前缀是为了**"跨站"判据**：`www.a.com` 和 `m.a.com` 必须算**同一个站**。
///   · 命中 = 本域 **或子域**，但必须写成 `hasSuffix("." + rule)` ——
///     裸 `hasSuffix(rule)` 会让 `nota.com` 误中 `a.com`（那是两个完全不同的站）。
///     ★ 这个坑「网页黑名单」栽过一次，见 `BlockList.hit` 的注释。
enum SiteRules {

    /// 两组名单（key 同时是 UserDefaults 键的后缀）
    enum Kind: String, CaseIterable, Identifiable {
        case openInNewTab     // 这个站以后都用新标签打开
        case adCleanSkip      // 这个站不清理广告

        var id: String { rawValue }

        var key: String {
            switch self {
            case .openInNewTab: return "vgOpenInNewTab"
            case .adCleanSkip:  return "vgAdCleanSkip"
            }
        }

        /// 界面上的叫法（设置页标题与提示语共用这一份）
        var title: String {
            switch self {
            case .openInNewTab: return "总用新标签打开的网站"
            case .adCleanSkip:  return "不清理广告的网站"
            }
        }
    }

    // MARK: - 归一化

    /// 输入可以是完整网址、也可以是裸域名 —— 统一成"用来比对的域名"。
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<i])
        }
        // 去端口（a.com:8080 与 a.com 是同一个站）
        if let c = s.firstIndex(of: ":") { s = String(s[..<c]) }
        // 去"手机版 / 电脑版"这类前缀 —— 它们本来就是同一个站的不同入口
        for p in ["www.", "m.", "wap."] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
            break
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: - 读（带进程内缓存：命中判断在每次导航时都会跑）

    private static var cache: [String: Set<String>] = [:]
    private static let lock = NSLock()

    private static func bag(_ k: Kind) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[k.key] { return c }
        let s = Set(UserDefaults.standard.stringArray(forKey: k.key) ?? [])
        cache[k.key] = s
        return s
    }

    private static func store(_ s: Set<String>, _ k: Kind) {
        lock.lock()
        cache[k.key] = s
        lock.unlock()
        UserDefaults.standard.set(Array(s).sorted(), forKey: k.key)
    }

    /// 设置页 / 备份恢复直接改了 UserDefaults 之后要调它（否则进程内还是老名单）
    static func invalidateCache() {
        lock.lock(); cache = [:]; lock.unlock()
    }

    // MARK: - 查询

    static func all(_ k: Kind) -> [String] { bag(k).sorted() }
    static func count(_ k: Kind) -> Int { bag(k).count }

    /// 命中了哪条规则（没命中 = nil）
    static func hit(_ host: String, in k: Kind) -> String? {
        let h = normalize(host)
        guard !h.isEmpty else { return nil }
        let rules = bag(k)
        if rules.contains(h) { return h }
        for r in rules where !r.isEmpty && h.hasSuffix("." + r) { return r }
        return nil
    }

    static func has(_ host: String, _ k: Kind) -> Bool { hit(host, in: k) != nil }

    // MARK: - 改

    /// 加一条。返回 true = 真的新加了（重复 / 太短的不算）
    @discardableResult
    static func add(_ raw: String, to k: Kind) -> Bool {
        let rule = normalize(raw)
        // 至少得像一个域名（挡掉空串和 "com" 这种）
        guard rule.contains("."), rule.count >= 4 else { return false }
        var s = bag(k)
        guard !s.contains(rule) else { return false }
        s.insert(rule)
        store(s, k)
        return true
    }

    static func remove(_ raw: String, from k: Kind) {
        let rule = normalize(raw)
        var s = bag(k)
        guard s.remove(rule) != nil else { return }
        store(s, k)
    }

    static func forgetAll(_ k: Kind) { store([], k) }

    // MARK: - "跨站"判据（点链接弹窗要用）

    /// 两个地址算不算**同一个站**。
    ///
    /// 判据：归一化后**相同** 或 **互为子域**。
    /// 归一化已经去掉了 `www.` / `m.` / `wap.`，所以 `www.a.com` ↔ `m.a.com` 会算同站。
    /// ★ 读不出来（空串）时返回 true —— **宁可少弹一次，也别因为解析不出域名就打扰他**。
    static func sameSite(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        if x.isEmpty || y.isEmpty { return true }
        if x == y { return true }
        return x.hasSuffix("." + y) || y.hasSuffix("." + x)
    }
}
