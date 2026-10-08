import Foundation

/// ★ v1.0.238：**按站点记的名单**。
///
/// 现在只有一组：**「要清理广告的网站」**。
///
/// ══ 语义反转（用户 2026-10-09 拍板）══
///   · 以前（v1.0.236）是「**默认全都清理** + 按站豁免」—— 用户实测后判定**弊端太大**
///     （清理会误伤页面，还可能吞掉正常点击）；
///   · 现在改成「**默认一个都不清理 + 只有名单里的站才清理**」。
///   · 同时撤掉了 `.openInNewTab`（点链接弹窗里勾"以后都用新标签"）——
///     连同"手点跨站链接问一句"那套行为一起撤了，见 `BrowserModel.createWebViewWith`。
///
/// ══ 三条口径（跟 `BlockList` 保持一致，**别各写一套**）══
///   · **按域名记，不按具体页面** —— 页面地址带一堆参数（`?id=123&t=xxx`），
///     按页面记永远记不全，名单也会莫名其妙失效。
///   · 归一化：转小写 → 去协议 / 去路径 → **去开头的 `www.` / `m.` / `wap.`** → 去端口。
///     去掉那几个前缀是因为 `www.a.com` / `m.a.com` 本来就是同一个站的不同入口。
///   · 命中 = 本域 **或子域**，但必须写成 `hasSuffix("." + rule)` ——
///     裸 `hasSuffix(rule)` 会让 `nota.com` 误中 `a.com`（那是两个完全不同的站）。
///     ★ 这个坑「网页黑名单」栽过一次，见 `BlockList.hit` 的注释。
enum SiteRules {

    /// 名单（key 同时是 UserDefaults 键）
    enum Kind: String, CaseIterable, Identifiable {
        case adCleanOn      // 这个站要清理广告

        var id: String { rawValue }

        var key: String {
            switch self {
            case .adCleanOn: return "vgAdCleanOn"
            }
        }

        /// 界面上的叫法（设置页标题与提示语共用这一份）
        var title: String {
            switch self {
            case .adCleanOn: return "清理广告的网站"
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

    // MARK: - 注入用的小工具

    /// 把域名列表拼成 JS 数组字面量的**内容**（形如 `"a.com","b.com"`）。
    ///
    /// ★ 为什么单独抽到这儿：`BrowserModel.cleanerSource` 要读 Bundle 里的脚本文件，
    ///   而**测试 target 里没有 BrowserModel**（run #238 就是栽在这 —— 测试里写
    ///   `BrowserModel.cleanerSource(...)` 直接 `Cannot find 'BrowserModel' in scope`）。
    ///   拼串这一步是**纯函数**，放数据层就能被 CI 单测盯住。
    /// ★ 域名是 `normalize` 洗过的（只有字母数字点和减号），理论上不会有引号/反斜杠；
    ///   这里照样转义一遍 —— 万一哪天 normalize 放松了，拼出来的也**仍是合法 JS**
    ///   （拼坏了整段注入脚本就废了，那是查都不好查的故障）。
    static func jsList(_ hosts: [String]) -> String {
        hosts.map { h in
            "\"" + h.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: ",")
    }

    // MARK: - 清理旧键（v1.0.238 一次性）

    /// 把 v1.0.236~237 那套反转前的键**清掉**。
    ///
    /// ★ 为什么不是"迁移"：老键 `vgAdCleanSkip` 存的是「**不**清理广告的站」，
    ///   新口径是「**要**清理广告的站」—— 语义正好相反，**没有正确的映射**
    ///   （把老名单直接搬过来 = 把"以前不能碰的站"变成"现在要清理的站"，正好搞反）。
    ///   所以老数据一律丢弃，让用户在新名单里重新挑。
    static func purgeLegacyKeys() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "vgAdCleanSkip")
        d.removeObject(forKey: "vgOpenInNewTab")
        d.removeObject(forKey: "adClean")        // 广告清理的老总开关（已废）
        d.removeObject(forKey: "askOpenTarget")  // "点链接时问一句"的老开关（已废）
        invalidateCache()
    }
}
