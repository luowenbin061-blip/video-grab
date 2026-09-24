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
/// **两种模式**，默认只服务本机：
///   · 普通模式：只绑 127.0.0.1，播放器自己取文件用，外面看不见。
///   · 局域网模式（用户点「共享」才开）：改绑 0.0.0.0，同一 Wi-Fi 下的电脑
///     用浏览器就能看到目录、下载文件。**必须带口令**（见 token）——
///     回环地址（手机自己）不需要口令，所以播放这条路完全不受影响。
///
/// 口令放在路径第一段（`/<token>/xxx`），不认就 403。它不是加密，
/// 只是一道门牌：挡住同一 Wi-Fi 下瞎扫端口的陌生人。用完关掉即可。
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

    // MARK: - 局域网共享

    /// 是否对局域网开放（默认关 —— 不主动把手机里的文件露出去）
    private(set) var lanEnabled = false
    /// 访问口令。局域网访客必须在路径第一段带上它；回环（手机自己）不用。
    private(set) var token = ""

    /// 电脑上要打开的地址，形如 http://192.168.1.7:18080/3f9a1c07b2e4d5a6/
    /// 没连 Wi-Fi（拿不到局域网 IP）时返回 nil。
    var lanURL: URL? {
        guard lanEnabled, port > 0, let ip = Self.lanIPAddress() else { return nil }
        return URL(string: "http://\(ip):\(port)/\(token)/")
    }

    /// 给 WebDAV 客户端用的根地址：**不带口令段**，口令走 Basic 认证。
    /// 形如 http://192.168.1.7:18080/ —— 客户端里填这个 + 用户名随便 + 密码＝口令。
    /// （地址里塞口令那种写法，WebDAV 客户端有的认有的不认，Basic 才是通用做法。）
    var davURL: URL? {
        guard lanEnabled, port > 0, let ip = Self.lanIPAddress() else { return nil }
        return URL(string: "http://\(ip):\(port)/")
    }

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

        // 局域网模式要先把固定端口试一遍 —— 地址稳定（18080）才好往电脑地址栏敲；
        // 普通模式没人在意端口，让系统随便分配。
        let host = lanEnabled ? "0.0.0.0" : "127.0.0.1"
        let ports = lanEnabled ? [18080, 18081, 18082, 18083, 0] : [0, 18080, 18081, 18082, 18083]

        for p in ports {
            if let got = tryListen(host: host, port: p) { return got }
        }
        if lastError == nil { lastError = "所有端口都试过了，都起不来" }
        return nil
    }

    func stop() { closeListener() }

    // MARK: - 开 / 关 局域网共享

    /// 打开共享。root 传 nil 就沿用上次的目录。成功返回 true（去 lanURL 拿地址）。
    @discardableResult
    func enableLAN(root wanted: URL? = nil) -> Bool {
        if let wanted { root = wanted }
        guard let root else {
            lastError = "还没有可共享的目录"
            return false
        }
        if lanEnabled, running, port > 0 { return true }

        if token.isEmpty { token = Self.makeToken() }
        lanEnabled = true
        closeListener()                 // 换绑地址（127.0.0.1 → 0.0.0.0）必须重新监听
        let reached = start(root: root)
        if reached == nil { lanEnabled = false; token = "" }
        return reached != nil
    }

    /// 关掉共享，退回「只服务本机」。口令一并清掉，下次开又是新的。
    func disableLAN() {
        guard lanEnabled else { return }
        lanEnabled = false
        token = ""
        let keep = root
        closeListener()
        if let keep { _ = start(root: keep) }
    }

    /// 16 位十六进制口令（UInt32.random 底层走的是系统的密码学随机源）
    private static func makeToken() -> String {
        String(format: "%08x%08x",
               UInt32.random(in: UInt32.min...UInt32.max),
               UInt32.random(in: UInt32.min...UInt32.max))
    }

    /// 手机当前的局域网 IPv4（优先 Wi-Fi 接口 en0）。没连 Wi-Fi 返回 nil。
    static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        if String(cString: ifa.ifa_name) == "en0" { return ip }
                        if fallback == nil { fallback = ip }
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        return fallback
    }

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
            var cli = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd: Int32 = withUnsafeMutablePointer(to: &cli) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &len)
                }
            }
            if cfd < 0 {
                if errno == EINTR { continue }
                if !running { break }
                Thread.sleep(forTimeInterval: 0.05)   // 别空转烧 CPU
                continue
            }
            // 记下对端地址：回环＝手机自己（播放器），局域网访客才要口令
            let isLocal = Self.isLoopback(cli)
            queue.async { [weak self] in self?.serve(cfd, isLocal: isLocal) }
        }
    }

    /// 对端是不是回环地址（用 inet_pton 比对，避免自己算字节序）
    private static func isLoopback(_ addr: sockaddr_in) -> Bool {
        var loop = in_addr()
        guard inet_pton(AF_INET, "127.0.0.1", &loop) == 1 else { return false }
        return addr.sin_addr.s_addr == loop.s_addr
    }

    private func serve(_ fd: Int32, isLocal: Bool) {
        defer { close(fd) }

        // 收发都设超时，免得被半开连接占住线程
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let req = readRequestHead(fd) else { return }
        respond(fd, requestHead: req.head, isLocal: isLocal, extraBody: req.extra)
    }

    /// 读到请求头结束（\r\n\r\n）为止。
    ///
    /// ★ 必须把「多读到的那截请求体」一起带出去：一次 recv 常常把头和请求体开头
    ///   一起收进来。以前这里直接丢掉多余字节 —— GET 没有请求体，所以一直没暴露；
    ///   PUT 上传会因此丢掉文件开头几个字节（值得庆幸的是它坏得很明显）。
    private func readRequestHead(_ fd: Int32) -> (head: String, extra: Data)? {
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
                let bodyStart = end + 4
                let head = String(decoding: buf[0..<end], as: UTF8.self)
                let extra = bodyStart < buf.count ? Data(buf[bodyStart...]) : Data()
                return (head, extra)
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

    private func respond(_ fd: Int32, requestHead: String, isLocal: Bool,
                         extraBody: Data = Data()) {
        let lines = requestHead.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else {
            sendSimple(fd, status: 400, reason: "Bad Request")
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimple(fd, status: 400, reason: "Bad Request")
            return
        }
        let method = String(parts[0]).uppercased()
        let isHead = method == "HEAD"
        // 允许的方法：GET/HEAD 给浏览器与播放器；后面那一串给 WebDAV 客户端。
        // 白名单形式（不写 else 兜底）—— 免得将来手滑多认一个方法。
        let allowed: Set<String> = ["GET", "HEAD", "OPTIONS", "PROPFIND",
                                    "PUT", "DELETE", "MKCOL", "MOVE", "COPY",
                                    "LOCK", "UNLOCK"]
        guard allowed.contains(method) else {
            sendSimple(fd, status: 405, reason: "Method Not Allowed")
            return
        }
        // 非 GET/HEAD 的就是 WebDAV 那套，后面单独走
        let isDAV = !(method == "GET" || method == "HEAD")

        // ★ 原始路径（含口令前缀）。PROPFIND 要把它原样写回 href ——
        //   客户端拿 href 认资源，改一个字符它就不认识自己刚列出来的东西了。
        var rawPath = String(parts[1])
        if let q = rawPath.firstIndex(of: "?") { rawPath = String(rawPath[..<q]) }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        // 空路径 = 根目录 → 走目录列表（播放器取的永远是具体文件名，不受影响）

        guard let root else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }

        // 局域网访客必须带口令；手机自己的播放器（回环）放行，播放链路零影响。
        // 两种带法都认：
        //   ① 路径第一段（/<口令>/…）—— 浏览器、播放器、手机自己用这个
        //   ② HTTP Basic（用户名随意填，密码 = 口令）—— WebDAV 客户端用这个，
        //      它们通常先不带凭据探一次，我们要回 401 + WWW-Authenticate 引导它重试
        if lanEnabled, !isLocal, !token.isEmpty {
            if path == token || path == "/" + token {
                path = ""                                    // /<口令> → 根目录
            } else if path.hasPrefix("/" + token + "/") {
                path = String(path.dropFirst(token.count + 2))
            } else if path.hasPrefix(token + "/") {
                path = String(path.dropFirst(token.count + 1))
            } else if Self.basicAuthPassword(lines) == token {
                // 凭据对了 —— 路径里不用再带口令
            } else if isDAV {
                sendAuthChallenge(fd)
                return
            } else {
                sendForbiddenPage(fd)
                return
            }
        }

        // 防目录穿越
        var rootPath = root.standardizedFileURL.path
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        let target = path.isEmpty
            ? root.standardizedFileURL                     // 空路径 = 根目录本身
            : root.appendingPathComponent(path).standardizedFileURL
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else {
            sendSimple(fd, status: 403, reason: "Forbidden")
            return
        }

        // ── WebDAV 那套方法在这里处理完就返回（它们对「文件不存在」的含义不同：
        //    对 PUT 是"新建"，对 DELETE 才是"找不到"）──
        if isDAV {
            handleWebDAV(fd, method: method, target: target, rawPath: rawPath,
                         root: root, lines: lines, extraBody: extraBody)
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        // 目录 → 目录列表页（「用电脑浏览器进来挑文件」就靠这一页）
        if isDir.boolValue {
            sendDirectoryList(fd, dir: target, relPath: path, isLocal: isLocal)
            return
        }

        guard let fh = try? FileHandle(forReadingFrom: target) else {
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

    private func sendHTML(_ fd: Int32, status: Int, reason: String, html: String) {
        let body = Data(html.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        guard writeAll(fd, Data(head.utf8)) else { return }
        _ = writeAll(fd, body)
    }

    private func sendForbiddenPage(_ fd: Int32) {
        sendHTML(fd, status: 403, reason: "Forbidden", html: """
        <!doctype html><meta charset="utf-8"><title>需要访问口令</title>
        <body style="font:15px -apple-system,system-ui,sans-serif;margin:40px;color:#111">
        <h2>需要访问口令</h2>
        <p>请用手机上「视频抓取」里显示的那个完整地址打开，形如
        <code>http://192.168.x.x:18080/口令/</code>。</p>
        </body>
        """)
    }

    /// 目录列表页 —— 电脑浏览器打开后直接点文件名就能下载 / 在线播放
    private func sendDirectoryList(_ fd: Int32, dir: URL, relPath: String, isLocal: Bool) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        // 局域网访客点出来的链接也得带口令，不然点进去会被拒
        let prefix = (lanEnabled && !isLocal && !token.isEmpty) ? "/\(token)" : ""
        let base = relPath.isEmpty ? "" : relPath + "/"

        var rows = ""
        for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let full = dir.appendingPathComponent(n)
            var d: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &d) else { continue }
            let enc = n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? n
            rows += "<li><a href=\"\(prefix)/\(base)\(enc)\">"
            rows += d.boolValue ? "📁 \(Self.esc(n))/</a>" : "🎬 \(Self.esc(n))</a>"
            if !d.boolValue { rows += "<span class=size>\(Self.sizeText(full))</span>" }
            rows += "</li>\n"
        }
        if rows.isEmpty { rows = "<li class=size>（这个目录里还没有文件）</li>\n" }

        var html = """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>视频抓取 · 文件</title>
        <style>
        body{font:15px -apple-system,system-ui,"PingFang SC",sans-serif;margin:26px;max-width:840px;color:#111}
        h2{font-size:17px;margin:0 0 14px} ul{list-style:none;padding:0;margin:0}
        li{margin:12px 0;line-height:1.4}
        a{color:#0a66ff;text-decoration:none;word-break:break-all}
        a:hover{text-decoration:underline}
        .size{color:#888;font-size:13px;margin-left:10px}
        .back{display:inline-block;margin-bottom:16px;font-size:14px}
        .hint{margin-top:30px;color:#888;font-size:13px;line-height:1.6}
        </style>
        <h2>📂 \(relPath.isEmpty ? "根目录" : Self.esc(relPath))</h2>
        """
        if !relPath.isEmpty {
            let parent = (relPath as NSString).deletingLastPathComponent
            html += "<a class=back href=\"\(prefix)/\(parent.isEmpty ? "" : parent + "/")\">← 返回上一层</a>\n"
        }
        html += "<ul>\n\(rows)</ul>\n"
        html += "<p class=hint>手机上的「视频抓取」正在共享这个目录。点文件名即可下载，"
        html += "mp4 一般能直接在线播放。<br>要关掉共享，回到手机 App 点「关闭共享」。</p>\n"
        sendHTML(fd, status: 200, reason: "OK", html: html)
    }

    private static func sizeText(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let n = (attrs?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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


// MARK: - WebDAV（把手机挂成电脑上的一个盘）
//
// 电脑上「映射网络驱动器 / RaiDrive / Cyberduck / Finder」连上来之后，手机就像一个
// U 盘：能拖文件进出、改名、删掉、用电脑的播放器直接播。走的是 WebDAV 标准协议。
//
// 认证：HTTP Basic —— 用户名随便填，密码填界面上那串口令。
//   客户端第一次通常不带凭据探一下，我们回 401 + WWW-Authenticate，它收到就知道该带凭据了。
//
// 边界（写在明处，别让人误以为这是个正经服务器）：
//   · 只在同一 Wi-Fi 下可用；口令是**门牌不是加密** —— 别在公共 Wi-Fi 开着共享
//   · LOCK 是「名义上的」：发个 token 就算锁上了，不做真互斥。
//     单人自用（自己电脑连自己手机）没问题；但别两个客户端同时改同一个文件
//   · 上传单个文件限 500MB，防止一下把手机塞满

extension LocalHTTPServer {

    /// WebDAV 的方法都从这里走。GET / HEAD 不走这里（它们有自己那条老路）。
    fileprivate func handleWebDAV(_ fd: Int32, method: String, target: URL,
                                  rawPath: String, root: URL,
                                  lines: [String], extraBody: Data) {
        switch method {
        case "OPTIONS":  davOptions(fd)
        case "PROPFIND": davPropfind(fd, target: target, rawPath: rawPath,
                                     depth: Self.headerValue(lines, "depth") ?? "1")
        case "PUT":      davPut(fd, target: target, lines: lines, extraBody: extraBody)
        case "DELETE":   davDelete(fd, target: target, root: root)
        case "MKCOL":    davMkcol(fd, target: target)
        case "MOVE":     davMoveOrCopy(fd, from: target, root: root, lines: lines, move: true)
        case "COPY":     davMoveOrCopy(fd, from: target, root: root, lines: lines, move: false)
        case "LOCK":     davLock(fd)
        case "UNLOCK":   sendSimple(fd, status: 204, reason: "No Content")
        default:         sendSimple(fd, status: 405, reason: "Method Not Allowed")
        }
    }

    // MARK: 小工具

    private static func headerValue(_ lines: [String], _ name: String) -> String? {
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            if l[..<c].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Basic 认证里的密码（用户名不校验 —— 就一个口令，没必要再要个名字）
    private static func basicAuthPassword(_ lines: [String]) -> String? {
        guard let v = headerValue(lines, "authorization") else { return nil }
        guard v.lowercased().hasPrefix("basic ") else { return nil }
        let b64 = String(v.dropFirst("basic ".count)).trimmingCharacters(in: .whitespaces)
        guard let d = Data(base64Encoded: b64),
              let s = String(data: d, encoding: .utf8),
              let i = s.firstIndex(of: ":") else { return nil }
        return String(s[s.index(after: i)...])
    }

    private static func xmlEsc(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    /// 逐段做 URL 编码（保留 /）。中文名、空格、圆括号都得编码，客户端才认。
    private static func hrefEncode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
    /// ★ DateFormatter 不是线程安全的，而连接是并发处理的（queue 带 .concurrent）
    ///   → 并发调 string(from:) 可能崩或算出错的日期。加一把锁，代价可忽略。
    private static let httpDateLock = NSLock()

    private static func httpDate(_ d: Date) -> String {
        httpDateLock.lock()
        defer { httpDateLock.unlock() }
        return httpDateFormatter.string(from: d)
    }

    // MARK: 各方法

    /// 401 + WWW-Authenticate：WebDAV 客户端看到这个才会弹认证框 / 带凭据重试。
    /// （浏览器那条路不返回它 —— 那边给一张人话说明页更合适。）
    fileprivate func sendAuthChallenge(_ fd: Int32) {
        var h = "HTTP/1.1 401 Unauthorized\r\n"
        h += "WWW-Authenticate: Basic realm=\"VideoGrab\"\r\n"
        h += "Content-Length: 0\r\n"
        h += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(h.utf8))
    }

    private func davOptions(_ fd: Int32) {
        var h = "HTTP/1.1 200 OK\r\n"
        h += "DAV: 1, 2\r\n"
        h += "Allow: OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK\r\n"
        h += "MS-Author-Via: DAV\r\n"        // Windows 资源管理器认这个头才会继续往下走
        h += "Content-Length: 0\r\n"
        h += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(h.utf8))
    }

    /// 列目录（就是 WebDAV 版的「目录列表页」）。
    /// Depth: 0 只列自己；1 再带上直接子项；infinity 按 1 处理（安全）。
    private func davPropfind(_ fd: Int32, target: URL, rawPath: String, depth: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">"
        xml += Self.davResponse(url: target, href: rawPath)

        if depth.lowercased() != "0", isDir.boolValue {
            let base = rawPath.hasSuffix("/") ? rawPath : rawPath + "/"
            let kids = (try? fm.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                xml += Self.davResponse(url: k, href: base + k.lastPathComponent)
            }
        }
        xml += "</D:multistatus>"

        var h = "HTTP/1.1 207 Multi-Status\r\n"
        h += "Content-Type: application/xml; charset=utf-8\r\n"
        h += "Content-Length: \(xml.utf8.count)\r\n"
        h += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(h.utf8) + Data(xml.utf8))
    }

    private static func davResponse(url: URL, href: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()

        var s = "<D:response><D:href>\(xmlEsc(hrefEncode(href)))</D:href>"
        s += "<D:propstat><D:prop>"
        s += "<D:displayname>\(xmlEsc(url.lastPathComponent))</D:displayname>"
        if isDir {
            s += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            s += "<D:resourcetype/>"
            s += "<D:getcontentlength>\(size)</D:getcontentlength>"
            s += "<D:getcontenttype>\(mimeType(for: url.pathExtension))</D:getcontenttype>"
        }
        s += "<D:getlastmodified>\(httpDate(mtime))</D:getlastmodified>"
        s += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        return s
    }

    /// 上传：边收边写，先写 .part 再改名 ——
    /// 中途断线只会留个 .part，不会留下一个「看起来完整」的半截视频。
    private func davPut(_ fd: Int32, target: URL, lines: [String], extraBody: Data) {
        guard let clStr = Self.headerValue(lines, "content-length"), let cl = Int(clStr) else {
            sendSimple(fd, status: 411, reason: "Length Required")
            return
        }
        guard cl <= 500 * 1024 * 1024 else {
            sendSimple(fd, status: 413, reason: "Payload Too Large")
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            sendSimple(fd, status: 409, reason: "Conflict")
            return
        }

        let part = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: part) else {
            sendSimple(fd, status: 500, reason: "Cannot Write")
            return
        }

        var written = 0
        if !extraBody.isEmpty {                      // 跟着请求头一起到达的那截
            let n = min(extraBody.count, cl)
            if (try? fh.write(contentsOf: extraBody.prefix(n))) != nil { written += n }
        }
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while written < cl {
            let want = min(chunk.count, cl - written)
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let b = raw.baseAddress else { return -1 }
                return recv(fd, b, want, 0)
            }
            if n <= 0 { break }
            if (try? fh.write(contentsOf: Data(chunk[0..<n]))) == nil { break }
            written += n
        }
        try? fh.close()

        guard written == cl else {
            try? FileManager.default.removeItem(at: part)
            sendSimple(fd, status: 500, reason: "Incomplete Upload")
            return
        }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: part, to: target)
            sendSimple(fd, status: 201, reason: "Created")
        } catch {
            try? FileManager.default.removeItem(at: part)
            sendSimple(fd, status: 500, reason: "Cannot Save")
        }
    }

    private func davDelete(_ fd: Int32, target: URL, root: URL) {
        // 根目录不给删（客户端手滑一下，整个下载库没了）
        if target.standardizedFileURL.path == root.standardizedFileURL.path {
            sendSimple(fd, status: 403, reason: "Forbidden")
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            sendSimple(fd, status: 204, reason: "No Content")
        } catch {
            sendSimple(fd, status: 500, reason: "Delete Failed")
        }
    }

    private func davMkcol(_ fd: Int32, target: URL) {
        if FileManager.default.fileExists(atPath: target.path) {
            sendSimple(fd, status: 405, reason: "Already Exists")
            return
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            sendSimple(fd, status: 201, reason: "Created")
        } catch {
            sendSimple(fd, status: 409, reason: "Cannot Create")
        }
    }

    private func davMoveOrCopy(_ fd: Int32, from: URL, root: URL,
                               lines: [String], move: Bool) {
        guard let dest = Self.headerValue(lines, "destination"),
              let to = Self.destinationURL(dest, root: root,
                                           token: lanEnabled ? token : nil) else {
            sendSimple(fd, status: 400, reason: "Bad Destination")
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        let overwrite = (Self.headerValue(lines, "overwrite") ?? "T").uppercased() != "F"
        let existed = fm.fileExists(atPath: to.path)
        if existed {
            guard overwrite else {
                sendSimple(fd, status: 412, reason: "Precondition Failed")
                return
            }
            try? fm.removeItem(at: to)
        }
        do {
            if move { try fm.moveItem(at: from, to: to) }
            else { try fm.copyItem(at: from, to: to) }
            if existed { sendSimple(fd, status: 204, reason: "No Content") }
            else { sendSimple(fd, status: 201, reason: "Created") }
        } catch {
            sendSimple(fd, status: 500, reason: "Failed")
        }
    }

    /// Destination 头可能是完整 URL，也可能只是绝对路径；两种都剥掉口令段，
    /// 再拼到 root 上，最后做一次越界检查（跟 GET 那条路的防护一致）。
    private static func destinationURL(_ raw: String, root: URL, token: String?) -> URL? {
        var p = raw
        if let r = p.range(of: "://") {
            let after = p[r.upperBound...]
            if let slash = after.firstIndex(of: "/") { p = String(after[slash...]) }
            else { p = "/" }
        }
        p = p.removingPercentEncoding ?? p
        if p.hasPrefix("/") { p = String(p.dropFirst()) }
        if let t = token, !t.isEmpty {
            if p == t { p = "" }
            else if p.hasPrefix(t + "/") { p = String(p.dropFirst(t.count + 1)) }
        }
        let target = p.isEmpty
            ? root.standardizedFileURL
            : root.appendingPathComponent(p).standardizedFileURL
        var rootPath = root.standardizedFileURL.path
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else { return nil }
        return target
    }

    /// 锁：**名义上的**实现 —— 发个 token 就当锁上了，不做真互斥。
    /// 真互斥要维护锁表 + 超时，对「自己电脑连自己手机」是过度设计；
    /// 但不少客户端（Finder、RaiDrive）看不到锁就只肯给只读挂载，所以得有这一个。
    private func davLock(_ fd: Int32) {
        let token = "opaquelocktoken:" + UUID().uuidString
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
            + "<D:locktype><D:write/></D:locktype>"
            + "<D:lockscope><D:exclusive/></D:lockscope>"
            + "<D:depth>infinity</D:depth>"
            + "<D:timeout>Second-3600</D:timeout>"
            + "<D:locktoken><D:href>\(token)</D:href></D:locktoken>"
            + "</D:activelock></D:lockdiscovery></D:prop>"
        var h = "HTTP/1.1 200 OK\r\n"
        h += "Lock-Token: <\(token)>\r\n"
        h += "Content-Type: application/xml; charset=utf-8\r\n"
        h += "Content-Length: \(xml.utf8.count)\r\n"
        h += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(h.utf8) + Data(xml.utf8))
    }
}
