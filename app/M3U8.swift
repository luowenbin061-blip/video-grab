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
        let iv: Data?
    }

    var isMaster = false
    var variants: [Variant] = []
    var segmentURLs: [URL] = []
    var segmentDurations: [Double] = []
    /// 第 i 个分片「之前」是否有 #EXT-X-DISCONTINUITY。
    /// 有的话说明编码参数/时间基变了，拼接时要留意（可能导致进度条不准）。
    var discontinuityBefore: Set<Int> = []
    var key: Key?
    var rawText = ""

    var totalDuration: Double { segmentDurations.reduce(0, +) }

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
                    mediaSequence = attrInt(line, "MEDIA-SEQUENCE") ?? 0
                    continue
                }

                if upper.hasPrefix("#EXT-X-KEY") {
                    let method = attrString(line, "METHOD") ?? "NONE"
                    if method.uppercased() == "NONE" {
                        currentKey = nil
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

        // 没写 IV 的话，HLS 规范规定用分片序号当 IV
        if var k = p.key, k.iv == nil {
            var be = UInt32(mediaSequence).bigEndian
            var iv = Data(count: 16)
            withUnsafeBytes(of: &be) { iv.replaceSubrange(12..<16, with: $0) }
            k.iv = iv
            p.key = k
        }

        return p
    }

    /// 从 master playlist 里挑一个变体：默认挑带宽最高的。
    func bestVariant() -> Variant? {
        variants.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
    }

    // MARK: - 小工具

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
