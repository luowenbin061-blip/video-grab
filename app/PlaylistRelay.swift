import Foundation

/// 把「远端清单」变成一份**洗干净、地址绝对化**的本地清单，再交给播放器播。
///
/// ══ 为什么必须有这一步（2026-09-28 拿真机那条地址实测出来的铁证）══
/// 用户报「内置播放器播放失败 / HTTP 400」，我把那条地址拿下来做了对照实验：
///
///   | 请求 | 服务端返回 |
///   |---|---|
///   | 清单本身 `<名称>.m3u8` | **200** · 7745 B · 合法 UTF-8 · 103 个分片 |
///   | 清单里的真实分片 `<名称>0.ts` | **200 / 206**（百分号编码、原生中文、带 Range 都试了，**都行**） |
///   | 带不带 `Referer` | **无差别** —— 这个站对分片**不校验**防盗链 |
///   | 播放器实际请求的那条 `<名称>.ts` | **404** |
///
/// 结论：**站上东西是好的；是 AVPlayer 把分片名解析错了** ——
/// 它把清单一行的 `<名称>0.ts` 变成了 `<名称>.ts`（**丢掉了序号**），
/// 给出的地址还是 `https:///4x1.ekcvn.com/…`（`https://` 后面多一个斜杠 = **主机名为空**）。
///
/// 而那份清单里唯一的"异常"就是：**分片行是「原生中文 + 全角括号」的相对路径**
/// （`苍井樱的打手枪2番号HEYZO-2008（口交）0.ts`）。能正常播放的站，分片名都是纯 ASCII。
///
/// ★ 这和 v1.0.134~136 是**同一个病根的第三个表现**：
///   下载路径之所以没这个毛病，正是因为**我们自己把清单每一行都清洗过**（`sanitizeURLString`）；
///   而播放路径以前是把远端的原始清单**直接**交给 AVPlayer —— 它自己没有清洗这一步。
///
/// ══ 做法 ══
///   ① 我们自己取清单（带上 UA / Referer / Cookie）
///   ② 逐行清洗：分片行 → 百分号编码 + **解析成绝对地址**。
///      给了绝对地址，播放器就只剩"照抄"这一件事，不再需要它自己做任何 URL 解析。
///   ③ 写成本地 `.m3u8`（放进本机 HTTP 服务的 root）
///   ④ 播放器播 `http://127.0.0.1:<端口>/<这份清单>`（HLS 必须来自 http，`file://` 不行）
///
/// ══ 为什么不能只用本地文件（`file://`）══
/// `Exporter.swift` 里已经实测记着：本地 `.m3u8` 用 `file://` 会报
/// `CoreMediaErrorDomain -12865 / 12881` —— **HLS 必须是 http/https**。
/// 所以必须借本机 HTTP 服务那一层（跟「边下边播」用的是同一套机制）。
///
/// ══ 只用在这一种情况：VOD ══
/// 清单里带 `#EXT-X-ENDLIST`（有头有尾）才走这里。
/// **直播清单是"活的"** —— 快照一份就会播完即停，那是把一个能用的功能搞坏。
/// 所以直播一律保持原样直连，宁可维持现状。
///
/// ══ 失败就退回原样（重要）══
/// 任何一步不顺（取不到 / 解不出 / 写不下 / 服务起不来）→ 返回 nil，
/// 调用方用**原来的远端地址**照旧播 —— **绝不比现在更差**。
enum PlaylistRelay {

    /// 临时清单的文件名前缀（带点，尽量不碍眼；存盘前会清掉旧的）
    static let filePrefix = ".vgplay_"

    /// 临时清单保留多久（秒）。
    ///
    /// ★ v1.0.140：从"1 小时"放宽到 **7 天**。
    ///   文件名现在是按远端地址算的**稳定名字**（同一部片子每次同一个文件），
    ///   压根不会堆积；而"1 小时就删"会在**播放中被删**——
    ///   AVPlayer 播放 HLS 时会重新请求清单（seek 之后尤其明显），
    ///   那时清单没了 → 直接 404 / 拖进度条黑屏。放宽之后这个坑就没了。
    static let staleAge: TimeInterval = 7 * 24 * 3600

