import Foundation

/// 边下边播：把**已经下载好的连续分片**变成一个动态清单，交给本机 HTTP 服务播。
///
/// ══ 为什么可行（2026-09-27 读码确认，不是猜）══
/// 分片本来就按序号留在磁盘上（`Downloader` 的 `seg_%06d.part`，注释写明"一直留到整条流程
/// 成功之后才由 DownloadJob 统一清"），而且那个目录**就在本地服务的 root 底下**
/// （root = `JobStore.dir`，分片在 `JobStore.dir/parts_<任务id>/`）——
/// 所以只要给出一个清单地址，播放器就能通过 http 把它当 HLS 播。
///
/// ══ 三条硬限制（用户 2026-09-27 明确接受）══
///   ① **加密流不做**：分片是密文，播放器拿不到 key 的上下文 →
///      用"首字节是不是 TS 同步字节 0x47"判断，不是就**不给入口**（而不是播出一片黑）；
///   ② **不能拖到还没下载的部分**：那些分片根本还不存在；
///   ③ 只列**从头连续**的分片 —— 下载是 4 路并发的，中间可能有洞，遇到第一个缺口就停。
///
/// ══ 为什么清单必须"现场生成" ══
/// 每下完一个分片，这份清单就该长一条。若写成静态文件，播放器第二次来要还是老内容，
/// 播完当前的就停了。所以清单路径是 `parts_<任务id>/live.m3u8` —— **和分片同目录**，
/// 本地服务每次 GET 现算一遍（见 `LocalHTTPServer` 里那条路由）。
///
/// ★★ v1.0.130 修的一个真 bug：v1.0.129 把清单放在一个自编的假目录 `__live/` 下，
///   结果真机一直转圈 —— 因为清单里的分片地址是**相对清单位置**解析的，
///   播放器跑去请求假目录下的分片，404。清单一进分片目录，这个问题自然消失。
///
/// ══ 一个已知的不精确 ══
/// `#EXTINF` 的时长：v1.0.133 起读 `durations.txt`（下载器在下的时候顺手记的真实时长），
/// 缺行才退回 12 秒的兜底值。它主要影响**进度条显示**（总时长），不影响能不能播下去
/// （TS 分片自带时间戳）。
///
/// ★ 这个 enum **故意不标 @MainActor**：本地服务是在后台并发队列里调它的
///   （只读磁盘，不碰 UI），标了主线程隔离就调不了。目录由调用方传进来，不依赖任何单例。
enum LivePreview {

    /// 相对 root 的清单路径：**就放在分片目录里**（`parts_<id>/live.m3u8`）。
    ///
    /// ★★ 为什么不自己编一个目录（v1.0.129 就是那么干的，结果真机一直转圈）：
    ///   HLS 清单里的分片地址是**相对于清单自己的位置**解析的。清单放在分片同目录时，
    ///   里面直接写 `seg_000001.part` 就是对的；放在别的目录（哪怕只是一个假目录名），
    ///   播放器就会去请求那个目录下的分片 → 404 → 一直转圈。
    static func relativePath(taskID: UUID) -> String {
        "\(partsDirName(taskID: taskID))/live.m3u8"
    }

    /// 从路径里认出"这是不是我们的边下边播清单"；是就返回任务 id
    static func taskID(fromPlaylistPath path: String) -> UUID? {
        let suffix = "/live.m3u8"
        guard path.hasSuffix(suffix) else { return nil }
        let dir = String(path.dropLast(suffix.count))
        guard dir.hasPrefix("parts_") else { return nil }
        return UUID(uuidString: String(dir.dropFirst("parts_".count)))
    }

    /// 分片目录名（**必须与 Downloader 里那个保持一致**：`parts_<任务id>`）
    static func partsDirName(taskID: UUID) -> String {
        "parts_\(taskID.uuidString)"
    }

