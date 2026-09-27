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
/// 播完当前的就停了。所以路径走 `__live/<任务id>.m3u8`，本地服务每次 GET 现算一遍
/// （见 `LocalHTTPServer` 里那条路由）。
///
/// ══ 一个已知的不精确 ══
/// `#EXTINF` 的时长写的是固定值 —— 原始分片时长在下载器那边的清单对象里，
/// 这里拿不到。它主要影响**进度条显示**（总时长会不准），不影响能不能播下去
/// （TS 分片自带时间戳）。用户要的是"先看几段判断内容"，可接受。
///
/// ★ 这个 enum **故意不标 @MainActor**：本地服务是在后台并发队列里调它的
///   （只读磁盘，不碰 UI），标了主线程隔离就调不了。目录由调用方传进来，不依赖任何单例。
enum LivePreview {

    /// 清单的"假目录名"。磁盘上**并不存在**这个目录 ——
    /// 本地服务一看到这个前缀就现场生成内容，不会去文件系统找。
    static let routePrefix = "__live"

    /// 相对 root 的清单路径（形如 `__live/<uuid>.m3u8`）
    static func relativePath(taskID: UUID) -> String {
        "\(routePrefix)/\(taskID.uuidString).m3u8"
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

    /// 现在能不能边下边播（三条判据都要过）
    static func canPlay(taskID: UUID, root: URL) -> Bool {
        let parts = contiguousParts(taskID: taskID, root: root)
        // 只有 1 片看不出什么，两片起才有点意义
        guard parts.count >= 2 else { return false }
        // 首字节必须是 TS 的同步字节 0x47 ——
        // 加密分片（AES-128 密文）和 fMP4 分片都不是，播出来只会是黑的，不如不给入口。
        let first = root.appendingPathComponent(partsDirName(taskID: taskID))
            .appendingPathComponent(parts[0])
        guard let h = try? FileHandle(forReadingFrom: first) else { return false }
        defer { try? h.close() }
        return h.readData(ofLength: 1).first == 0x47
    }

    /// 现场生成清单内容。路径不是 `__live/...` 或算不出来 → nil（让本地服务按普通文件处理）
    static func playlistBody(forPath path: String, root: URL) -> String? {
        guard path.hasPrefix(routePrefix + "/") else { return nil }
        let tail = String(path.dropFirst(routePrefix.count + 1))
        let idStr = tail.replacingOccurrences(of: ".m3u8", with: "")
        guard let id = UUID(uuidString: idStr) else { return nil }
        let parts = contiguousParts(taskID: id, root: root)
        guard !parts.isEmpty else { return nil }

        // ★ 故意**不写 `#EXT-X-ENDLIST`**，并且标成 EVENT：
        //   这才是"还没完、会继续追加"的语义 —— 播放器才会隔一会儿再来要一次清单，
        //   于是刚下完的新分片能被接上播。
        var body = "#EXTM3U\n#EXT-X-VERSION:3\n"
        body += "#EXT-X-TARGETDURATION:11\n"
        body += "#EXT-X-MEDIA-SEQUENCE:0\n"
        body += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        for n in parts {
            body += "#EXTINF:10.0,part\n\(n)\n"
        }
        return body
    }
}
