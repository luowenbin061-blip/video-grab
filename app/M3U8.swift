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

    /// #EXT-X-MAP 的原样文本（fMP4/CMAF 的初始化段）。
    /// 记下来**不是为了用它**，是为了能明确告诉用户「这种格式我们拼不出来」。
    var initSegmentRaw: String?
    /// 见过 #EXT-X-BYTERANGE（分片按字节区间给，不是一个个独立文件）
    var sawByteRange = false
    /// 见过的 DRM 加密方式（SAMPLE-AES 那一类；AES-128 不算）
    var drmMethod: String?

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

    /// baseURL 用「真正取到这份 m3u8 的那个地址」，相对路径都相对它解析。
    static func parse(text: String, baseURL: URL) -> M3U8Playlist {
        var p = M3U8Playlist()
        p.rawText = text

        var pendingVariant: (bandwidth: Int?, resolution: String?)?
        var pendingDuration: Double?
        var nextIsDiscontinuity = false
        var currentKey: Key?
        var mediaSequence = 0

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
                            uri = URL(string: u, relativeTo: baseURL)?.absoluteURL
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
            guard let abs = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }

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
