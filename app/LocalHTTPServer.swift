import Foundation
import Darwin

/// 一个只服务本机的极简 HTTP 文件服务器（BSD socket 实现）。
///
/// 为什么这个 App 非要一个本机 HTTP 服务不可 —— 三条都是查证过的硬约束：
///
///   1. **本地 .ts 文件不能交给 AVFoundation**。Apple 开发者论坛官方回复：
///      "TS files are not and will not be supported on iOS. You must use fMP4."
///      错误发生在 AVURLAsset 建轨道那一刻，用户看到的就是「无法打开」。
///
///   2. **本地 .m3u8 文件也不行**。HLS 必须来自 http/https —— 把 m3u8 和 .ts
///      全放本地、用 file:// 交给 AVPlayer，会报 CoreMediaErrorDomain
///      -12865 / 12881。这一点多个独立来源一致（Apple 官方论坛 + 多篇实测文）。
///      （我上一版把「本地 m3u8」当备选路，是错的，这版去掉了。）
///
///   3. 所以只能：**在 App 内起一个 HTTP 服务**，把 m3u8 和 .ts 用
///      http://127.0.0.1:端口/ 暴露出去，AVPlayer / AVAssetExportSession 才读得到。
///      这也是 WLM3U 等同类库的标准做法（它们用 GCDWebServer）。
///
/// 为什么这版改用 BSD socket，而不用上一版的 Network.framework（NWListener）：
///   上一版在真机上**起不来** —— NWListener 的 port 始终是 nil，最后返回 nil。
///   怀疑是 `requiredLocalEndpoint` 配 `.any` 端口时对端口的处理有歧义，
///   而 Network.framework 的状态机不给出可读的失败原因。
///   BSD socket 的 bind/getsockname 是确定的，失败时还能拿到 errno。
///
/// 只绑 127.0.0.1，不对局域网开放。
final class LocalHTTPServer {

    static let shared = LocalHTTPServer()

    /// 干活用的并发队列：接受连接和读请求都丢这里
    private let queue = DispatchQueue(label: "vg.localhttp", attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var running = false

    private var root: URL?
    private(set) var port: UInt16 = 0
    /// 起不来时的具体原因（含 errno），会显示到界面上 —— 不能再只丢一句"没起来"
    private(set) var lastError: String?

    private init() {
        // 往已关闭的 socket 写会收到 SIGPIPE，默认动作是直接杀掉进程。
        // 播放器提前断开连接很容易触发，所以必须忽略。
        _ = signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - 生命周期

    /// 启动（幂等）。root 是要对外暴露的目录。
    @discardableResult
    func start(root: URL) -> UInt16? {
        self.root = root
        if running, port > 0, listenFD >= 0 { return port }

        lastError = nil
        closeListener()

        // 先用「系统分配端口」，不行再试几个固定端口
        let attempts: [(host: String, port: Int)] =
            [("127.0.0.1", 0), ("127.0.0.1", 18080), ("127.0.0.1", 18081),
             ("127.0.0.1", 18082), ("127.0.0.1", 18083)]

        for a in attempts {
            if let p = tryListen(host: a.host, port: a.port) { return p }
        }
        if lastError == nil { lastError = "所有端口都试过了，都起不来" }
        return nil
    }

    func stop() { closeListener() }

    private func closeListener() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        port = 0
    }

    /// 尝试在一个具体地址上监听。成功返回端口号，失败把原因写进 lastError。
    private func tryListen(host: String, port wanted: Int) -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastError = "socket() 失败 errno=\(errno)"
            return nil
        }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(wanted).bigEndian     // 网络字节序
        let converted = inet_pton(AF_INET, host, &addr.sin_addr)
        guard converted == 1 else {
            lastError = "inet_pton 失败（\(host)）"
            close(fd)
            return nil
        }

