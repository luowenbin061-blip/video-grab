import Foundation

/// 一个 m3u8 的解析结果。
///
/// HLS 的 m3u8 分两级，这一点很关键（原方案漏掉了）：
///   · Master Playlist —— 含 #EXT-X-STREAM-INF，里面是「多个清晰度各自的 m3u8 地址」，
///     本身不含分片。直接拼会拼错。
///   · Media Playlist  —— 才是真正列出 .ts 分片的那一层。
/// 所以流程必须是：拿到 m3u8 → 若是 master 则挑一个变体、再取它的子列表 → 解析出分片。
struct M3U8Playlist {

    struct Variant {
        let bandwidth: Int?
        let resolution: String?
        let url: URL
    }

    struct Key {
        let method: String          // AES-128 / NONE / SAMPLE-AES
        let uri: URL?
        /// 可变：清单没写 IV 时要按规范用分片序号推导出来再补进去
        var iv: Data?
    }

    var isMaster = false
    var variants: [Variant] = []
    var segmentURLs: [URL] = []
    var segmentDurations: [Double] = []
    /// 第 i 个分片「之前」是否有 #EXT-X-DISCONTINUITY。
    /// 有的话说明编码参数/时间基变了，拼接时要留意（可能导致进度条不准）。
    var discontinuityBefore: Set<Int> = []
    var key: Key?
    /// #EXT-X-MEDIA-SEQUENCE —— 清单没写 IV 时，某个分片的 IV 由
    /// 「它 + 该分片的下标」推出来，所以要带出去给下载器用。
    var mediaSequence = 0
    var rawText = ""
    /// ★ v1.0.141：这份清单**实际是从哪个地址取到的**。
    ///   为什么需要：`#EXT-X-KEY` 的 URI 也可能是**相对路径**，要按"清单的地址"解析
    ///   （不是按分片的地址）—— 外部审查专门点过这一条。放在这里就不用在各处猜了。
    var baseURL: URL?

    /// #EXT-X-MAP 的原样文本（fMP4/CMAF 的初始化段）。
    /// 记下来**不是为了用它**，是为了能明确告诉用户「这种格式我们拼不出来」。
    var initSegmentRaw: String?
    /// 见过 #EXT-X-BYTERANGE（分片按字节区间给，不是一个个独立文件）
    var sawByteRange = false
    /// 见过的 DRM 加密方式（SAMPLE-AES 那一类；AES-128 不算）
    var drmMethod: String?
    /// ★ v1.0.134：**解析不出来的地址行**（前几条，截断存）。
    ///   以前这种行是静默跳过的 —— 结果是"清单里明明有分片，我们却一个都没拿到"，
    ///   报错只有一句"没有解析出任何分片"，看不出真正原因。
    ///   现在留着它们，报错时能把"到底卡在哪条地址上"念给用户听。
    var badAddressLines: [String] = []

    var totalDuration: Double { segmentDurations.reduce(0, +) }

    /// 这份清单里有没有**我们拼不出来 / 解不了**的写法。
    ///
    /// ★ 为什么必须显式拦下来：以前这些标签被当成「看不懂就跳过」，
    ///   结果是把分片硬拼成一个**缺了开头、播不了的残缺文件**，界面上还显示「下载成功」。
    ///   **产出坏文件却报成功，比直接失败恶劣得多。** 宁可诚实地失败。
    var unsupportedReason: String? {
        if let m = drmMethod {
            return "它用了 \(m) 加密（这是真 DRM，跟流媒体网站那种一回事），我们解不了"
        }
        if let map = initSegmentRaw {
            return "它是 fMP4 格式（清单里有 \(map.prefix(70))），我们的拼接器只认传统的 TS 分片"
        }
        if sawByteRange {
            return "它的分片是按字节区间给的（#EXT-X-BYTERANGE），我们还不支持这种取法"
        }
        return nil
    }

    // MARK: - 解析