    /// 要交给内置播放器的**一条东西**：地址已经是"能播的那个"。
    ///
    /// 为什么要单独一个类型：地址要先经过异步的"清单本地化"才能定下来，
    /// 而 `PlayerSheet` 需要一个 `Identifiable` 的值来驱动 `fullScreenCover`。
    struct PlayTarget: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let headers: [String: String]?
    }

    /// 统一入口：把"网页/嗅探拿到的那条地址"变成一个能播的目标。
    ///
    /// 顺序：清洗（非 ASCII 转百分号）→ **试清单本地化** → 不成或不是 http(s) 就用原地址。
    /// 返回 nil 只表示"连合法 URL 都不是"，那时调用方给一句提示就行。
    static func target(remote: String,
                       title: String,
                       headers: [String: String]?) async -> PlayTarget? {
        let cleaned = M3U8Playlist.sanitizeURLString(remote)
        guard let raw = URL(string: cleaned) else { return nil }
        let final = await localPlaybackURL(remote: raw, headers: headers, root: JobStore.dir) ?? raw
        return PlayTarget(url: final, title: title, headers: headers)
    }

    /// 生成一份本地清单并返回它的本机 http 地址。
    /// 返回 nil = 这一步没成，调用方请用原来的远端地址。
    ///
    /// - Parameters:
    ///   - remote: 远端清单地址（我们已经 `sanitizeURLString` 洗过的那个）
    ///   - headers: 取清单要带的头（UA / Referer / Cookie，防盗链站必需）
    ///   - root: 本机 HTTP 服务的根目录（和下载目录一致，见 `JobStore.dir`）
    static func localPlaybackURL(remote: URL,
                                 headers: [String: String]?,
                                 root: URL,
                                 timeout: TimeInterval = 20) async -> URL? {
        // ★ 只管 http/https。
        //   本地文件（下好的 mp4 / 本机那份 .ts 清单）本来就是 `file://` 或 `127.0.0.1`，
        //   它们**已经是能播的**，不该再被"取一遍" —— 而且 URLSession 也取不了 `file://`。
        guard let scheme = remote.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        // ① 自己取清单
        var req = URLRequest(url: remote, timeoutInterval: timeout)
        if let headers {
            for (k, v) in headers where !v.isEmpty {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty else { return nil }
        // 相对地址要相对**最终**地址解析（中间可能有一次跳转）
        let base = resp.url ?? remote

        // ② 解码：跟下载器同一套兜底（严格 UTF-8 会败在 GBK 站 / 切片切断汉字上）
        let text: String
        if let u = String(data: data, encoding: .utf8) {
            text = u
        } else if let g = String(data: data, encoding: HLSDownloader.gb18030) {
            text = g
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
        }
        guard !text.isEmpty, text.contains("#EXTM3U") else { return nil }

        // ③ 只处理 VOD。直播是"活的"，快照会播完即停 —— 那种情况退回原地址直连。
        guard text.contains("#EXT-X-ENDLIST") else { return nil }

        // ④ 逐行清洗：数据行 → 绝对地址；`#EXT-X-KEY` 的 URI 也顺手洗（同一个病根）
        var out: [String] = []
        var dataLines = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                // ★ 所有 `#` 标签里的 `URI="…"` 都要绝对化 —— 不只是 #EXT-X-KEY，
                //   还有 #EXT-X-MAP（fMP4 初始化段）等。理由见 rewriteURIAttrs 的注释。
                out.append(rewriteURIAttrs(line, base: base))
                continue
            }
            guard let abs = M3U8Playlist.resolve(line, relativeTo: base) else { return nil }
            out.append(abs.absoluteString)
            dataLines += 1
        }
        guard dataLines > 0 else { return nil }

        // ⑤ 写盘（原子写）
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // ★ 文件名由**远端地址**算出来（稳定）：同一部片子每次覆盖同一份，
        //   既不堆积、也不会"播到一半清单被清理掉"（旧代码用随机 UUID，每次都是一份新的）。
        let name = filePrefix + stableKey(remote.absoluteString) + ".m3u8"
        let dst = root.appendingPathComponent(name)
        guard let body = out.joined(separator: "\n").appending("\n").data(using: .utf8) else { return nil }
        do {
            try body.write(to: dst, options: .atomic)
        } catch {
            return nil
        }

        // ⑥ 起本机服务、拿地址
        guard LocalHTTPServer.shared.start(root: root) != nil else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        cleanOld(root: root, keep: name)
        return LocalHTTPServer.shared.url(name)
    }

    /// 清掉很久没用过的临时清单（保留刚写的那一份）。
    ///
    /// ★★ 为什么不是"1 小时就删"（v1.0.140 改）——
    ///   文件名现在是**按远端地址算出来的稳定名字**（同一部片子每次都是同一个文件），
    ///   所以根本不会堆积，清理可以放得很松。
    ///   而"1 小时"那个阈值有个真问题：**AVPlayer 在播放中会重新请求清单**
    ///   （seek 之后尤其明显），如果那份清单在播放期间被删掉，就会出现
    ///   "播着播着 404 / 拖进度条黑屏"。→ 放宽到 7 天，播放中绝不会被删。
    private static func cleanOld(root: URL, keep: String) {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: []) else { return }
        let now = Date()
        for f in list where f.lastPathComponent.hasPrefix(filePrefix) {
            if f.lastPathComponent == keep { continue }
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(mod) > staleAge {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// 稳定短哈希（FNV-1a 64 位）—— 给临时清单起一个"同一部片子每次都一样"的名字。
    ///
    /// ★ 为什么不能用 `String.hashValue`：它带**每进程随机种子**，每次启动结果都不同，
    ///   那样文件名又变回"每次新一份"，等于没解决问题。
    ///   这里只要求"稳定 + 够散"，不需要抗攻击，所以用最朴素的 FNV-1a。
    private static func stableKey(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(String(format: "%016llx", h).prefix(8))
    }

    /// ★★ v1.0.141：把"已下好的分片 + 取下来的钥匙"写成一份**本地清单**，
    /// 交给内嵌 ffmpeg 去做**解密 / 拼接 / 换封装**。
    ///
    /// ══ 为什么要这么干（实测得出的结论，不是推想）══
    ///   · 我们自己那套"一把钥匙解全片 + 自己拼接"，遇到**逐段换钥匙**的清单必废：
    ///     真实事故里 409 个分片有 401 个解密错 → 成品 2MB 而输入 212.7MB，**界面还报成功**。
    ///   · 而 ffmpeg 的 hls 解复用器**本来就按段切钥匙**、fMP4 也会处理 —— 这是它的本职工作。
    ///
    /// ══ 命名与协议：本机跑真 ffmpeg 试了三种组合才定下来 ══
    ///   · 分片 `.ts` + 钥匙走 http        → ❌ 钥匙协议不在白名单（只允许 file/crypto/data）
    ///   · 分片 `.ts` + 钥匙 `.part`（本地）→ ❌ `.part` 不在文件后缀白名单
    ///   · **分片与钥匙都叫 `.ts`、清单放同目录写相对名** → ✅ 通过（退出码 0、轨齐全）
    ///   → 所以清单里**不出现任何绝对地址**，也**不需要起本机 HTTP 服务**。
    ///
    /// 返回 (清单地址, 放弃原因)：成了 why = nil；没成就 url = nil 而 why 是**具体是哪一步不行的**。
    /// ★ v1.0.142：以前只返回 nil，调用方只能说一句"凑不成一份本地清单" —— 于是真机上
    ///   根本看不出卡在哪（白猜一轮）。失败原因必须留痕，这一条是这个项目的铁律。
    static func localPlaylistURL(playlist: M3U8Playlist, partsDir: URL,
                                 headers: [String: String]?) async -> (url: URL?, why: String?, skippedAds: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: partsDir, withIntermediateDirectories: true)

        var out: [String] = []
        var segIndex = 0
        var keyIndex = 0
        var keyCache: [String: String] = [:]          // 远端钥匙地址 → 本地文件名（同一把只取一次）
        let base = playlist.baseURL

        // ★★ v1.0.146：「广告 + 真片 + 广告」拼在一份清单里的站（本机实测：广告 1280×720、
        //   真片 1280×2276）—— 拼在一起转出来的 MP4 **视频参数中途会变**，
        //   播放器从第二段开始只出声音、画面停在广告最后一帧（真机 4 条里 2 条复现）。
        //   → 只保留"地址里带请求目录名"的那一段（= 用户要的那部），广告段不下。
        //   判据：分片地址里含不含【请求清单所在目录的名字】（如 fGzW9Ut6）。
        //   ★ 判据不成立（全都匹配 / 全都不匹配）→ **全下**，绝不误删真片。
        var anchor: String? = nil
        if let b = base {
            let n = b.deletingLastPathComponent().lastPathComponent
            if n.count >= 4 { anchor = n }        // 太短的目录名当锚点容易误伤
        }
        var matched = 0, missed = 0
        if anchor != nil {
            for raw in playlist.rawText.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let u = M3U8Playlist.resolve(line, relativeTo: base ?? partsDir)?.absoluteString ?? line
                if u.contains(anchor!) { matched += 1 } else { missed += 1 }
            }
        }
        // 只在"有匹配也有不匹配"时才过滤 —— 两种极端都按全下处理
        let keepOnlyMatched = (anchor != nil && matched > 0 && missed > 0)
        var skippedAds = 0

        for raw in playlist.rawText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                guard line.hasPrefix("#EXT-X-KEY") else {
                    // ★ `#EXT-X-MAP`（fMP4 的初始化段）现在**故意不处理** ——
                    //   那种流还没验证过，宁可让 ffmpeg 直接报错，也不假装能做。
                    out.append(line)
                    continue
                }
                guard let info = keyAttr(line) else { out.append(line); continue }
                if info.method.uppercased() == "NONE" {
                    out.append("#EXT-X-KEY:METHOD=NONE")
                    continue
                }
                if let cached = keyCache[info.uri] {
                    out.append(replacingURI(line, with: cached))
                    continue
                }
                // 钥匙地址可能是相对路径 → 按**清单的基准地址**解析（不是分片的）
                let resolved: URL?
                if let b = base {
                    resolved = M3U8Playlist.resolve(info.uri, relativeTo: b)
                } else {
                    resolved = URL(string: M3U8Playlist.sanitizeURLString(info.uri))
                }
                guard let ku = resolved else { return (nil, "钥匙地址读不懂：\(info.uri.prefix(80))", 0) }
                var req = URLRequest(url: ku, timeoutInterval: 20)
                if let headers {
                    for (k, v) in headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
                }
                guard let (kd, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      kd.count >= 16 else { return (nil, "钥匙取不到（状态码或内容不对）：\(ku.absoluteString.prefix(80))", 0) }
                let name = DLName.key(keyIndex)
                do {
                    try kd.write(to: partsDir.appendingPathComponent(name), options: .atomic)
                } catch { return (nil, "钥匙写盘失败", 0) }
                keyCache[info.uri] = name
                keyIndex += 1
                out.append(replacingURI(line, with: name))
                continue
            }

            // 分片行 → 本地相对名（按出现顺序，从 seg_000000.ts 起）
            let name = DLName.segment(segIndex)
            guard fm.fileExists(atPath: partsDir.appendingPathComponent(name).path) else {
                return (nil, "第 \(segIndex) 个分片文件不在（\(name)）—— 分片没下齐或名字对不上", 0)
            }
            segIndex += 1
            // ★ 广告过滤（判据见上）：只留"带请求目录名"的那段
            if keepOnlyMatched, let a = anchor {
                let u = M3U8Playlist.resolve(line, relativeTo: base ?? partsDir)?.absoluteString ?? line
                if !u.contains(a) { skippedAds += 1; continue }
            }
            out.append(name)
        }
        guard segIndex > 0 else { return (nil, "这份清单里没有分片行", 0) }

        let dst = partsDir.appendingPathComponent(DLName.playlist)
        guard let body = out.joined(separator: "\n").appending("\n").data(using: .utf8) else {
            return (nil, "清单文本编码失败", 0)
        }
        do {
            try body.write(to: dst, options: .atomic)
        } catch { return (nil, "清单写盘失败：\(error.localizedDescription)", 0) }
        return (dst, nil)
    }

    /// 从 `#EXT-X-KEY` 行里取出 METHOD 与 URI（没有 URI 就返回 nil）
    private static func keyAttr(_ line: String) -> (method: String, uri: String)? {
        guard let r = line.range(of: "URI=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let r2 = rest.range(of: "\"") else { return nil }
        let uri = String(rest[..<r2.lowerBound])
        guard !uri.isEmpty else { return nil }
        var method = ""
        if let mr = line.range(of: "METHOD=") {
            method = String(line[mr.upperBound...].prefix { $0 != "," })
                .trimmingCharacters(in: .whitespaces)
        }
        return (method, uri)
    }

    /// 把 `#EXT-X-KEY` 行里的 URI 换成给定名字
    private static func replacingURI(_ line: String, with name: String) -> String {
        guard let info = keyAttr(line) else { return line }
        return line.replacingOccurrences(of: "URI=\"" + info.uri + "\"",
                                        with: "URI=\"" + name + "\"")
    }

    /// 把一行 `#` 标签里**所有** `URI="…"` 都重写成绝对远端地址。
    ///
    /// ★★ 为什么必须"所有"，而不是只认 `#EXT-X-KEY`、更不能只动含非 ASCII 的：
    ///   这份清单**被搬到了本机 http**（`http://127.0.0.1:端口/…`）——
    ///   于是清单里**任何相对地址的解析基准都跟着变了**，相对 URI 会被解析到本机服务的根目录下，
    ///   必然 404。原来在远端好好的 `#EXT-X-KEY:METHOD=AES-128,URI="key.bin"`（纯 ASCII）
    ///   搬过来之后就废了，**属于"把本来能播的搞坏"的那一类**（2026-09-28 外部审查指出，已核实）。
    ///   同类标签还有 `#EXT-X-MAP:URI="init.mp4"`（fMP4 的初始化段，漏了直接播不了）、
    ///   `#EXT-X-MEDIA:…URI="…"`、`#EXT-X-I-FRAME-STREAM-INF:URI="…"`。
    ///   → 所以：**凡是 `URI="…"`，一律换成绝对远端地址**（原本已是绝对的会原样返回）。
    private static func rewriteURIAttrs(_ line: String, base: URL) -> String {
        guard line.contains("URI=\"") else { return line }
        var out = ""
        var rest = Substring(line)
        while let r = rest.range(of: "URI=\"") {
            out += rest[..<r.upperBound]
            rest = rest[r.upperBound...]
            guard let r2 = rest.range(of: "\"") else { return line }   // 引号都没闭合 → 整行不动
            let uri = String(rest[..<r2.lowerBound])
            if let abs = M3U8Playlist.resolve(uri, relativeTo: base) {
                out += abs.absoluteString
            } else {
                out += uri
            }
            rest = rest[r2.lowerBound...]
        }
        out += rest
        return out
    }
}