    /// 从头连续存在的分片名；遇到第一个缺口（或空文件）就停
    static func contiguousParts(taskID: UUID, root: URL, cap: Int = 5000) -> [String] {
        let dir = root.appendingPathComponent(partsDirName(taskID: taskID))
        let fm = FileManager.default
        var out: [String] = []
        for i in 0..<cap {
            let name = String(format: "seg_%06d.part", i)
            let f = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: f.path),
                  ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { break }
            out.append(name)
        }
        return out
    }

    /// 分片够不够开这个入口（界面用它决定**按钮出不出现**）。
    /// 只要求"有 ≥2 个从头连续的分片" —— 格式问题放到点击后再解释，
    /// 不然用户看到的只是"按钮莫名不见了"，反而像功能坏了。
    static func hasEnoughParts(taskID: UUID, root: URL) -> Bool {
        contiguousParts(taskID: taskID, root: root).count >= 2
    }

    /// 现在能不能真的播。**不能播就返回原因**（写进提示 / 过程记录），
    /// 返回 nil 表示可以播。
    static func blockReason(taskID: UUID, root: URL) -> String? {
        let dir = root.appendingPathComponent(partsDirName(taskID: taskID))
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return "还没开始下载分片"
        }
        let parts = contiguousParts(taskID: taskID, root: root)
        if parts.isEmpty { return "还没开始下载分片" }
        if parts.count < 2 { return "已下载的分片还不够（\(parts.count) 个）" }
        // 首字节必须是 TS 的同步字节 0x47 ——
        // 加密分片（AES-128 密文）和 fMP4 分片（.m4s）都不是，播出来只会是黑的。
        let first = dir.appendingPathComponent(parts[0])
        guard let h = try? FileHandle(forReadingFrom: first) else { return "分片读不出来" }
        defer { try? h.close() }
        if h.readData(ofLength: 1).first != 0x47 {
            return "这条流的格式不支持（分片不是 TS —— 多半是 fMP4 或加密流）"
        }
        return nil
    }

    /// 兼容旧调用：能播就是 true
    static func canPlay(taskID: UUID, root: URL) -> Bool {
        blockReason(taskID: taskID, root: root) == nil
    }

    /// 时长旁注文件名（**必须与 `HLSDownloader.durationsFileName` 一致**）
    static let durationsFileName = "durations.txt"

    /// 分片时长的兜底值：旁注文件缺行时用它。
    /// 12 秒是常见 HLS 分片长度的合理中位（6~15 都有），只影响进度条，不影响播放。
    static let fallbackSegmentDuration: Double = 12

    /// 读 `durations.txt` → 下标 = 分片序号 → 秒数。文件不在 / 读不出来就是空字典。
    static func segmentDurations(taskID: UUID, root: URL) -> [Double] {
        let f = root.appendingPathComponent(partsDirName(taskID: taskID))
                     .appendingPathComponent(durationsFileName)
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map {
            Double($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    /// 现场生成清单内容。认不出是我们这条边下边播清单 → nil（让本地服务按普通文件处理）
    ///
    /// ══ ★ v1.0.133：改成 VOD，跟"下载页播的清单"同一套 ══
    /// 用户原话：「边下边播时播放器里只能看到进度条、看不到视频时长，还显示直播元素……
    /// 我的需求是边下边播时播放器也应该用下载页面里那套播放器的逻辑才对」。
    ///
    /// 以前这里是 **EVENT 型**（不写 `#EXT-X-ENDLIST`）：播放器认为这是个"还在继续的直播流"，
    /// 于是**不显示总时长**、还在界面上打出直播/LIVE 标记 —— 用户看到的就是这个。
    /// 现在改成 VOD（有 `#EXT-X-PLAYLIST-TYPE:VOD` 和 `#EXT-X-ENDLIST`），
    /// 播放器就当它是一部**有头有尾的普通片子**：总时长按清单里的分片时长算出来、
    /// 正常显示进度条，跟下载页播成品一模一样。
    ///
    /// 代价（用户 2026-09-28 明确接受）：清单只在**打开播放器的这一刻**算一次，
    /// 播到"当时已下完的位置"就停；想看新下完的部分要退出重进一次。
    /// ——列表上的进度条本来也在走，用户能看出下到哪儿了。
    ///
    /// ★ 每次请求都重算 = 用户重开播放器时清单自动变长（本机服务每次 GET 都调这里）。
    static func playlistBody(forPath path: String, root: URL) -> String? {
        guard let id = taskID(fromPlaylistPath: path) else { return nil }
        let parts = contiguousParts(taskID: id, root: root)
        guard !parts.isEmpty else { return nil }

        // 真实分片时长（缺行用兜底值补）—— 总时长就是它们的和，进度条从此是准的
        let durs = segmentDurations(taskID: id, root: root)
        func dur(_ i: Int) -> Double {
            let d = i < durs.count ? durs[i] : 0
            return d.isFinite && d > 0 ? d : fallbackSegmentDuration
        }
        let maxDur = (0..<parts.count).map(dur).max() ?? fallbackSegmentDuration

        var body = "#EXTM3U\n#EXT-X-VERSION:3\n"
        // TARGETDURATION 必须是"最长那个分片"向上取整 —— 写小了播放器会认为清单非法
        body += "#EXT-X-TARGETDURATION:\(Int(ceil(maxDur)))\n"
        body += "#EXT-X-MEDIA-SEQUENCE:0\n"
        body += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (i, n) in parts.enumerated() {
            body += "#EXTINF:\(String(format: "%.3f", dur(i))),part\n\(n)\n"
        }
        body += "#EXT-X-ENDLIST\n"
        return body
    }
}
