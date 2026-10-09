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

    /// ★ v1.0.258：**WebDAV（共享给电脑）删/移走文件后的通知**。
    ///   背景：电脑端通过共享把文件「剪切（MOVE）/重命名/删除」时，手机上的文件是真的会
    ///   消失/改位置，而任务记录毫不知情 —— 用户只在**重启 App 后**看到一句
    ///   "文件已不在（可能被系统清理或删掉）"，完全不知道是电脑端的操作干的。
    ///   有了这个回调，主界面能给对应任务记一笔（"该文件已通过「共享给电脑」…"），
    ///   把隐形操作变可见。**由 WebDAV 请求线程调用**，实现方自己切主线程。
    ///   （只发通知、**不改任务状态**：文件可能只是被移个位置又移回来，状态由重启时的
    ///   文件检查说了算 —— 见 DP 审查的建议。）
    static var onExternalFileChange: ((_ name: String, _ action: String) -> Void)?

    /// 干活用的并发队列：接受连接和读请求都丢这里
    private let queue = DispatchQueue(label: "vg.localhttp", attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var running = false
    /// ★ v1.0.203：监听代次号（重绑端口/重开共享时 +1，旧 accept 循环据此退出）
    private var listenGen = 0
    /// ★ v1.0.229：起/停服务要**串行**。
    ///   为什么：`start()` 里是「先关旧监听、再绑新端口」——两台线程同时进来时，
    ///   先跑到 `tryListen` 的那次会拿到端口 P1 并把它交给播放器，紧接着另一次又把监听
    ///   挪到 P2 → 播放器拿着 P1 去连，得到的就是 **-1004「连不上」**。
    ///   本机服务同时被播放、下载、共享三条路调用，这个竞态是真实存在的。
    ///   用递归锁：`start()` 内部还会调 `closeListener()`（同一把锁再进一层）。
    private let lock = NSRecursiveLock()

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
        lock.lock()
        defer { lock.unlock() }
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

    /// ★★ v1.0.229：**自检 + 自愈** —— 回环连一下自己，连不上就把监听重开。
    ///
    /// 为什么非要有它（用户实测「点『窗口』报播放器起不来」，截图是
    /// `http://127.0.0.1:<端口>/__vgproxy/… → -1004 无法连接服务器`）：
    /// `start()` 是"已经在跑就直接返回那个端口"的幂等实现 —— 万一接受循环已经废了
    /// （资源耗尽那类），它会**一直返回一个没人接的端口**，于是所有走本机代理的播放
    /// 永远是"连不上"，而且**永远不会自己好**，只能重启 App。
    /// 现在每次要用之前先探一下（一次回环 connect，几十微秒），坏了就重开。
    @discardableResult
    func ensureAlive() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        if running, port > 0, listenFD >= 0, canReachSelf() { return port }
        closeListener()
        return start(root: root ?? JobStore.dir)
    }

    /// 往自己的监听端口连一下（只为确认"有人在接"）。连上就立刻断开，不发请求。
    private func canReachSelf() -> Bool {
        guard port > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // 200ms 够本机回环用了；真卡住也不能把调用方（播放链路）拖住
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { return false }
        let r: Int32 = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

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

        if token.isEmpty {
            // ★ v1.0.102：开了「记住口令」就沿用上次那串（找不到才新生成并记住）
            if fixedTokenOn,
               let saved = UserDefaults.standard.string(forKey: Self.tokenKey), !saved.isEmpty {
                token = saved
            } else {
                token = Self.makeToken()
                if fixedTokenOn { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
            }
        }
        lanEnabled = true
        closeListener()                 // 换绑地址（127.0.0.1 → 0.0.0.0）必须重新监听
        let reached = start(root: root)
        if reached == nil { lanEnabled = false; token = "" }
        return reached != nil
    }

    /// 关掉共享，退回「只服务本机」。
    /// 口令照旧清掉（下次开又是新的）—— **除非用户开了「记住口令」**，
    /// 那种情况清了下次地址就变了，等于白记。
    func disableLAN() {
        guard lanEnabled else { return }
        lanEnabled = false
        if !fixedTokenOn { token = "" }
        let keep = root
        closeListener()
        if let keep { _ = start(root: keep) }
    }

    // MARK: - 固定口令（v1.0.102）
    //
    // 用户的诉求（原话）：**电脑上存一个书签，手机开了共享直接点开就能用，不用每次复制。**
    // 原来每次开共享都换一串新口令 → 地址每次都变 → 只能每次重新复制。
    // 现在：开关打开就把口令记下来（存 UserDefaults），重开 App / 重启手机都不变；
    // 关掉开关就恢复"每次换新的"。
    // 代价（必须让用户知道）：固定之后，同一个 Wi-Fi 下**曾经拿到过这个地址的人**
    // 以后也能一直进 —— 所以默认不开，用户自己决定。

    private static let rememberKey = "vg.fixedTokenOn"
    private static let tokenKey = "vg.fixedToken"

    /// 用户开了「记住口令」没有（设置页的 @AppStorage 绑的是同一个 key）
    var fixedTokenOn: Bool { UserDefaults.standard.bool(forKey: Self.rememberKey) }

    /// 把当前这串固定下来（用户刚打开开关）
    func fixCurrentToken() {
        if token.isEmpty { token = Self.makeToken() }
        UserDefaults.standard.set(true, forKey: Self.rememberKey)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    /// 忘掉固定口令（关掉开关）→ 下次开共享又是新口令
    func forgetFixedToken() {
        UserDefaults.standard.set(false, forKey: Self.rememberKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        if !lanEnabled { token = "" }
    }

    /// 换一个口令（用户在设置里点）。共享开着也**立刻生效** —— 口令是每个请求现校验的。
    @discardableResult
    func regenerateToken() -> String {
        let t = Self.makeToken()
        token = t
        if fixedTokenOn { UserDefaults.standard.set(t, forKey: Self.tokenKey) }
        return t
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
        lock.lock()
        defer { lock.unlock() }
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
        // ★ v1.0.203：每次重新监听**代次 +1** —— 旧的 accept 循环看到代次变了就退出。
        //   以前只靠 `running` 这个布尔：关掉再打开（running 又变 true）时，
        //   旧循环会对着**已经关闭的 fd** 每 50ms 空转一次、永不退出（僵尸循环 + fd 泄漏）。
        listenGen &+= 1
        let myGen = listenGen
        queue.async { [weak self] in self?.acceptLoop(fd, gen: myGen) }
        return assigned
    }

    /// 拿到某个相对路径的访问地址
    func url(_ relativePath: String) -> URL? {
        guard port > 0 else { return nil }
        let clean = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        return URL(string: "http://127.0.0.1:\(port)/\(clean)")
    }

    // MARK: - accept

    private func acceptLoop(_ fd: Int32, gen myGen: Int) {
        while running, myGen == listenGen {
            var cli = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd: Int32 = withUnsafeMutablePointer(to: &cli) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &len)
                }
            }
            if cfd < 0 {
                if errno == EINTR { continue }
                if !running || myGen != listenGen { break }   // ★ 代次变了＝这个循环已经过期
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

        // ★★ v1.0.166：**播放代理** —— 把上游请求搬到本机来走一趟（防盗链的站也能播；
        //   为什么非这样不可，根因见 `MediaProxy` 开头）。
        //   放在**口令校验之后**：局域网访客不许拿它当开放代理用。
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        if let reply = MediaProxy.handle(rawTarget: String(parts[1]),
                                         rangeHeader: rangeHeader) {
            sendProxy(fd, reply, isHead: isHead)
            return
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

        // ★ v1.0.169 缩略图：磁盘上是 `thumb_<uuid>.jpg`（就躺在共享目录里），
        //   但页面通过 `__thumb/` 这个虚拟路径取 —— 这样目录列表里不会混进一堆缩略图，
        //   也能给它一个明确的 image/jpeg（普通文件走的是 octet-stream，<img> 可能不认）。
        //   只认「thumb_ 开头 + .jpg 结尾 + 不含 /」这一个形状：挡掉目录穿越和任意文件读取。
        if path.hasPrefix("__thumb/") {
            let name = String(path.dropFirst("__thumb/".count))
            if name.hasPrefix("thumb_"), name.hasSuffix(".jpg"), !name.contains("/") {
                if let data = try? Data(contentsOf: JobStore.file(named: name)) {
                    sendBody(fd, status: 200, reason: "OK", contentType: "image/jpeg",
                             body: data, isHead: isHead)
                    return
                }
            }
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }

        // ★ v1.0.127 边下边播：这条清单是**现场生成**的 —— 每下完一个分片它就变长。
        //   所以不能当普通文件发（那只会发出第一次写下的内容，播放器播完就停）。
        //   路径形如 `__live/<任务id>.m3u8`；磁盘上并没有这个目录。
        if let body = LivePreview.playlistBody(forPath: path, root: root) {
            sendBody(fd, status: 200, reason: "OK",
                     contentType: "application/vnd.apple.mpegurl",
                     body: Data(body.utf8), isHead: isHead)
            return
        }

        // ★★ v1.0.250 磁力「边下边播」：把正在下载的 torrent 文件当 HTTP 流喂给播放器。
        //   路径形如 `__torrent/<任务号>/<文件下标>.<扩展名>`；磁盘上没有这个路径，
        //   数据来自"边等边读"（见 serveTorrentStream）。
        if path.hasPrefix("__torrent/") {
            serveTorrentStream(fd, path: path, lines: lines, isHead: isHead, isLocal: isLocal)
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

        // ★ v1.0.199：**不是白名单里的内容一律 403** —— 这条挡住的就是
        //   `records.json` 这类"内部文件被直接按路径下载"（光靠列表里不显示是不够的）。
        guard Self.isServable(target.lastPathComponent) else {
            sendSimple(fd, status: 403, reason: "Forbidden")
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
        //
        // ★★ v1.0.140：**解析必须严格**（2026-09-28 外部审查指出，我逐行核实成立）。
        //   旧写法遇到不合法的 Range 不会拒绝，反而会**发错内容**：
        //     · `bytes=100-50`（起止写反）→ `end` 保持初值 `total-1` → 发「从 100 到文件末尾」；
        //     · `bytes=0-1, 3-4`（多范围）→ 中间那截 `Int("1, 3")` 失败 → 同样发「整份」；
        //     · `bytes=-0` → 被当成"没有 Range"，回 200 整份。
        //   播放器拿到不该拿的数据，表现是"播到一半出问题"，极难查。
        //   按 RFC 7233：**不支持 / 不合法的 Range 一律回 416** ——
        //   宁可让它明确报错，也不要给它错的数据。
        var start = 0
        var end = total - 1
        var partial = false
        let rangeLines = lines.filter { $0.lowercased().hasPrefix("range:") }
        if rangeLines.count > 1 {                    // 多个 Range 头 = 多范围请求，不支持
            sendRangeNotSatisfiable(fd, total: total)
            return
        }
        if let l = rangeLines.first {
            let v = l.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard let r = v.range(of: "bytes=") else {
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let spec = v[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !spec.contains(",") else {          // 多范围（bytes=0-1,3-4）
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard comps.count == 2 else {
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let sStr = comps[0].trimmingCharacters(in: .whitespaces)
            let eStr = comps[1].trimmingCharacters(in: .whitespaces)
            if sStr.isEmpty {
                // `bytes=-N`：末尾 N 字节。N 必须 >0（`-0` 是不满足的请求）
                guard let n = Int(eStr), n > 0 else {
                    sendRangeNotSatisfiable(fd, total: total); return
                }
                start = max(0, total - n)
                end = total - 1
            } else {
                guard let s = Int(sStr), s >= 0, s < total else {
                    sendRangeNotSatisfiable(fd, total: total); return
                }
                start = s
                if eStr.isEmpty {
                    end = total - 1                     // `bytes=N-`
                } else {
                    guard let e = Int(eStr), e >= s else {   // 起止写反 = 不合法
                        sendRangeNotSatisfiable(fd, total: total); return
                    }
                    end = min(e, total - 1)             // 超过末尾按 RFC 夹到末尾
                }
            }
            partial = true
        }
        if start >= total || start > end {
            sendRangeNotSatisfiable(fd, total: total)     // 兜底：上面已经严格拦过一遍
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

    /// ★★ v1.0.250：磁力「边下边播」的 HTTP 流 —— 把正在下载的 torrent 文件喂给播放器。
    ///
    /// 路径：`__torrent/<任务号>/<文件下标>.<扩展名>`（任务号 / 下标对不上 = 404，
    /// 换任务后旧链接自然失效）。请求到的位置还没下完时：**先催 libtorrent 优先下这段**，
    /// 边等边查；等到多少发多少（206 的 Content-Range 按实际发，播放器会接着要下一段）。
    private func serveTorrentStream(_ fd: Int32, path: String, lines: [String],
                                    isHead: Bool, isLocal: Bool) {
        // 只服务本机播放器（回环）；局域网访客不给看"正在下载"的内容
        guard isLocal else {
            sendForbiddenPage(fd)
            return
        }
        let rest = String(path.dropFirst("__torrent/".count))
        let segs = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard segs.count == 2, let tid = Int32(String(segs[0])) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        let filePart = String(segs[1])
        let idxStr = filePart.split(separator: ".").first.map(String.init) ?? ""
        guard let fIndex = Int(idxStr),
              let ctx = MagnetEngine.torrentStreamContext(tid: tid, fileIndex: fIndex) else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }
        let total = Int(ctx.size)
        guard total > 0 else {
            sendSimple(fd, status: 404, reason: "Not Found")
            return
        }

        // Range 解析（和本地文件那套同一张 RFC 7233 的严格表；流只支持单范围 ——
        // 播放器本来就是单范围发的）
        var start = 0
        var end = total - 1
        var partial = false
        if let l = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let v = l.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard let r = v.range(of: "bytes=") else {
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let spec = v[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !spec.contains(",") else {
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
            guard comps.count == 2 else {
                sendRangeNotSatisfiable(fd, total: total); return
            }
            let sStr = comps[0].trimmingCharacters(in: .whitespaces)
            let eStr = comps[1].trimmingCharacters(in: .whitespaces)
            if sStr.isEmpty {
                guard let n = Int(eStr), n > 0 else {
                    sendRangeNotSatisfiable(fd, total: total); return
                }
                start = max(0, total - n)
                end = total - 1
            } else {
                guard let s = Int(sStr), s >= 0, s < total else {
                    sendRangeNotSatisfiable(fd, total: total); return
                }
                start = s
                if eStr.isEmpty {
                    end = total - 1
                } else {
                    guard let e = Int(eStr), e >= s else {
                        sendRangeNotSatisfiable(fd, total: total); return
                    }
                    end = min(e, total - 1)
                }
            }
            partial = true
        }
        if start >= total || start > end {
            sendRangeNotSatisfiable(fd, total: total)
            return
        }

        // ── 等这段数据（边下边播的核心）──
        let want = Int64(end - start + 1)
        guard let ready = waitForTorrentData(tid: tid, index: fIndex,
                                             off: Int64(start), want: want) else {
            sendSimple(fd, status: 503, reason: "Service Unavailable")   // 暂无数据，播放器会重试
            return
        }
        let length = Int(ready)

        let full = (start == 0 && length == total)
        var header = full ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        header += "Content-Type: \(Self.mimeType(for: (ctx.path as NSString).pathExtension))\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        if !full { header += "Content-Range: bytes \(start)-\(start + length - 1)/\(total)\r\n" }
        header += "Connection: close\r\n\r\n"
        guard writeAll(fd, Data(header.utf8)) else { return }
        if isHead { return }

        // 从磁盘把这段读出来发（和普通文件一样的 256KB 分段）
        guard let fh = try? FileHandle(forReadingFrom: ctx.url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(start))
        var remain = length
        while remain > 0 {
            let chunk = min(remain, 256 * 1024)
            guard let d = try? fh.read(upToCount: chunk), !d.isEmpty else { break }
            guard writeAll(fd, d) else { break }
            remain -= d.count
        }
    }

    /// ★ v1.0.250：等到 [off, off+want) 里至少有一小段"连续可读"。
    ///   返回实际可读的字节数（> 0）；任务没了 / 超时且一字节都没有 → nil。
    ///   等待期间每 0.25 秒催一次 libtorrent（把这段标成"急着要"）。
    private func waitForTorrentData(tid: Int32, index: Int, off: Int64, want: Int64) -> Int64? {
        let t0 = Date()
        let floorBytes = min(want, Int64(1 << 20))       // 先凑到 1MB 再发，播放器缓冲更稳
        while true {
            _ = MagnetEngine.torrentPrefer(tid: tid, fileIndex: index, off: off, len: want)
            let have = MagnetEngine.torrentPrefix(tid: tid, fileIndex: index, off: off, want: want)
            if have < 0 { return nil }                   // 任务没了
            if have >= floorBytes { return have }
            let el = Date().timeIntervalSince(t0)
            if have > 0, el >= 6 { return have }         // 等到 6 秒：有多少先发多少
            if el >= 30 { return have > 0 ? have : nil } // 30 秒硬上限
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// 416：Range 不合法 / 我们不支持多范围。
    /// ★ 按 RFC 7233，416 要带 `Content-Range: bytes */总长` 告诉对方文件到底多长。
    private func sendRangeNotSatisfiable(_ fd: Int32, total: Int) {
        var head = "HTTP/1.1 416 Range Not Satisfiable\r\n"
        head += "Content-Range: bytes */\(total)\r\n"
        head += "Content-Length: 0\r\n"
        head += "Connection: close\r\n\r\n"
        _ = writeAll(fd, Data(head.utf8))
    }

    /// ★ v1.0.166：代理响应 —— 把我们替播放器取回来的东西发出去（含 206 / Content-Range）。
    private func sendProxy(_ fd: Int32, _ r: MediaProxy.Reply, isHead: Bool) {
        var head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        if r.acceptRanges { head += "Accept-Ranges: bytes\r\n" }
        if let cr = r.contentRange { head += "Content-Range: \(cr)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        guard writeAll(fd, Data(head.utf8)) else { return }
        if isHead || r.body.isEmpty { return }
        _ = writeAll(fd, r.body)
    }

    /// 给 `MediaProxy` 按后缀猜类型用（`mimeType(for:)` 是 private，开一个口子，**别抄第二份**）
    static func mimeForProxy(_ ext: String) -> String { mimeType(for: ext) }

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

    /// ★ v1.0.127：发一段带指定 Content-Type 的内容（边下边播的清单要它）
    private func sendBody(_ fd: Int32, status: Int, reason: String,
                          contentType: String, body: Data, isHead: Bool = false) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"      // 清单每次都要最新，绝不缓存
        head += "Connection: close\r\n\r\n"
        guard writeAll(fd, Data(head.utf8)) else { return }
        // ★ v1.0.130：播放器有时会先 HEAD 一下清单 —— HEAD 不能带 body，只回头部
        if !isHead { _ = writeAll(fd, body) }
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

    /// 目录列表页 —— 电脑浏览器打开后直接点就能播 / 下载。
    ///
    /// ★ v1.0.169：从「一行一个文件名」改成**卡片网格**（缩略图 + 时长 + 分辨率 + 时间，
    ///   加搜索 / 排序 / 类型筛选）。数据 = 「目录里有什么文件」+「`records.json` 里的对应记录」——
    ///   记录里存的时长 / 分辨率 / 下载时间 / 缩略图，这一页以前一个都没用上。
    ///   页面本体（HTML/CSS/JS）在 `LanPage`，这里只负责把每张卡的字段算出来。
    private func sendDirectoryList(_ fd: Int32, dir: URL, relPath: String, isLocal: Bool) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        // 局域网访客点出来的链接也得带口令，不然点进去会被拒
        let prefix = (lanEnabled && !isLocal && !token.isEmpty) ? "/\(token)" : ""
        let base = relPath.isEmpty ? "" : relPath + "/"

        // 文件名 → 记录：缩略图、时长、分辨率、片名都靠它。
        // ★ 只读 `JobStore` / `JobRecord`（非隔离）—— 这条线程不是主线程，不能碰 DownloadJob。
        var byFile: [String: JobRecord] = [:]
        for r in JobStore.load() {
            if let n = r.outputName, !n.isEmpty { byFile[n] = r }
        }

        var items: [LanPage.Item] = []
        for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let full = dir.appendingPathComponent(n)
            var d: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &d) else { continue }
            // App 自己产的"附件"不进这一页（缩略图 / 播放缓存清单 / 分片目录）——
            // 它们不是"内容"。以前只有缩略图被挡掉，于是那一页混进一堆几 KB 的
            // `.vgplay_*.m3u8`（播放中继写的临时清单）和空的 parts_ 目录，
            // 而且 m3u8 还被当成"视频"归类 → 视频分类里全是播不了的清单。
            // ★ v1.0.199：改成走**白名单**（`isServable`）—— 目录仍然列出（但不含 parts_ 这类），
            //   文件只有媒体/字幕才显示。records.json 这种内部文件就此从列表里消失。
            if d.boolValue {
                if Self.isInternalArtifact(n) { continue }
            } else if !Self.isServable(n) {
                continue
            }

            let enc = n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? n
            let url = "\(prefix)/\(base)\(enc)"

            if d.boolValue {
                items.append(LanPage.Item(name: n, url: url, kind: "dir",
                                          dur: 0, dim: "", bytes: 0, time: 0, thumb: ""))
                continue
            }

            let rec = byFile[n]
            let attrs = try? fm.attributesOfItem(atPath: full.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            // 优先用记录里"下完的时刻"，没有就退回文件的修改时间
            let stamp = rec?.finishedAt ?? rec?.createdAt
            // 缩略图只有真在磁盘上才给地址，不然 <img> 会去请求一个 404
            var thumb = ""
            if let r = rec {
                let t = JobStore.thumbName(for: r.id)
                if JobStore.exists(named: t) { thumb = "\(prefix)/__thumb/\(t)" }
            }
            let display = rec.flatMap { $0.title.isEmpty ? nil : $0.title } ?? n

            items.append(LanPage.Item(name: display, url: url,
                                      kind: Self.kindKey(rec: rec, file: n),
                                      dur: rec?.duration ?? 0,
                                      dim: rec?.resolution ?? "",
                                      bytes: size,
                                      time: stamp?.timeIntervalSince1970 ?? mtime,
                                      thumb: thumb))
        }

        let heading = relPath.isEmpty ? "我的下载" : (relPath as NSString).lastPathComponent
        let sub = relPath.isEmpty
            ? "手机上的「视频抓取」正在共享这个目录"
            : "共享目录 / \(relPath)"
        var back: String? = nil
        if !relPath.isEmpty {
            let parent = (relPath as NSString).deletingLastPathComponent
            back = "\(prefix)/\(parent.isEmpty ? "" : parent + "/")"
        }

        let html = LanPage.html(
            items: items, heading: heading, sub: sub, backURL: back,
            note: "这一页是手机上的「视频抓取」共享出来的。点缩略图在线播放（mp4 能直接播），"
                + "点卡片选中后可批量下载，缩略图右上角的 ↓ 下载单个。"
                + "App 内部的缩略图、播放缓存清单和临时分片目录不在这里显示"
                + "（用电脑挂 WebDAV 看得到）。要关掉共享，回手机 App 点「关闭共享」。")
        sendHTML(fd, status: 200, reason: "OK", html: html)
    }

    /// App 自己产的中间产物 —— 不该出现在「给电脑挑文件」这一页里。
    ///
    /// 清单（都是 `JobStore.dir` 里真实存在的文件/目录，`contentsOfDirectory` 会返回它们）：
    ///   · `.vgplay_*.m3u8` —— 播放中继写的临时清单（按远端地址算的稳定名，7 天过期）
    ///   · `thumb_*.jpg`    —— 每条的缩略图
    ///   · `parts_*` / `joined_*` —— 边下边播的分片目录、拼接临时目录
    /// 它们都能通往 WebDAV 看得到、管得着；只是不该在"挑片子"的卡片墙里碍眼。
    private static func isInternalArtifact(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if name.hasPrefix("thumb_") { return true }
        if name.hasPrefix("parts_") { return true }
        if name.hasPrefix("joined_") { return true }
        return false
    }

    // ══ ★★ v1.0.199（AI 审查 P0）：**共享只放行"内容"，不放开整个数据目录** ══
    //   以前 root 就是 App 的数据目录，服务只做了"防目录穿越"（路径必须落在 root 内）——
    //   root 里面**任何文件都能被拖走**，包括 `records.json`（里面有每个任务的
    //   sourceURL / Referer / **Cookie**）。同一 Wi-Fi 的人拿到地址就能把这些登录态拿走。
    //   现在按**扩展名白名单**放行（默认拒绝，更稳——将来新增的内部文件自动被挡住）。
    //   ★ 回环（手机自己播本地视频）走的是同一套判定，所以 m3u8 / ts 必须留着，
    //     否则会把自家的播放链路一起挡死。
    private static let servableExts: Set<String> = [
        // ★★ v1.0.200：这张表**必须以 `kindKey`（下面那张扩展名分类表）为准**，
        //   再加三样"播放必需、但不是内容"的：`part`（老任务遗留的分片，边下边播要靠它）、
        //   `m4s`（fMP4 分片）、`m3u8`（本地播放清单）。
        //   ★ 初版（v1.0.199）漏了 `part` 和 webm/mkv/avi/flv/3gp/heic/bmp/tiff/svg ——
        //     后果是**边下边播对升级前下好的任务直接 403**、这些格式的下载物在共享页里消失。
        //     AgentChat 四片体检时抓出来的（我自己的回归）。
        "mp4", "m4v", "mov", "ts", "part", "m4s", "m3u8", "webm", "mkv", "flv", "avi", "3gp",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "svg",
        "srt", "vtt", "ass", "ssa",
    ]

    /// 这个文件名能不能共享出去 —— **目录列表与单文件下载共用同一条判据**
    private static func isServable(_ name: String) -> Bool {
        if isInternalArtifact(name) { return false }
        return servableExts.contains((name as NSString).pathExtension.lowercased())
    }

    /// 卡片上的类型标签：优先信记录里建卡时定下的类别，没有就按扩展名猜。
    ///
    /// ★★ v1.0.170：**这张扩展名表必须和 `DownloadJob.kind(fromExtension:)` 逐字一致** ——
    ///   那一张才是"什么算视频/图片/音频"的**唯一定义**，这里只是它在后台线程的替身
    ///   （`DownloadJob` 是 `@MainActor`，本机 HTTP 服务用不了它）。
    ///   上一版漏了个 `3gp` → 那种视频被判成"文件"，在网页上看着就像"少了一个"。
    ///   自检里加了一条「两张表必须相同」的断言把这个形状钉住。
    /// ★ 另外：**`m3u8` 不算视频** —— 它是播放清单（几 KB），不是能直接播的片子。
    private static func kindKey(rec: JobRecord?, file: String) -> String {
        if let k = rec?.kind, ["video", "image", "audio", "doc"].contains(k) { return k }
        switch (file as NSString).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "ts", "webm", "mkv", "flv", "avi", "3gp":
            return "video"
        case "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "svg":
            return "image"
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus":
            return "audio"
        default:
            return "doc"
        }
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
        // ★ v1.0.130：边下边播的分片在磁盘上叫 `seg_xxxxxx.part`，
        //   它们其实就是 TS 分片 —— 不给对类型的话播放器拿到 octet-stream，会不肯播。
        case "part": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "mp4", "m4v": return "video/mp4"
        // ★ v1.0.169：图片也给对类型（缩略图走 __thumb 已经有 jpeg，这里管普通图片文件）
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
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
                // ★ v1.0.199：WebDAV 列表也过同一条白名单（否则换个协议照样能翻出 records.json）
                let kn = k.lastPathComponent
                let kIsDir = (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if kIsDir {
                    if Self.isInternalArtifact(kn) { continue }
                } else if !Self.isServable(kn) {
                    continue
                }
                xml += Self.davResponse(url: k, href: base + kn)
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
            Self.onExternalFileChange?(target.lastPathComponent, "删除")   // ★ v1.0.258
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
            // ★ v1.0.258：移走（MOVE）才算"源没了"；COPY 源还在、不通知。
            if move { Self.onExternalFileChange?(from.lastPathComponent, "移走") }
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
