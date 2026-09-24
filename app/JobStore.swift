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
    static func totalSize() -> Int64 {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var sum: Int64 = 0
        for u in list {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey])
            sum += Int64(v?.fileSize ?? 0)
        }
        return sum
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
