import Foundation

/// ★★ v1.0.166：**播放代理** —— 让防盗链的站也能在 App 里播。
///
/// ══ 为什么必须有它（2026-09-29 真机定案，证据是一条任务记录）══
///   同一条地址、同一台机器、同样那几个头（Referer / UA / Cookie）：
///     · 我们自己用 `URLSession` 去取 → **全成**
///       （下载那条路：56 个分片 + AES 钥匙全拿到、还转成了 15.5 MB 的 MP4）
///     · `AVPlayer` 播 → **403**（`-1102` / `CoreMediaErrorDomain -12660`）
///   → 差别不在"头对不对"，在 **AVPlayer 这条管线带不上头**：
///     `AVURLAssetHTTPHeaderFieldsKey` 是个**未公开的私有键**，对 HLS 的
///     **内部请求（子清单 / 分片 / AES 钥匙）不可靠** ——
///     那句注释自己都写着"AVPlayer 没有公开办法给请求带头"。
///
/// ══ 做法：把上游请求搬到本机服务上走一趟 ══
///   播放器改成请求 **本机服务**：
///     `http://127.0.0.1:<端口>/__vgproxy/<key>/<名字>?u=<上游地址>`
///   本机服务代我们**带上头**去取上游，把结果原样发回去（含 206 / Range）。
///   如果取回来的是一份**清单**，就顺手把里面每一行 URI（以及 `URI="…"` 属性）也换成代理地址 ——
///   于是**清单、子清单、分片、钥匙全都从我们这条路走，每一跳都带头**。
///   （顺带把 PlaylistRelay 那个"master 清单不管"的空白也补上了：master 里的变体行同样会被改写。）
///
/// ══ 四条硬规矩 ══
///   · **Cookie 绝不写进 URL**：URL 里只放一个 key，凭据只存在内存表里（`register`）。
///   · **每条请求都重新去上游取**，不缓存清单 —— AVPlayer 播放中会重新请求清单，
///     给它旧的会把本来能播的搞坏（`PlaylistRelay` 踩过这个坑）。
///   · **失败要有话**：上游非 2xx 时把状态码和人话带回去，别让界面只剩"加载不出来"。
///   · ★★ **不许把 `var` 捕获进并发闭包**（run #138、**#164** 都栽在这）——
///     结果用 `Box` 这个类来接。
enum MediaProxy {

    /// URL 里的路由前缀（本机服务按它分流；放在口令校验之后，局域网访客不能拿它当开放代理）
    static let prefix = "__vgproxy/"

    /// 本机服务回给播放器的一坨东西
    struct Reply {
        var status: Int
        var reason: String
        var contentType: String
        var body: Data
        var contentRange: String?
        var acceptRanges: Bool
    }

    // MARK: - 上游请求头（只在内存里，按 key 存）

    private static var table: [String: [String: String]] = [:]
    /// ★ v1.0.168：`key → 父清单地址`。分片/钥匙那一跳靠它回头找到"我是从哪份清单来的"。
    private static var playlists: [String: String] = [:]
    /// ★ v1.0.168：`key|路径 → (刚刷新出来的新地址, 记下的时刻)`。
    /// 为什么要它：一个分片 403 触发刷新后，**同一批其他分片直接从这儿拿新地址** ——
    /// 否则 149 个分片就是 149 次重取清单，既慢又容易被打。
    private static var refreshed: [String: (url: URL, at: Date)] = [:]
    private static let lock = NSLock()

    /// 登记一套头、返回它的 key（同一套头共用一个 key，表不会长大）。
    /// ★ 用自己算的稳定哈希 —— **不用 `Hasher`**（它每次进程启动都换种子）。
    static func register(_ headers: [String: String]?, playlist: String? = nil) -> String {
        let h = (headers ?? [:]).filter { !$0.value.isEmpty }
        var raw = h.sorted { $0.key < $1.key }
            .map { $0.key + "=" + $0.value }
            .joined(separator: "\u{1}")
        // ★ v1.0.168：把「父清单地址」也算进 key —— 同一个视频的清单/钥匙/分片共用这个 key，
        //   于是分片那一跳能凭它回头找到"我是从哪份清单来的"，才有得刷新。
        if let playlist, !playlist.isEmpty { raw += "\u{2}" + playlist }
        var x: UInt64 = 5381
        for b in raw.utf8 { x = (x &* 33) ^ UInt64(b) }
        let k = String(x, radix: 36)
        lock.lock()
        table[k] = h
        playlists[k] = playlist
        lock.unlock()
        return k
    }

