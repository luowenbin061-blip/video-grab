import Foundation

/// 磁力引擎 `lt_engine_poll` 返回的那段 JSON 的**解析与判断**（纯逻辑，可单测）。
///
/// ★★ 为什么单独一个文件、只 import Foundation：
///   它要进 `project.yml` 的纯逻辑白名单（跟 `LinkText.swift` / `BiliParse.swift` 一个规矩）。
///   "默认该下哪些文件""文件是不是视频""大小怎么显示"这几件事，
///   光看代码看不出对错，必须跑起来才算数。
///
/// ★ 故意**不引用** `DownloadJob.MediaKind`：那个类型不在测试白名单里，
///   一旦引用，测试目标就编译不过。映射放到引擎那一层去做。
enum MagnetStatus {

    // MARK: - 引擎状态

    /// 引擎阶段。
    /// ★ 名字是 `Stage` 不是 `State` —— **`State` 会跟 SwiftUI 的 `@State` 属性包装器撞名**
    ///   （工程里那个类型一致性脚本直接把这种撞名拦下来了）。
    ///   这工程里 `HLSDownloader.Stage` 已经验证过 `Stage` 不冲突。
    enum Stage: String, Equatable {
        case metadata       // 还在拉元数据（文件列表还没到手）
        case checking       // 校验/分配中
        case downloading
        /// ★ v1.0.253：元数据到手、但"还没有任何想要的数据"—— 等用户点「开始下载」，
        ///   或者用户把勾选清空了。
        ///   **注意**：libtorrent 会把这种状态报成 finished/seeding（"想要的数据
        ///   都齐了"——要的个数为 0 也是齐）——桥接层已经把它归一成 idle；
        ///   界面据此显示"等用户操作"，而不是"已完成"。
        case idle
        case finished
        case unknown
    }

    enum FileKind: Equatable {
        case video, audio, image, doc

