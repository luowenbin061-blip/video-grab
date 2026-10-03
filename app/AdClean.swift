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

    // MARK: - 例外名单（这些网站不清理）

    private static let skipKey = "adCleanSkipHosts"

    /// 不清理的网站（host）。
    ///
    /// ★ 两种来源：① 用户点「本站不清理」手动加；② **清理器自己发现误清了正文时自动加**
    ///   （保守优先 —— 宁可这个站广告不干净，也不能让它打不开）。
    ///   设置页里能看到名单、也能逐个删掉再试。
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
