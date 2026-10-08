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

    // ★★ v1.0.238：这里的「总开关」（原来的 `key` / `isOn`）**已删除** ——
    //   广告清理改成**按站名单**（`SiteRules.adCleanOn`：只清名单里的站），
    //   不再有"全开 / 全关"这回事。于是这个类型只剩下一件事：
    //   **接住网页层回传的诊断信息**（下面这段）。

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