    /// ★★ v1.0.134：把一行地址「洗干净」成 Foundation 认得的写法。
    ///
    /// ══ 为什么必须有这一步（用户 2026-09-28 报的真 bug）══
    /// 有些站的分片名**直接写中文**（那一条是 `早披白莉莉莉音号083122-001-CARIB（口交）.0.ts`，
    /// 还带两个**全角括号**）。而 `URL(string:)` 有个硬规矩：
    /// **字符串里只要有一个非 ASCII 字符，它就直接返回 nil**（要求你先做百分号编码）。
    /// 以前这里写的是 `guard let abs = URL(string: line, relativeTo: baseURL) else { continue }`
    /// —— 遇到 nil 就**静默跳过**，于是所有分片行全被扔掉，最后报出
    /// 「m3u8 里没有解析出任何分片」。用户看到的就是"个别视频下不了"
    /// （其实规律是**分片地址带中文的**下不了），而亚瑟浏览器能下 ——
    /// 因为它不走 `URL(string:)` 这条死路。
    ///
    /// ══ 规矩 ══
    ///   · **只编码 ASCII 以外的字符 + 空格 + 几个会坏事的分隔符**；
    ///     `:/?#[]@!$&'()*+,;=` 这些在 URL 里有意义，动了反而会改语义（`?` 是查询开始、
    ///     `#` 是片段开始 —— 把它们编码掉，服务器就取不到东西了）。
    ///   · **已经是 `%XX` 的不能重复编码**（`%` 后面跟两位十六进制就原样留着），
    ///     否则 `%E6` 会变成 `%25E6`，请求路径就错了。
    static func sanitizeURLString(_ s: String) -> String {
        // 快路径：纯 ASCII、没有空格、没有 `#`、且每个 `%` 都真的是两位十六进制
        // → 不用动（绝大多数站走这条，零开销）。
        //
        // ★★ v1.0.140：快路径原来只查"全 ASCII 且无空格"，会漏两种**必须处理**的情况
        //   （2026-09-28 外部审查指出，我逐行核实成立）：
        //     ① **无效的 `%`**：像 `100%.ts` 这种，全 ASCII → 被原样放过，
        //        而 `URL(string:)` 依旧返回 nil —— 于是回到"这行读不懂"的老失败模式；
        //     ② **`#`**：它在 URL 里是"片段开始"，会把后面的文件名整段切掉。
        //        （`视频#1.ts` 会被当成"请求 视频，片段是 1.ts"）
        if s.allSatisfy({ $0.isASCII && $0 != " " && $0 != "#" }), percentEscapesLookOK(s) {
            return s
        }

        var out = ""
        out.reserveCapacity(s.count + 16)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 2 < chars.count,
               chars[i + 1].isHexDigit, chars[i + 2].isHexDigit {
                // 已经是 %XX —— 原样保留（不重复编码）
                out.append(c); out.append(chars[i + 1]); out.append(chars[i + 2])
                i += 3
                continue
            }
            // ★ v1.0.140：`#` 也进"要编码"那一类 —— 见上面快路径的说明。
            //   （片段本来就**不会发到服务器**，把它编码成 %23 只会更安全；
            //     而 `?` **必须保留**，它是查询串的开始，编码掉就取不到东西了。）
            // ★★ v1.0.152：`%` 也进"要编码"那一类 —— **写回归测试时才发现的漏网**：
            //   上面的快路径当初修了"无效百分号"，但慢路径**照样把裸 `%` 原样输出**
            //   （`100%.ts` → 还是 `100%.ts`）→ `URL(string:)` 依旧返回 nil。
            //   合法的 `%XX` 上面已经原样放行，走到这里的 `%` 一定是坏的 → 编成 %25。
            if c.isASCII, c != " ", c != "#", c != "%" {
                out.append(c)
            } else {
                // 非 ASCII / 空格 / 杂七杂八 → 逐个 UTF-8 字节编码
                for b in String(c).utf8 {
                    out += String(format: "%%%02X", b)
                }
            }
            i += 1
        }
        return out
    }

    /// 每个 `%` 后面是不是真的跟着两位十六进制。
    /// 只要有一个不是，就说明这串里存在**无效的百分号转义**（如 `100%.ts`），
    /// 那就**不能走快路径** —— 必须交给慢路径把它编成 `%25`，否则 `URL(string:)` 还是 nil。
    private static func percentEscapesLookOK(_ s: String) -> Bool {
        let a = Array(s)
        var i = 0
        while i < a.count {
            if a[i] == "%" {
                guard i + 2 < a.count, a[i + 1].isHexDigit, a[i + 2].isHexDigit else { return false }
                i += 3
            } else {
                i += 1
            }
        }
        return true
    }

    /// 把一行地址解析成绝对 URL。**先用 `sanitizeURLString` 洗一遍**，
    /// 中文/全角/空格都不会再让 `URL(string:)` 返回 nil。
    /// 真的还是解析不出来（地址本身就残缺）→ 返回 nil，由调用方决定怎么说。
    static func resolve(_ line: String, relativeTo baseURL: URL) -> URL? {
        if let u = URL(string: line, relativeTo: baseURL)?.absoluteURL { return u }
        let fixed = sanitizeURLString(line)
        return URL(string: fixed, relativeTo: baseURL)?.absoluteURL
    }

    /// baseURL 用「真正取到这份 m3u8 的那个地址」，相对路径都相对它解析。
    static func parse(text: String, baseURL: URL) -> M3U8Playlist {
        var p = M3U8Playlist()
        p.rawText = text
        p.baseURL = baseURL          // ★ v1.0.141：钥匙的相对地址要按它解析

        var pendingVariant: (bandwidth: Int?, resolution: String?)?
        var pendingDuration: Double?
        var nextIsDiscontinuity = false
        var currentKey: Key?
        var mediaSequence = 0
        /// ★ v1.0.134：解析不出来的地址行 —— 记下前几条，报错时能说清是哪种地址
        var badLines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let upper = line.uppercased()

                if upper.hasPrefix("#EXT-X-STREAM-INF") {
                    p.isMaster = true
                    pendingVariant = (attrInt(line, "BANDWIDTH"), attrString(line, "RESOLUTION"))
                    continue
                }

                if upper.hasPrefix("#EXT-X-DISCONTINUITY") {
                    nextIsDiscontinuity = true
                    continue
                }

                if upper.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                    // 注意：这是「冒号分隔」的标签（#EXT-X-MEDIA-SEQUENCE:0），
                    // 不能用下面那个按 KEY=VALUE 找的 attrString —— 之前就是这么写错的。
                    mediaSequence = attrAfterColon(line).flatMap(Int.init) ?? 0
                    continue
                }

                if upper.hasPrefix("#EXT-X-MAP") {
                    p.initSegmentRaw = line
                    continue
                }

                if upper.hasPrefix("#EXT-X-BYTERANGE") {
                    p.sawByteRange = true
                    continue
                }

                if upper.hasPrefix("#EXT-X-KEY") {
                    let method = attrString(line, "METHOD") ?? "NONE"
                    if method.uppercased() == "NONE" {
                        currentKey = nil
                    } else if method.uppercased().hasPrefix("SAMPLE-AES") {
                        // SAMPLE-AES / SAMPLE-AES-CTR = 真 DRM。我们解不了，
                        // 但要说清楚 —— 以前会一路下到最后才报一句「分片解密失败」。
                        p.drmMethod = method
                        currentKey = Key(method: method, uri: nil, iv: nil)
                    } else {
                        var uri: URL? = nil
                        if let u = attrString(line, "URI") {
                            // 关键：key 的 URI 常常是相对路径，必须相对这份 m3u8 解析
                            // ★ v1.0.134：同样走 resolve（可能带中文 / 全角）
                            uri = resolve(u, relativeTo: baseURL)
                        }
                        var iv: Data? = nil
                        if let ivStr = attrString(line, "IV") {
                            iv = dataFromHex(ivStr.hasPrefix("0x") || ivStr.hasPrefix("0X")
                                             ? String(ivStr.dropFirst(2)) : ivStr)
                        }
                        currentKey = Key(method: method, uri: uri, iv: iv)
                    }
                    continue
                }

                if upper.hasPrefix("#EXTINF") {
                    let v = line.dropFirst("#EXTINF:".count)
                    let num = v.split(separator: ",").first.map(String.init) ?? ""
                    pendingDuration = Double(num.trimmingCharacters(in: .whitespaces))
                    continue
                }

                continue   // 其他 # 开头的标签忽略
            }

            // ---- 非 # 开头 = 一个地址行 ----
            // 关键：分片名常常是纯文件名（无斜杠无协议），
            // 必须用 URL(string:relativeTo:) 解析成绝对地址，否则 404。
            // ★ v1.0.134：`resolve` 会先做百分号编码 —— 中文 / 全角 / 空格的分片名
            //   以前会让 URL(string:) 返回 nil，整行被静默跳过（这就是"个别视频下不了"的真因）。
            guard let abs = resolve(line, relativeTo: baseURL) else {
                // 解析不出来别静默吞掉 —— 记下来，调用方能把原因念给用户听
                if badLines.count < 5 { badLines.append(String(line.prefix(80))) }
                continue
            }

            if let pv = pendingVariant {
                // 在 master playlist 里，这一行是某个清晰度的 m3u8 地址
                p.variants.append(Variant(bandwidth: pv.bandwidth, resolution: pv.resolution, url: abs))
                pendingVariant = nil
                continue
            }

            // 在 media playlist 里，这一行是一个分片
            let index = p.segmentURLs.count
            if nextIsDiscontinuity {
                p.discontinuityBefore.insert(index)
                nextIsDiscontinuity = false
            }
            p.segmentURLs.append(abs)
            p.segmentDurations.append(pendingDuration ?? 0)
            pendingDuration = nil
            if currentKey != nil { p.key = currentKey }
        }

        // 注意：这里**不能**把「按 mediaSequence 推导的 IV」写进 key ——
        // 一个 key 是所有分片共用的，而每个分片规范上该用自己的序号当 IV。
        // 之前这里写了个单值兜底，结果只有第 0 个分片 IV 正确、其余全错；
        // 现在只把 mediaSequence 带出去，由下载器逐分片算（mediaSequence + 下标）。
        p.mediaSequence = mediaSequence
        p.badAddressLines = badLines

        return p
    }

    /// 从 master playlist 里挑一个变体：默认挑带宽最高的。
    func bestVariant() -> Variant? {
        variants.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
    }

    // MARK: - 小工具

    /// 读 `#EXT-X-XXX:值` 这种「冒号分隔」的标签。
    /// 和 `attrString` 要区分开：那个处理的是 `KEY=VALUE` 形式（如 #EXT-X-KEY 里的 METHOD=...）。
    private static func attrAfterColon(_ line: String) -> String? {
        guard let i = line.firstIndex(of: ":") else { return nil }
        let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// 读 #EXT-X-XXX:KEY=VALUE,... 里的某个值（带引号的会去掉引号）。
    private static func attrString(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: key + "=", options: .caseInsensitive) else { return nil }
        var rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        let v = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func attrInt(_ line: String, _ key: String) -> Int? {
        guard let s = attrString(line, key) else { return nil }
        return Int(s)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var d = Data()
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            d.append(b)
            i += 2
        }
        return d
    }
}