    private static func headers(_ key: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return table[key]
    }

    private static func playlist(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return playlists[key]
    }

    /// 查"刚刷新出来的新地址"（同 key + 同路径）。超过 5 分钟的不算数。
    private static func freshAddress(key: String, path: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = refreshed[key + "|" + path],
              Date().timeIntervalSince(hit.at) < 300 else { return nil }
        return hit.url
    }

    /// 记下刷新结果，并顺手清掉过期的（表不会无限长）
    private static func rememberFresh(key: String, path: String, url: URL) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        refreshed = refreshed.filter { now.timeIntervalSince($0.value.at) < 300 }
        refreshed[key + "|" + path] = (url, now)
    }

    // MARK: - 入口：把上游地址变成"本机代理地址"

    /// 失败（地址非法 / 服务起不来）→ 返回 nil，调用方**退回原地址照旧播**（绝不比现在更差）。
    static func wrap(_ upstream: String, headers hs: [String: String]?) -> URL? {
        let cleaned = M3U8Playlist.sanitizeURLString(upstream)
        guard let u = URL(string: cleaned),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        // 本机服务要先起来（root 用下载目录 —— 跟边下边播 / 清单本地化同一个根）
        // ★ v1.0.229：改用 `ensureAlive()` —— 它多做一步"回环自检"，
        //   发现服务其实没人接就重开。原来只 `start()`，一旦接受循环废了就永远坏着
        //   （用户实测"点窗口报播放器起不来 / -1004 无法连接服务器"，多站点复现）。
        guard LocalHTTPServer.shared.ensureAlive() != nil else { return nil }
        // ★ v1.0.168：把清单地址一并登记（分片那一跳要靠它刷新）
        return URL(string: proxyString(for: u, key: register(hs, playlist: cleaned)) ?? "")
    }

    /// ★★ v1.0.167：**播放 / 重下之前先体检一次** —— 这条地址还活着吗？
    ///
    /// 为什么非要它：这类站的直链**带时效**（实测同一条地址，下载时好的，不到半小时
    /// 就被网关 403 了）。地址一死，AVPlayer 只会吐一串天书：
    ///   `NSURLErrorDomain -1102`（"没有访问许可"）+ `CoreMediaErrorDomain -12660`
    /// —— 翻译过来就是 **HTTP 403 Forbidden**（Apple 的 CoreMedia 错误对照表里
    /// `-12660` 写死就是 403；实测第三方播放器报的也是同一条）。用户看不懂，
    /// 只会以为"程序坏了"。
    ///
    /// 所以：**自己能判断的事别推给播放器**。返回 nil = 地址能用；
    /// 返回一句中文 = 直接把这句话显示给用户，**不要再建播放器 / 不要再建下载任务**。
    static func probe(_ upstream: String, headers hs: [String: String]?) async -> String? {
        let cleaned = M3U8Playlist.sanitizeURLString(upstream)
        guard let u = URL(string: cleaned),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return "这条地址不完整，读不出来" }

        // ★ 探两次：先带 Range 只要 1KB（快、省流量）；万一是那种**不喜欢 Range 的服务器**，
        //   把 Range 去掉再探一次 —— 绝不因为"服务器挑剔"就把好地址判成坏地址
        //   （那是最糟的失败模式：明明能播，程序说不能播）。
        //   第二次只在第一次没通过时才发，正常情况零开销。
        let withRange = await ask(u, headers: hs, range: "bytes=0-1023")
        if withRange == nil { return nil }
        let plain = await ask(u, headers: hs, range: nil)
        if plain == nil { return nil }
        return withRange
    }

    /// 探一次。返回 nil = 这个地址能用；否则返回一句中文（**直接拿给用户看**）。
    ///
    /// ★ 不用 `HEAD`：有的站对 HEAD 直接回 501，那会把好地址误判成坏地址。
    private static func ask(_ u: URL, headers hs: [String: String]?, range: String?) async -> String? {
        var req = URLRequest(url: u, timeoutInterval: 15)
        for (k, v) in (hs ?? [:]) where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "这个地址没有正常回应" }
            switch http.statusCode {
            case 200...299:
                return nil
            case 401, 403:
                return "服务器不让取（HTTP \(http.statusCode)）—— 站点多半下架了，或者这条链接过期了"
            case 404, 410:
                return "站点上已经没有这个视频了（HTTP \(http.statusCode)）"
            default:
                return "服务器返回 HTTP \(http.statusCode)，现在取不到"
            }
        } catch {
            return "取不到这个地址：" + error.localizedDescription
        }
    }

    /// 上游地址 → 本机代理地址（`wrap` 与清单改写**共用这一份**，不要写第二份）
    private static func proxyString(for up: URL, key: String) -> String? {
        guard let base = LocalHTTPServer.shared.url(prefix + key + "/" + urlName(up)) else { return nil }
        // ★ `u=` 的值整串百分号编码（连 `:/?&` 都编掉）—— 上游地址里本来就可能带 `?`/`&`，
        //   不编干净的话它会被当成我们自己的查询参数切开。
        guard let enc = up.absoluteString.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
        else { return nil }
        return base.absoluteString + "?u=" + enc
    }

    /// 末段名字——**只为了"让播放器认得出类型"**，服务端不看它（只看 `u=` 和 key）。
    private static func urlName(_ up: URL) -> String {
        let last = up.lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        let known: Set<String> = ["m3u8", "ts", "m4s", "mp4", "m4v", "mov",
                                  "key", "bin", "mp2t", "part", "aac", "mp3"]
        if !ext.isEmpty, known.contains(ext) {
            // 名字里可能有中文 → 编码后再拼
            return last.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ("media." + ext)
        }
        // 认不出后缀的一律当清单（这类站给播放器的入口基本就是 .m3u8）
        return "media.m3u8"
    }

    // MARK: - 本机服务收到 __vgproxy 请求时调它

    /// - Parameters:
    ///   - rawTarget: 请求行里那个**原始** target（含 query、**没解码**）
    ///   - rangeHeader: 播放器带的 `Range`，原样转给上游
    /// 返回 nil = 这不是一条代理请求（调用方照旧走文件那条路）。
    static func handle(rawTarget: String, rangeHeader: String?) -> Reply? {
        guard let qi = rawTarget.firstIndex(of: "?") else { return nil }
        let rawPath = String(rawTarget[..<qi])
        guard let pr = rawPath.range(of: prefix) else { return nil }
        let key = String(rawPath[pr.upperBound...].prefix { $0 != "/" })
        let query = String(rawTarget[rawTarget.index(after: qi)...])
        guard let enc = queryValue("u", in: query),
              let upStr = enc.removingPercentEncoding,
              let up = URL(string: M3U8Playlist.sanitizeURLString(upStr))
        else {
            return fail(400, "Bad Request", "这条播放地址读不出来（不是一条完整的地址）")
        }

        // ① 去上游取（带上头 + 播放器要的 Range）
        //   ★★ v1.0.168：先看有没有"刚刷新出来的新地址"（同一批分片共用，见 `refreshed`）；
        //   没有就用清单里嵌的原地址。401/403 时**回头刷新一次父清单**再试一次 ——
        //   清单里那批分片/钥匙地址是"签发时给的"、各自会到期，播放是连贯的一排请求，
        //   只要有一跳到期就挂（而下载是"一口气跑完"，所以看不出这个毛病）。
        let hs = headers(key)
        let effective = freshAddress(key: key, path: up.path) ?? up
        var got = fetch(effective, headers: hs, range: rangeHeader)
        if let code = got.resp?.statusCode, code == 401 || code == 403,
           effective.absoluteString == up.absoluteString,
           let fresh = refresh(parent: key, up: up) {
            rememberFresh(key: key, path: up.path, url: fresh)
            got = fetch(fresh, headers: hs, range: rangeHeader)
        }
        if got.timedOut {
            return fail(504, "Gateway Timeout", "上游 35 秒没回话")
        }
        guard let http = got.resp, let data = got.data else {
            return fail(502, "Bad Gateway",
                        "取不到上游：" + (got.err?.localizedDescription ?? "原因不明"))
        }
        guard (200...299).contains(http.statusCode) else {
            return fail(http.statusCode, "Upstream \(http.statusCode)",
                        "上游返回 \(http.statusCode) —— 地址失效、需要登录，或者防盗链把这条挡了")
        }

        let upCTRaw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let upCT = upCTRaw.lowercased()

        // ② 是清单 → 改写成"全都走本机代理"的清单（master 里的变体行同样会被改写）
        if data.starts(with: [0x23, 0x45, 0x58, 0x54]) || upCT.contains("mpegurl") {
            let base = http.url ?? up
            let text = decode(data)
            guard !text.isEmpty, let rewritten = rewritePlaylist(text, base: base, key: key) else {
                return fail(502, "Bad Gateway", "清单读不出来")
            }
            return Reply(status: 200, reason: "OK",
                         contentType: "application/vnd.apple.mpegurl",
                         body: Data(rewritten.utf8),
                         contentRange: nil, acceptRanges: false)
        }

        // ③ 普通内容（分片 / 钥匙 / 直接文件）→ 原样转发，Range 语义照搬
        let ct = (upCT.isEmpty || upCT.contains("octet-stream"))
            ? LocalHTTPServer.mimeForProxy(up.pathExtension)
            : upCTRaw
        return Reply(status: http.statusCode,
                     reason: http.statusCode == 206 ? "Partial Content" : "OK",
                     contentType: ct.isEmpty ? "application/octet-stream" : ct,
                     body: data,
                     contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                     acceptRanges: true)
    }

    // MARK: - 清单改写

    /// 每一行 URI 都换成代理地址。**解析规则用 `PlaylistRelay` 那一套**（`URI="…"` 的取法、
    /// 相对地址怎么解析）—— 那种规则绝不该有第二份。
    private static func rewritePlaylist(_ text: String, base: URL, key: String) -> String? {
        var out: [String] = []
        var dataLines = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                out.append(PlaylistRelay.rewriteURIAttrs(line, base: base) { abs in
                    proxyString(for: abs, key: key) ?? abs.absoluteString
                })
                continue
            }
            guard let abs = M3U8Playlist.resolve(line, relativeTo: base) else { continue }
            out.append(proxyString(for: abs, key: key) ?? abs.absoluteString)
            dataLines += 1
        }
        // 一行 URI 都没有 = 不是清单（或整份读坏）→ 交给调用方报错，别发一份空清单出去
        guard dataLines > 0 else { return nil }
        return out.joined(separator: "\n") + "\n"
    }

    /// 跟下载器同一个兜底顺序（严格 UTF-8 会败在 GBK 站 / 切片正好切断汉字上）
    private static func decode(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: HLSDownloader.gb18030) { return s }
        return String(data: d, encoding: .isoLatin1) ?? ""
    }

    // MARK: - 取上游（v1.0.168 抽出，供"取一次 + 刷新后再取一次"复用）

    /// `fetch` 的结果。**同步取回**（信号量等完才返回），所以这个值类型不跨并发、安全。
    private struct Fetched {
        var data: Data?
        var resp: HTTPURLResponse?
        var err: Error?
        var timedOut = false
    }

    /// 取一次上游（同步等）。★ 本机服务用的是**并发**队列，所以在这里等不会卡住别人的连接。
    private static func fetch(_ url: URL, headers hs: [String: String]?, range: String?) -> Fetched {
        var req = URLRequest(url: url, timeoutInterval: 30)
        if let hs {
            for (kk, vv) in hs where !vv.isEmpty { req.setValue(vv, forHTTPHeaderField: kk) }
        }
        if let range, !range.isEmpty { req.setValue(range, forHTTPHeaderField: "Range") }

        // ★ 结果用**类**接 —— 绝不能用 `var`（被并发闭包捕获就编译不过，run #138/#164 的坑）
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { d, r, e in
            box.data = d
            box.resp = r as? HTTPURLResponse
            box.err = e
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            return Fetched(timedOut: true)
        }
        return Fetched(data: box.data, resp: box.resp, err: box.err)
    }

    /// 取一份清单正文（沿用同一套兜底编码；严格 UTF-8 会败在 GBK 站上）
    private static func plainText(_ url: URL, headers hs: [String: String]?) -> String? {
        let f = fetch(url, headers: hs, range: nil)
        guard let resp = f.resp, (200...299).contains(resp.statusCode), let d = f.data else { return nil }
        let s = decode(d)
        return s.isEmpty ? nil : s
    }

    /// ★★ v1.0.168：**回头刷新一次父清单**，在清单里按**路径**找到同一行、返回它刚签发的地址。
    ///
    /// 为什么要它（2026-09-29 真机定位）：清单里那批「分片 / 钥匙」地址是**清单签发时给的**，
    /// 它们**各自到期** —— 实测同一条记录里，清单路径时间戳是 18:41、而钥匙的 URI 是 18:35 签发，
    /// **两批地址签发时刻差了 6 分钟**。下载是"一口气跑完"（28.6 秒）所以没事；
    /// **播放是连贯的一排请求**，只要有一跳到期就挂。
    /// v1.0.166 的代理只做到"播放器请求清单时重取"，**分片/钥匙这一层根本没有刷新机制** —— 就是缺这个。
    /// （DeepSeek 在 2026-09-29 的会诊里提醒过"分片 403 时要回头刷新清单"，我当时误判成已实现。）
    ///
    /// 匹配办法：**按路径找同一行** —— 签名会变，路径通常不变。
    /// 取 `URI="…"` 属性**借 `PlaylistRelay.rewriteURIAttrs` 的解析**（把 map 当收集器用），
    /// 不另写一份"找 URI"的规则。
    private static func refresh(parent key: String, up: URL) -> URL? {
        guard let pl = playlist(key),
              let plURL = URL(string: M3U8Playlist.sanitizeURLString(pl)),
              let text = plainText(plURL, headers: headers(key))
        else { return nil }

        let want = up.path
        guard !want.isEmpty else { return nil }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var candidates: [URL] = []
            if line.hasPrefix("#") {
                // 借现成的解析：把 map 当收集器（返回原值，不做改写）
                _ = PlaylistRelay.rewriteURIAttrs(line, base: plURL) { abs in
                    candidates.append(abs)
                    return abs.absoluteString
                }
            } else if let abs = M3U8Playlist.resolve(line, relativeTo: plURL) {
                candidates.append(abs)
            }
            if let hit = candidates.first(where: { $0.path == want }) { return hit }
        }
        return nil
    }

    // MARK: - 小工具

    /// ★ 承接并发闭包的结果。**必须用类** —— 用 `var` 会被并发闭包捕获、直接编译不过。
    private final class Box: @unchecked Sendable {
        var data: Data?
        var resp: HTTPURLResponse?
        var err: Error?
    }

    private static func fail(_ status: Int, _ reason: String, _ msg: String) -> Reply {
        Reply(status: status, reason: reason,
              contentType: "text/plain; charset=utf-8",
              body: Data(msg.utf8), contentRange: nil, acceptRanges: false)
    }

    /// 从 query 里取一个参数（值是我们自己编码过的，里面不会有 `&`/`=`）
    private static func queryValue(_ name: String, in query: String) -> String? {
        for part in query.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            if kv.count >= 2, kv[0] == name { return kv.dropFirst().joined(separator: "=") }
        }
        return nil
    }
}
