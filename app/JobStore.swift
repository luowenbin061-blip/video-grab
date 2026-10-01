import Foundation

/// 程序内保存下载产物和记录的地方。
///
/// ══ 为什么放在 Library/Application Support，而不是 Documents ══
///
/// 需求是：视频**留在程序内**，下载完自动转成 mp4，由用户自己决定
/// 要不要存到相册或文件夹。
///
/// 而 Documents 一旦开了 `UIFileSharingEnabled`，就会自动暴露在系统
/// 「文件」App → 我的 iPhone → 视频抓取 里 —— 那等于"转出程序"了，
/// 用户还没做选择，文件已经在外面了。
///
/// Application Support 是 App 私有的，系统「文件」App 看不到。
/// 用户想导出时，点界面上的按钮走系统的保存/导出选择器即可。
enum JobStore {

    /// 所有下载产物、临时分片、记录都放这里
    static let dir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("VideoGrab", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var recordsURL: URL { dir.appendingPathComponent("records.json") }

    static func file(named name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    static func exists(named name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: file(named: name).path)
    }

    /// 缩略图文件名（按任务 id 命名，跟标题无关 —— 改标题不会错位）。
    ///
    /// ★ v1.0.169：从 `DownloadJob` 搬到这里。本机 HTTP 服务跑在**后台线程**，
    ///   要在那儿拼缩略图地址，而 `DownloadJob` 是 `@MainActor` 的，后台碰不得。
    ///   `DownloadJob.thumbName(for:)` 保留原入口转发过来，调用方一行都不用改。
    static func thumbName(for id: UUID) -> String { "thumb_\(id.uuidString).jpg" }

    static func size(of name: String?) -> Int64 {
        guard let name, !name.isEmpty else { return 0 }
        let a = try? FileManager.default.attributesOfItem(atPath: file(named: name).path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 设备可用空间（拿不到就 0）。
    /// ★ v1.0.160：从 `DownloadList`（一个 View）搬到这里 —— 压缩队列也要用它判断
    ///   "这批压得下吗"，而 View 上的静态成员跨类型引用又别扭又容易写错类型名
    ///   （真机上就是这么炸的：`ContentView.deviceFreeSpace` 根本没有，它在 DownloadList 上）。
    ///   放在 JobStore 最顺：它本来就是"这套目录/空间"的管家。
    static var deviceFreeSpace: Int64 {
        let u = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 删掉若干文件（不存在就跳过）
    static func remove(_ names: [String?]) {
        for n in names {
            guard let n, !n.isEmpty else { continue }
            try? FileManager.default.removeItem(at: file(named: n))
        }
    }

    /// 这个目录占了多少空间（界面上给用户看）
    ///
    /// ★ v1.0.101：改成**递归**统计。以前只算顶层条目 —— 而分片在
    /// `parts_<uuid>/` 子目录里，等于"临时文件吃掉的空间用户完全看不见"。
    static func totalSize() -> Int64 {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return list.reduce(0) { $0 + sizeOfItem($1, fm: fm) }
    }

    /// 一个文件 / 一个目录（递归）的字节数
    ///
    /// ★★ v1.0.105 修的真 bug：原来无论文件还是目录都丢给 `enumerator(at:)` ——
    ///   而 Apple 文档写得很清楚：**传进去的是文件时，这个枚举器不枚举任何东西**
    ///   （"If url is a filename, the method returns an enumerator object that
    ///   enumerates no files—the first call to nextObject() returns nil"）。
    ///   后果：顶层那些**成品文件**（.mp4 / .ts，正好是占用的大头）一个都没算进去，
    ///   界面上那个「占用」只反映了临时分片 → 下载完成后分片一清，数字几乎归零。
    ///   （v1.0.101 我加递归的**本意**是「把分片也算上」，结果反而把成品踢出去了。）
    private static func sizeOfItem(_ u: URL, fm: FileManager) -> Int64 {
        // 先分清「这是文件还是目录」—— 文件直接读大小，别走枚举器
        let own = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if own?.isRegularFile == true {
            return Int64(own?.fileSize ?? 0)
        }
        guard let e = fm.enumerator(at: u,
                                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var s: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { s += Int64(v?.fileSize ?? 0) }
        }
        return s
    }

    /// 设备可用空间（拿不到就给 nil）—— 转码前预检用
    static func freeSpace() -> Int64? {
        let u = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// 清理「下载临时文件」：所有 `parts_*` 分片目录 + `joined_*.json` 完成标记。
    /// **不动**任何成品、不动 records.json。返回释放的字节数。
    ///
    /// ★ v1.0.101：以前**完全没有清理入口** —— 失败/中断的任务把分片留着（为了续传），
    /// 但谁都不清，于是磁盘只减不增、越用越容易失败（会诊的机制②）。
    /// `keeping` 传"正在下载的任务 id"，那些任务的目录跳过（否则会把正在下的弄坏）。
    @discardableResult
    static func cleanupTemp(keeping activeIDs: Set<String> = [],
                            keepPartials: Bool = false) -> Int64 {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var freed: Int64 = 0
        for u in list {
            let n = u.lastPathComponent
            if n.hasPrefix("parts_") {
                let uid = String(n.dropFirst("parts_".count))
                if activeIDs.contains(uid) { continue }
            } else if !n.hasPrefix("joined_") {
                continue
            }
            freed += sizeOfItem(u, fm: fm)
            try? fm.removeItem(at: u)
        }
        // ★ v1.0.160：顺手把压缩的半成品也扫掉（除非**正在压** —— 那条的 .partial 还得用）
        if !keepPartials {
            freed += cleanupPartials()
        }
        return freed
    }

    /// ★ v1.0.160：扫掉「压缩的半成品」。
    ///   压缩写的是 `名字.partial.mp4` / `名字.partial.jpg`，而上面的 `cleanupTemp`
    ///   **只认 `parts_*` / `joined_*`** —— 所以一次被杀掉的压缩会留下一个
    ///   **看不见、又占空间、而且永远不会消失**的大文件（真机上就是这么攒起来的）。
    ///
    /// ★★ 判据必须精确到 **`.partial.`（前后两个点都在）**：
    ///   下载端还有 `seg_000001.part` / `direct.part` 这类文件名，那是**续传要用的**，
    ///   绝不能被一起扫掉（扫了就等于"暂停下的那半天下白下了"）。
    @discardableResult
    static func cleanupPartials() -> Int64 {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var freed: Int64 = 0
        for u in list where u.lastPathComponent.contains(".partial.") {
            freed += sizeOfItem(u, fm: fm)
            try? fm.removeItem(at: u)
        }
        return freed
    }

    // MARK: - 记录的持久化

    static func load() -> [JobRecord] {
        guard let d = try? Data(contentsOf: recordsURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // 单个字段对不上也不该让整份记录读不出来 —— 旧版本写的记录要能兼容
        if let list = try? dec.decode([JobRecord].self, from: d) { return list }

        // ★★ v1.0.195（AI 审查 P0）：以前整份解码失败就 `return []` —— 更糟的是
        //   下一次 save() 会拿空列表把文件**覆盖**，所有任务的元数据全没
        //   （视频文件还在盘上，但列表对不上号，等于"账本自己清空"）。
        //   现在三步兜底：① 坏档先备份留证；② 逐条抢救（坏一条丢一条）；③ 返回救回来的。
        //   （时间戳就地格式化 —— DownloadJob.stamp 挂在主线程上，这里调不了。）
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let badCopy = dir.appendingPathComponent("records_损坏备份_\(f.string(from: Date())).json")
        try? FileManager.default.removeItem(at: badCopy)
        try? FileManager.default.copyItem(at: recordsURL, to: badCopy)

        var rescued: [JobRecord] = []
        if let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            for one in arr {
                guard let oneData = try? JSONSerialization.data(withJSONObject: one) else { continue }
                if let rec = try? dec.decode(JobRecord.self, from: oneData) { rescued.append(rec) }
            }
        }
        return rescued
    }

    /// 写成功与否现在有返回值了（调用方暂不分支，但**写前的备份**一定做 —— 那是最后的保险）
    @discardableResult
    static func save(_ records: [JobRecord]) -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(records) else { return false }

        // ★ v1.0.195（AI 审查 P0）：写新档前把**当前这份**复制成"上一份备份" ——
        //   就算这次写入因为磁盘满失败，也还有一份能捞的。
        //   （空列表不值得备份：那就是 `[]` 两个字节。）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: recordsURL.path),
           (attrs[.size] as? Int64 ?? 0) > 2 {
            let backup = dir.appendingPathComponent("records_上一份.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: recordsURL, to: backup)
        }
        return (try? d.write(to: recordsURL, options: .atomic)) != nil
    }
}

/// 一条下载记录的持久化形态。只存"元数据"，文件本身在磁盘上。
struct JobRecord: Codable {
    var id: UUID
    var title: String
    var sourceURL: String
    /// 嗅探时的页面上下文。Referer/UA 落盘（跨重启续传过防盗链用）；
    /// **Cookie 故意不存** —— 那是登录凭据，写磁盘的代价大于收益。
    /// 可选类型：旧记录里没有这两个键，读进来是 nil，整份记录不受影响。
    var referrer: String?
    var ua: String?
    var createdAt: Date
    var finishedAt: Date?
    var finished: Bool
    var failed: String?
    /// ★ v1.0.107：用户点过「暂停」（或被系统中断）→ 落盘。
    /// 以前这个状态**不存**，重启后只能靠「没完成 + 没失败」去猜，于是
    /// 「没下完」的任务可能既不算进行中、也不算暂停/失败 → 三个按钮一个都不显示。
    /// 可选类型：老记录里没有这个键 → 解出来是 nil → 上层按老逻辑兜底，不会读不出记录。
    var paused: Bool?
    /// 能直接播的那个产物（转成功是 .mp4，没转成是 .ts）
    var outputName: String?
    var mp4Ready: Bool
    /// 没转成 mp4 时，本地 .ts 要靠本机 HTTP 包成 HLS 才能播，这条是清单文件名
    var playlistName: String?
    var fileSize: Int64
    var duration: Double
    var resolution: String?
    var phaseText: String
    var notes: [String]
    /// ★ v1.0.111：建卡时就定下来的类别（"video"/"image"/"audio"/"doc"）。
    ///   为什么必须有：`DownloadJob.mediaKind` 原来**只看成品文件名的扩展名**，
    ///   而下载中的任务还没有成品（outputName 是 nil）→ 一律被算成「文件」，
    ///   下载完 / 重启后才靠扩展名变回「视频」—— 用户看到的就是"归类自己会跳"。
    ///   可选类型：老记录里没这个键 → nil → 上层退回按扩展名判，不会读不出记录。
    var kind: String?

    /// ★ v1.0.127：**建卡那一刻的 Cookie 快照**。
    ///   为什么必须落盘：下载请求要带 Cookie 才能过防盗链 / 登录态校验，
    ///   而任务暂停隔夜、或 App 重启后恢复任务时，页面的会话早就没了 ——
    ///   以前这里不存（读回来是空串），那条续传**注定失败**，用户只看到"下载失败"却不知为什么。
    ///   放在末尾（可选类型）：老存档读进来就是 nil，向后兼容。
    var cookie: String?
}

extension JobRecord {
    /// 给人看的时间
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
