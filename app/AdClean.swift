import Foundation

/// 「网页广告清理」的总开关 + 诊断日志。
///
/// ★ 为什么单独一个文件：BrowserModel 已经很大，而这块跟"浏览器内核"无关 ——
///   它只是「一个开关 + 一个受限大小的日志文件」。
///
/// ★ 这个类型**故意不挂 @MainActor**：它的 `record` 要在
///   `WKScriptMessageHandler` 的 `nonisolated` 回调里被调用，
///   挂上主线程隔离就会编不过（工程里踩过一次同类坑）。
enum AdClean {

    /// 总开关的 UserDefaults 键。设置页的 `@AppStorage` 用同一个键。
    static let key = "adClean"

    /// 是否开启。
    ///
    /// ★ 用 `object(forKey:)` 而不是 `bool(forKey:)` —— 后者把「没设过」和
    ///   「设成 false」都读成 false，而我们要区分的恰恰是这两者：
    ///   没设过 → **默认开**；显式关过 → 关。
    ///   （设置页那个 `@AppStorage(..., ) var = true` 在用户没动它时不会写盘，
    ///   所以这里读到 nil 就是"用户从没关过"。）
    static var isOn: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    // MARK: - 例外名单（这个网站不做自动清理）

    private static let skipKey = "adCleanSkipHosts"

    /// 不清理的网站（host）。
    ///
    /// ★★ v1.0.212 起，这份名单**只由用户手动加/减**。
    ///   以前（210/211）是"清理器自己发现误清就自动把整站加进来"—— 那是这一系列问题的根：
    ///   自检偶尔误判一次，就把**整个网站永久拉黑**，而且拉黑那一瞬间还会把当页已藏的
    ///   全部放回来 → 越用越差。**自动化只该做可撤销的动作（隐藏/还原），
    ///   不该做有记忆的惩罚（拉黑）。**
    static var skipHosts: [String] {
        UserDefaults.standard.stringArray(forKey: skipKey) ?? []
    }

    static func addSkip(_ host: String) {
        guard !host.isEmpty else { return }
        var l = skipHosts
        guard !l.contains(host) else { return }
        l.append(host)
        UserDefaults.standard.set(l, forKey: skipKey)
    }

    static func removeSkip(_ host: String) {
        guard !host.isEmpty else { return }
        UserDefaults.standard.set(skipHosts.filter { $0 != host }, forKey: skipKey)
    }

    /// ★ v1.0.212：一键清空 —— 用来救"被旧版本自动塞满"的名单。
    static func clearAllSkip() {
        UserDefaults.standard.set([String](), forKey: skipKey)
    }

    // MARK: - 保存的清理规则（点选清理保存下来的）

    private static let savedKey = "adCleanSavedRulesV1"
    private static let maxRulesPerHost = 40
    private static let maxHosts = 200

    /// host → [规则]。规则是网页层发过来的**原始 JSON 对象**，这里原样存，
    /// 不做结构解释（解释归网页层），这样以后加字段不用改这里。
    static var savedRules: [String: [[String: Any]]] {
        guard let d = UserDefaults.standard.data(forKey: savedKey),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: [[String: Any]]]
        else { return [:] }
        return o
    }

    static func addRule(host: String, rule: [String: Any]) {
        guard !host.isEmpty else { return }
        var all = savedRules
        var list = all[host] ?? []
        guard list.count < maxRulesPerHost else { return }
        if all[host] == nil && all.count >= maxHosts { return }
        list.append(rule)
        all[host] = list
        writeRules(all)
    }

    static func removeRules(for host: String) {
        guard !host.isEmpty else { return }
        var all = savedRules
        all.removeValue(forKey: host)
        writeRules(all)
    }

    static func clearAllRules() {
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    static var ruleHosts: [String] { savedRules.keys.sorted() }
    static var ruleHostCount: Int { savedRules.count }
    static var ruleCount: Int { savedRules.values.reduce(0) { $0 + $1.count } }

    /// 交给网页层用（注入时替换 `var SAVED = {};`，或运行时 `__vgSetSaved`）。
    static var savedRulesJSON: String {
        guard let d = try? JSONSerialization.data(withJSONObject: savedRules),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func writeRules(_ all: [String: [[String: Any]]]) {
        guard let d = try? JSONSerialization.data(withJSONObject: all) else { return }
        UserDefaults.standard.set(d, forKey: savedKey)
    }

    // MARK: - 诊断日志

    /// 只留最近 64KB —— 这是诊断用的，不能任它长大。
    private static let maxBytes = 64 * 1024
    private static let lock = NSLock()

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("adclean.log")
    }

    /// 记一条（由网页层的诊断回传触发）。
    ///
    /// ★ **任何失败都静默**:这只是诊断，绝不能因为它影响到浏览。
    static func record(_ body: Any) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        append("[\(stamp)] \(line)\n")
    }

    /// 日志有多大（设置页显示用）
    static var sizeBytes: Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let n = attrs[.size] as? Int else { return 0 }
        return n
    }

    private static func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += s
        if text.utf8.count > maxBytes {
            // 砍掉前半（按行切，避免把一行切一半）
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            text = lines.suffix(max(1, lines.count / 2)).joined(separator: "\n")
        }
        if let d = text.data(using: .utf8) {
            try? d.write(to: url, options: .atomic)
        }
    }
}
