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

    static func size(of name: String?) -> Int64 {
        guard let name, !name.isEmpty else { return 0 }
        let a = try? FileManager.default.attributesOfItem(atPath: file(named: name).path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
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
    static func cleanupTemp(keeping activeIDs: Set<String> = []) -> Int64 {
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
        return freed
    }

    // MARK: - 记录的持久化

    static func load() -> [JobRecord] {
        guard let d = try? Data(contentsOf: recordsURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // 单个字段对不上也不该让整份记录读不出来 —— 旧版本写的记录要能兼容
        return (try? dec.decode([JobRecord].self, from: d)) ?? []
    }

    static func save(_ records: [JobRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(records) else { return }
        try? d.write(to: recordsURL, options: .atomic)
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
}

extension JobRecord {
    /// 给人看的时间
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