        /// 按扩展名判断。认不出来一律当"文档"（那样默认不会被勾上）。
        init(path: String) {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "mp4", "m4v", "mkv", "avi", "mov", "wmv", "flv", "webm",
                 "ts", "m2ts", "mpg", "mpeg", "rmvb", "rm", "3gp", "vob":
                self = .video
            case "mp3", "flac", "aac", "m4a", "wav", "ogg", "opus", "ape":
                self = .audio
            case "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic":
                self = .image
            default:
                self = .doc
            }
        }
    }

    struct File: Equatable {
        var index: Int
        var path: String
        var size: Int64
        var done: Int64

        /// 显示用的文件名（去掉目录）。
        var name: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
        var progress: Double {
            size > 0 ? min(1, max(0, Double(done) / Double(size))) : 0
        }
        var kind: FileKind { FileKind(path: path) }
    }

    struct Snapshot: Equatable {
        var state: Stage = .metadata
        var name: String = ""
        /// 元数据（文件列表）到手没有。
        var metaReady: Bool = false
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var rateBytes: Int64 = 0
        var peers: Int = 0
        var progress: Double = 0
        var files: [File] = []

        // ★★ v1.0.248：这几个是用来**分辨"为什么连不上"**的。
        //   用户实测那次"一直已连上 0 个"，界面上分不出是引擎没接进网络、
        //   还是这个种真的没人做种 —— 只能干等。现在有依据了。
        /// 会话里找到这条任务没有。
        var hasHandle: Bool = true
        /// 会话登记成功了没有。
        var added: Bool = true
        /// DHT 路由表里有几个节点。**恒为 0 = 引擎根本没接进 BT 网络。**
        var dhtNodes: Int = 0
        /// 打了几个 tracker。
        var trackers: Int = 0
        /// 引擎报的错（加入失败 / torrent_error_alert）。
        var engineError: String = ""
        /// ★ v1.0.250：任务暂停没有 —— 界面的「暂停 / 继续」按钮和"已暂停"字样跟着它切。
        var paused: Bool = false
        /// ★ v1.0.253：诊断计数（DP 审查建议）——"找不到资源"时能看到
        ///   tracker 到底回没回话、peer 连接有没有在报错。
        var trackerReplies: Int = 0
        var trackerErrors: Int = 0
        var peerErrors: Int = 0
    }

    /// 「等元数据的时候到底卡在哪」—— 界面按这个换文案，而不是一律说"没人做种"。
    enum WaitReason: Equatable {
        /// 引擎压根没接受这条任务（真错）。
        case engineRejected
        /// DHT 一个节点都没有 → 网络层面就没接进去。
        case noDht
        /// 网络接上了，但一个 peer 都没有 → 这个种暂时没人做种。
        case noPeers
        /// 已经连上 peer 了，就差元数据。
        case fetching
    }

    /// 判断"卡在哪"。★ 纯函数，可单测。
    /// 注意：刚起步的头十几秒 DHT 一定是 0 个节点（正常），所以**调用方要配合
    /// "已经等了多久"来用** —— 界面在 20 秒之前不把 `noDht` 当结论。
    static func waitReason(_ s: Snapshot) -> WaitReason {
        if !s.hasHandle && !s.added { return .engineRejected }
        if s.peers > 0 { return .fetching }
        if s.dhtNodes <= 0 { return .noDht }
        return .noPeers
    }

    // MARK: - 解析

    /// 解析引擎返回的 JSON。**解析不出来就返回 nil**（调用方据此报"引擎没回话"）。
    static func parse(_ json: String) -> Snapshot? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var s = Snapshot()
        s.state = Stage(rawValue: (root["state"] as? String) ?? "") ?? .unknown
        s.name = (root["name"] as? String) ?? ""
        s.metaReady = (root["meta"] as? Bool) ?? false
        s.totalBytes = int64(root["totalBytes"])
        s.doneBytes = int64(root["doneBytes"])
        s.rateBytes = int64(root["rateBytes"])
        s.peers = Int(int64(root["peers"]))
        s.progress = double(root["progress"])
        s.hasHandle = (root["hasHandle"] as? Bool) ?? true
        s.added = (root["added"] as? Bool) ?? true
        s.dhtNodes = Int(int64(root["dhtNodes"]))
        s.trackers = Int(int64(root["trackers"]))
        s.engineError = (root["err"] as? String) ?? ""
        s.paused = (root["paused"] as? Bool) ?? false
        s.trackerReplies = Int(int64(root["trReplies"]))
        s.trackerErrors = Int(int64(root["trErrors"]))
        s.peerErrors = Int(int64(root["peerErrors"]))
        if let arr = root["files"] as? [[String: Any]] {
            s.files = arr.compactMap { o in
                guard let path = o["path"] as? String else { return nil }
                return File(index: Int(int64(o["index"])),
                            path: path,
                            size: int64(o["size"]),
                            done: int64(o["done"]))
            }
        }
        // ★ 兜底：引擎说元数据到了、但一个文件都没有 → 当"还没到"，
        //   免得界面上出现一个空列表让人以为坏了。
        if s.metaReady && s.files.isEmpty { s.metaReady = false }
        return s
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func double(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return 0
    }

    // MARK: - 默认下哪些

    /// ★ v1.0.250：这个文件能不能「边下边播」。
    ///   iOS 的 AVPlayer 只吃 mp4 系容器（mp4 / m4v / mov）——
    ///   mkv / avi 这类（哪怕里面装的是 h264）它天生不认，边不边播都一样播不了。
    ///   所以界面上只给这几个格式出「播放」按钮。
    static func streamable(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov"].contains(ext)
    }

    /// 默认该勾哪些文件。
    ///
    /// 规则（照"用户真正想要什么"来，不是照"全都下"来）：
    ///   · 有视频 → **全部视频都勾上**（一季多集是常态，少勾一集更让人烦）；
    ///   · 一个视频都没有 → 勾**体积最大的那个**（至少保证不是空的）；
    ///   · 一个文件都没有 → 返回空（调用方按"全都下"处理）。
    /// ★ 这样种子里那些 `.txt` / `.nfo` / `.url` / 预览图 / 样片自然就不会被默认下下来。
    static func defaultSelection(in files: [File]) -> Set<Int> {
        guard !files.isEmpty else { return [] }
        let videos = files.filter { $0.kind == .video }
        if !videos.isEmpty { return Set(videos.map(\.index)) }
        if let biggest = files.max(by: { $0.size < $1.size }) { return [biggest.index] }
        return []
    }

    /// 选中的文件加起来多大（给"下载选中的 N 个（共 X）"用）。
    static func totalSize(of indices: Set<Int>, in files: [File]) -> Int64 {
        files.filter { indices.contains($0.index) }.reduce(0) { $0 + $1.size }
    }

    // MARK: - 显示

    /// 体积：1.2 GB / 356 MB / 890 KB。**不用 ByteCountFormatter** ——
    /// 那个的输出跟系统语言走，单测里没法钉死。
    static func humanSize(_ n: Int64) -> String {
        if n <= 0 { return "未知" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) \(units[0])" }
        return String(format: "%.1f %@", v, units[i])
    }

    /// 速度：1.2 MB/s（不到 1 KB/s 就直接显示 B/s）。
    static func humanRate(_ n: Int64) -> String {
        guard n > 0 else { return "0 B/s" }
        return humanSize(n) + "/s"
    }
}