        let bound: Int32 = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            lastError = "bind(\(host):\(wanted)) 失败 errno=\(errno)"
            close(fd)
            return nil
        }

        guard listen(fd, 32) == 0 else {
            lastError = "listen 失败 errno=\(errno)"
            close(fd)
            return nil
        }

        // 问系统要回真正绑上的端口（wanted 为 0 时由系统分配）
        var actual = sockaddr_in()
        var alen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got: Int32 = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &alen)
            }
        }
        guard got == 0 else {
            lastError = "getsockname 失败 errno=\(errno)"
            close(fd)
            return nil
        }
        let assigned = UInt16(bigEndian: actual.sin_port)
        guard assigned > 0 else {
            lastError = "系统分配到的端口是 0"
            close(fd)
            return nil
        }

        listenFD = fd
        port = assigned
        running = true
        lastError = nil
        queue.async { [weak self] in self?.acceptLoop(fd) }
        return assigned
    }

    /// 拿到某个相对路径的访问地址
    func url(_ relativePath: String) -> URL? {
        guard port > 0 else { return nil }
        let clean = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        return URL(string: "http://127.0.0.1:\(port)/\(clean)")
    }

    // MARK: - accept

    private func acceptLoop(_ fd: Int32) {
        while running {
            var cli = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = accept(fd, &cli, &len)
            if cfd < 0 {
                if errno == EINTR { continue }
                if !running { break }
                Thread.sleep(forTimeInterval: 0.05)   // 别空转烧 CPU
                continue
            }
            queue.async { [weak self] in self?.serve(cfd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        // 收发都设超时，免得被半开连接占住线程
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let head = readRequestHead(fd) else { return }
        respond(fd, requestHead: head)
    }

    /// 读到请求头结束（\r\n\r\n）为止
    private func readRequestHead(_ fd: Int32) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buf.count < 64 * 1024 {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, raw.count, 0)
            }
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if let end = Self.headerEnd(buf) {
                return String(decoding: buf[0..<end], as: UTF8.self)
            }
        }
        return nil
    }

    private static func headerEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = 0
        while i + 3 < b.count {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    // MARK: - 响应

    private func respond(_ fd: Int32, requestHead: String) {
        let lines = requestHead.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else {
            sendSimple(fd, status: 400, reason: "Bad Request")
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            sendSimple(fd, status: 405, reason: "Method Not Allowed")
            return
        }
        let isHead = parts[0] == "HEAD"

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        if path.isEmpty { path = "index.m3u8" }

        guard let root else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }

        // 防目录穿越
        let rootPath = root.standardizedFileURL.path
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else {
            sendSimple(fd, status: 403, reason: "Forbidden")
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              !isDir.boolValue,
              let fh = try? FileHandle(forReadingFrom: target) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        defer { try? fh.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let total = (attrs?[.size] as? Int) ?? 0
        guard total > 0 else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }

        // Range（播放器 seek 时会要）
        var start = 0
        var end = total - 1
        var partial = false
        for l in lines where l.lowercased().hasPrefix("range:") {
            let v = l.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard let r = v.range(of: "bytes=") else { continue }
            let spec = v[r.upperBound...]
            let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let s = Int(comps.first ?? ""), s >= 0 {
                start = s
                if comps.count > 1, let e = Int(comps[1]), e >= s { end = min(e, total - 1) }
                partial = true
            } else if comps.count > 1, let e = Int(comps[1]), e > 0 {
                start = max(0, total - e)       // bytes=-N
                end = total - 1
                partial = true
            }
        }
        if start >= total || start > end {
            sendSimple(fd, status: 416, reason: "Range Not Satisfiable")
            return
        }

        let length = end - start + 1
        var header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(Self.mimeType(for: target.pathExtension))\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        header += "Connection: close\r\n\r\n"

        guard writeAll(fd, Data(header.utf8)) else { return }
        if isHead { return }

        // 分段读出再发 —— 视频可能几百 MB，不能整个读进内存
        try? fh.seek(toOffset: UInt64(start))
        var remain = length
        while remain > 0 {
            let want = min(remain, 256 * 1024)
            guard let d = try? fh.read(upToCount: want), !d.isEmpty else { break }
            guard writeAll(fd, d) else { break }
            remain -= d.count
        }
    }

    private func sendSimple(_ fd: Int32, status: Int, reason: String) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: 0\r\n"
        head += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(head.utf8))
    }

    /// 写完整，处理短写和 EINTR
    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let n = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "mp4", "m4v": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
