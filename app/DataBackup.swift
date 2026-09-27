import Foundation

/// 数据备份 / 恢复：把"这台设备上攒下来的东西"打包成一个 JSON。
///
/// ══ 为什么需要（用户 2026-09-27 提的）══
/// 这是个**单机** App（没有 iCloud、没有账号）。重装 IPA、换机、或者手滑删掉 App，
/// 书签 / 下载记录 / 首页快捷入口 / 播放进度 / 设置就全没了 —— 而这些都是用时间攒出来的。
///
/// ══ 不打包什么 ══
/// **不打包 Cookie** —— 那里面是登录态，导出的 JSON 一旦发出去（发微信、传电脑），
/// 等于把登录态一起送出去。任务记录里的 cookie 值在导出时会被抹成空串，
/// 恢复回来那些任务续传时要重新去页面取一次上下文。
///
/// ══ 恢复是"覆盖" ══
/// 用户明确要覆盖。覆盖前**自动把当前数据另存一份**（`恢复前备份-<时间>.json`），
/// 恢复错了还能回滚。恢复后各模块内存里的还是老数据（Store 都是单例），
/// 所以要提示"完全重启 App 才生效"。
///
/// ★ 故意不标 @MainActor：全是文件/UserDefaults 操作，不碰 UI。
enum DataBackup {

    static let appTag = "VideoGrab"
    static let formatVersion = 1

    /// 打包的文件（都放 `JobStore.dir` 下）
    static let fileNames = ["bookmarks.json", "records.json", "tabs.json",
                            "watch.json", "shortcuts.json"]

    /// 打包的设置项 —— **白名单**，不是"把 UserDefaults 全导出去"
    /// （那会把系统 / 别的库塞进来的无关键也带上）。
    static let defaultsKeys = [
        "homePageURL",          // 主页地址
        "desktopUA",            // 桌面模式
        "noImageMode",          // 无图模式
        "sniffButtonResident",  // 嗅探按钮常驻屏幕
        "autoSniff",            // 后台自动嗅探
        "playerPiPEnabled",     // 播放小窗
        "lpDebug",              // 长按诊断条
        "lpLongPressDownload",  // 长按下载
        "vg.fixedTokenOn",      // 记住局域网口令
        "vg.fixedToken",        // 口令本身
        // ★ v1.0.133：两个新的播放开关也一起带走（用户 2026-09-28 要求补）
        "resumeEnabled",        // 记录播放进度
        "autoLandscape",        // 首次播放自动横屏
    ]

    /// ★ v1.0.133：「已放行网站」的名单（用户要求补进备份）。
    ///
    /// ══ 为什么只能"带名单"，不能"带信任关系" ══
    /// 用户原话是"补上已放行网站列表"。这里必须说清楚一个系统限制：
    ///   · 这份名单本身（`vgTrustedCertHosts`）只是**一串域名**，存在 UserDefaults 里 —— 能原样带走；
    ///   · 但**"信任这张证书"这件事是系统密钥串里的记录，绑当前设备**，
    ///     SDK 没有"导出信任 / 导入信任"的接口，别的设备也不会认。
    /// 所以恢复之后：名单回来了（设置页能看见那几个域名），但**证书还得用户自己再点一次信任**。
    /// 我们绝不在界面上假装"已自动恢复信任" —— 做不到的事不装作做到了。
    static let trustedHostsKey = "vgTrustedCertHosts"

    enum BackupError: LocalizedError {
        case badFormat
        case tooNew
        case empty

        var errorDescription: String? {
            switch self {
            case .badFormat: return "这个文件不是本程序导出的备份。"
            case .tooNew:    return "这份备份来自更新的版本，当前版本恢复不了。"
            case .empty:     return "这个备份里没有任何数据。"
            }
        }
    }

    // MARK: - 导出

