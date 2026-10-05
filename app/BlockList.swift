import Foundation

/// 「不再加载这个站」的域名黑名单。
///
/// ★ 先分清三样东西（名字像、作用完全不同，别再搞混）：
///   · `TrustedHosts` = 证书不被信任也**照开**的放行名单 —— 它**从不拦页面**；
///   · `BlockList`（这里）= 用户**主动不让进**的站 —— 主文档导航会被拦下来；
///   · `AdClean` = 网页广告清理（清浮层）—— 跟上面两个都无关。
///
/// ★ 口径（v1.0.225 定的三条，动之前先看）：
///   ① **按域名拦，不按具体页面** —— 一个站进黑名单，它下面所有页面都进不去；
///   ② 记的时候**去掉开头的 `www.`** —— 不然会出现「加了 www.x.com，结果 x.com 照样能进」
///      这种半吊子拦截，最容易让人以为功能坏了；
///   ③ 命中判据 = **域名本身，或它的子域**（`m.example.com` 命中 `example.com`），
///      但**绝不能**用裸 `hasSuffix` —— 那样 `notexample.com` 会误中 `example.com`。
///      必须**连那个点一起比**（`.` + 规则）。
///
/// ★ 为什么存盘 + 进程内缓存：跟 `TrustedHosts` 同一个理由 ——
///   名单必须跨重启有效；而"每敲一个地址都去读一次 UserDefaults"没必要。
enum BlockList {

    private static let key = "vgBlockedHosts"

    private static var cache: Set<String>?

    private static func load() -> Set<String> {
        if let c = cache { return c }
        let s = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        cache = s
        return s
    }

    private static func save(_ s: Set<String>) {
        cache = s
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    /// 名单里有几个（设置页显示用）
    static var count: Int { load().count }

    /// 全部规则（排好序，给列表用）
    static var all: [String] { load().sorted() }

    /// 把任意输入（网址 / 域名 / 带 www 的 / 带端口路径的）规范化成"规则"。
    /// **认不出来就返回空串**（调用方据此拒绝，别把垃圾存进去）。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        // 带了协议或路径 → 交给 URL 只取主机部分
        if s.contains("://") || s.contains("/") {
            let withScheme = s.contains("://") ? s : ("http://" + s)
            if let h = URL(string: withScheme)?.host { s = h }
        }
        // 去掉端口（上面走 URL 的已经没有端口了，这条是给裸 `x.com:8080` 兜底）
        if let i = s.firstIndex(of: ":") { s = String(s[s.startIndex..<i]) }
        // ★ 口径②：统一去掉开头的 www.（带个长度守卫，别把 "www" 本身削成空串）
        if s.hasPrefix("www."), s.count > 4 { s = String(s.dropFirst(4)) }
        // 认不出来的（没有点的、空的）一律拒收
        guard !s.isEmpty, s.contains(".") else { return "" }
        return s
    }

    /// 这个 host 命中哪条规则（nil = 没命中）。返回命中的那条规则本身，便于提示里说清。
    ///
    /// ★ 子域判据必须写 `"." + rule` —— 裸 `hasSuffix(rule)` 会让
    ///   `notexample.com` 命中 `example.com`（多了个点就变成了另一个域名）。
    static func hit(_ host: String) -> String? {
        let h = host.lowercased()
        guard !h.isEmpty else { return nil }
        for rule in load() {
            if h == rule || h.hasSuffix("." + rule) { return rule }
        }
        return nil
    }

    /// 这个网址该不该拦（只取 host 判断）。
    static func blocks(_ urlString: String) -> Bool {
        guard let h = URL(string: urlString)?.host else { return false }
        return hit(h) != nil
    }

    /// 加进去。返回 true = 这次真的新增了（false = 本来就有 / 名字认不出来）。
    @discardableResult
    static func add(_ raw: String) -> Bool {
        let rule = normalize(raw)
        guard !rule.isEmpty else { return false }
        var s = load()
        if s.contains(rule) { return false }
        s.insert(rule)
        save(s)
        return true
    }

    /// 删一条。传进来的可以是域名也可以是网址，先规范化。
    static func remove(_ raw: String) {
        let rule = normalize(raw)
        guard !rule.isEmpty else { return }
        var s = load()
        s.remove(rule)
        save(s)
    }

    /// 清空
    static func forgetAll() { save([]) }

    /// ★ 跟 `TrustedHosts.invalidateCache()` 同一个理由（备份恢复会**直接改写 UserDefaults**）：
    ///   进程里那份 cache 就成了旧的 —— 不刷掉的话，列表显示和实际生效的都是旧名单，
    ///   而且用户完全看不出来（要等 App 重启才对）。
    static func invalidateCache() { cache = nil }
}