    /// 生成备份数据（调用方负责落盘 + 弹分享面板）
    static func exportData() throws -> Data {
        var files: [String: String] = [:]
        for n in fileNames {
            guard let d = try? Data(contentsOf: JobStore.file(named: n)) else { continue }
            var text = String(data: d, encoding: .utf8) ?? ""
            // ★ 任务记录里的 cookie 抹掉（见文件头说明）
            if n == "records.json" { text = stripCookies(text) }
            files[n] = text
        }

        var defaults: [String: Any] = [:]
        let ud = UserDefaults.standard
        for k in defaultsKeys where ud.object(forKey: k) != nil {
            defaults[k] = ud.object(forKey: k)
        }

        // ★ v1.0.133：带上「已放行网站」的域名名单（只是字符串，不含任何证书）。
        //   空名单不写这个键 —— 免得备份文件里多一个没用的空数组。
        let hosts = ud.stringArray(forKey: trustedHostsKey) ?? []
        if !hosts.isEmpty { defaults[trustedHostsKey] = hosts }

        guard !files.isEmpty || !defaults.isEmpty else { throw BackupError.empty }

        let payload: [String: Any] = [
            "app": appTag,
            "version": formatVersion,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "files": files,
            "defaults": defaults,
        ]
        return try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// 把 `"cookie":"..."` 抹成空串（保留字段名 —— 读出来是空串，退回"没存上下文"）
    private static func stripCookies(_ s: String) -> String {
        s.replacingOccurrences(of: "\"cookie\"\\s*:\\s*\"[^\"]*\"",
                               with: "\"cookie\":\"\"",
                               options: .regularExpression)
    }

    // MARK: - 恢复（覆盖）

    /// 恢复并返回一段给用户看的结果说明
    static func restore(from data: Data) throws -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let app = obj["app"] as? String, app == appTag else {
            throw BackupError.badFormat
        }
        let v = (obj["version"] as? NSNumber)?.intValue ?? 0
        guard v <= formatVersion else { throw BackupError.tooNew }

        // ① 覆盖前先把**当前**数据另存一份 —— 恢复错了还能回滚
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        if let cur = try? exportData() {
            try? cur.write(to: JobStore.file(named: "恢复前备份-\(f.string(from: Date())).json"),
                           options: .atomic)
        }

        // ② 覆盖写回
        var nFile = 0
        var nKey = 0
        if let files = obj["files"] as? [String: String] {
            for (name, text) in files where fileNames.contains(name) {
                guard let d = text.data(using: .utf8) else { continue }
                if (try? d.write(to: JobStore.file(named: name), options: .atomic)) != nil { nFile += 1 }
            }
        }
        if let defs = obj["defaults"] as? [String: Any] {
            let ud = UserDefaults.standard
            for (k, val) in defs where defaultsKeys.contains(k) {
                ud.set(val, forKey: k)
                nKey += 1
            }
        }

        // ★ v1.0.133：把「已放行网站」的名单读回来。
        //   ★ 只能恢复名单，**恢复不了信任**（系统不给这个能力，见 trustedHostsKey 的说明）。
        //   所以这里同时把 "最近一次放行" 清掉 —— 那条记录指向的是旧设备上的旧时间点，
        //   留着会让设置页显示一个对不上的"最近一次"。名单本身照常回来。
        var nHosts = 0
        if let defs = obj["defaults"] as? [String: Any] {
            let ud = UserDefaults.standard
            let hosts = (defs[trustedHostsKey] as? [String]) ?? []
            if !hosts.isEmpty {
                ud.set(hosts, forKey: trustedHostsKey)
                TrustedHosts.invalidateCache()      // 它内部有进程内缓存，不刷就还是老名单
                nHosts = hosts.count
            }
            ud.removeObject(forKey: "vgTrustedCertLastHost")
            ud.removeObject(forKey: "vgTrustedCertLastAt")
        }

        var text = "已恢复 \(nFile) 个数据文件、\(nKey) 项设置。\n"
        if nHosts > 0 {
            // ★ 说清楚"为什么还要手动点一次" —— 别让用户以为功能没生效
            text += "已放行的网站名单也带回来了（\(nHosts) 个）。\n"
                + "注意：**证书信任这件事系统不让程序代劳** —— "
                + "这几家网站下次打开还会提醒你放行一次，点一下「仍然访问」就记住了。\n"
        }
        text += "要完全退出 App 再打开才生效（现在内存里还是旧数据）。\n"
            + "恢复前的旧数据已另存为「恢复前备份-\(f.string(from: Date())).json」。"
        return text
    }
}
