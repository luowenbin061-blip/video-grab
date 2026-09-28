import Foundation

/// 下载前先「探一下」这个地址到底是什么。
///
/// 为什么必须有这一步：嗅探只按地址字符串猜类型（带 m3u8 字样就当清单），
/// 而实际拿到的东西经常不是清单 —— mp4 直链、跳转页、接口页都会被塞给 m3u8 解析器，
/// 结果统一是「一个分片都没解析出来」，用户只看到一句失败、不知道卡在哪。
/// 这里先取前 2KB 看一眼：是真清单 / 是单个文件 / 还是认不出。
/// 顺带把 HTTP 状态和内容开头记进过程记录 —— 以后再出问题，看一眼就知道原因。
struct SourceProbe {

    enum Kind { case hls, file, unknown }

    /// ★ v1.0.109：这个地址到底是什么东西 —— 决定下载后怎么处理。
    ///   原来只有"视频/不是视频"两种，现在四类 + 未知（未知也允许下载）。
    enum MediaClass: String {
        case video, image, audio, doc, unknown

        var label: String {
            switch self {
            case .video: return "视频"
            case .image: return "图片"
            case .audio: return "音频"
            case .doc: return "文档"
            case .unknown: return "文件"
            }
        }
    }

    var kind: Kind = .unknown
    var media: MediaClass = .unknown
    var httpStatus: Int = 0
    var contentType: String = ""
    var contentLength: Int64 = 0
    var acceptsRange = false
    /// 取回内容的开头（压成一行，诊断用）
    var headText: String = ""

    /// 写进「过程记录」的一行
    var summary: String {
        var s = "HTTP \(httpStatus)"
        if !contentType.isEmpty { s += " · \(contentType)" }
        if contentLength > 0 { s += " · \(contentLength / 1024)KB" }
        if acceptsRange { s += " · 支持分段" }
        s += " · " + label
        if !headText.isEmpty { s += "  开头：\(headText)" }
        return s
    }

    private var label: String {
        switch kind {
        case .hls: return "HLS 清单"
        case .file: return "单个文件 · \(media.label)"
        case .unknown: return "认不出（网页）"
        }
    }

    static func fetch(url: URL, ua: String, referer: String?,
                      cookie: String?, timeout: TimeInterval) async -> SourceProbe {
        var p = SourceProbe()
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty { r.setValue(referer, forHTTPHeaderField: "Referer") }
        if let cookie, !cookie.isEmpty { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        r.setValue("bytes=0-2047", forHTTPHeaderField: "Range")

        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse {
                p.httpStatus = h.statusCode
                p.contentType = (h.value(forHTTPHeaderField: "Content-Type") ?? "")
                    .components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                p.contentLength = h.expectedContentLength
                p.acceptsRange = h.statusCode == 206
                    || h.value(forHTTPHeaderField: "Content-Range") != nil
                    || (h.value(forHTTPHeaderField: "Accept-Ranges") ?? "") == "bytes"
                // 206 时 expectedContentLength 只是这一段的长度，要用 Content-Range 里的总长
                if let cr = h.value(forHTTPHeaderField: "Content-Range"),
                   let total = cr.components(separatedBy: "/").last,
                   let n = Int64(total) {
                    p.contentLength = n
                }
            }

            // ★★ v1.0.136：**解码绝不能整个失败** —— 这一条修的是用户报的「小部分视频下载失败」。
            //
            // 以前写的是 `String(data:data.prefix(2048), encoding:.utf8) ?? ""`：
            // 严格 UTF-8 解码有两个**非常常见**的坑，一踩就把"取回的内容"当成**空串**：
            //   ① 这份 m3u8 根本不是 UTF-8（中文站很常见 GBK/GB18030）→ 整段解不出来 → nil；
            //   ② 我们只取了**前 2048 字节**，正好切在一个多字节汉字中间（中文名分片很常见）→ nil。
            // 于是 `trimmed` 是空串 → `hasPrefix("#EXTM3U")` 为假 → 掉进下面"单个文件"那一支
            // → `kind = .file` → 下载器**把清单本身当成一个文档存了下来**，
            //   界面上就是「MP4 没转出来 …… 已保存（文件，不需要转码）」。
            // 用户那条过程记录正好是这个签名：`application/x-mpegURL · 单个文件 · 文件`，
            // 而且**没有「开头：」那一段**（因为 headText 是空的）—— 一查就中。
            //
            // `#EXTM3U` 是**纯 ASCII**：只要解码**别整个失败**，它一定读得出来。
            // 所以改用 `String(decoding:as:)` —— 它**永不失败**，坏字节变 U+FFFD，ASCII 原样保留。
            let text = String(decoding: data.prefix(4096), as: UTF8.self)
            var probeText = text
            if probeText.hasPrefix("\u{FEFF}") { probeText.removeFirst() }   // UTF-8 BOM 也会让 hasPrefix 落空
            let trimmed = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
            let ct = p.contentType.lowercased()
            let head = trimmed.lowercased()
            // 服务器自己说是清单，或地址后缀就是 .m3u8 → 也算清单（双保险，防"看内容"这一路失手）
            let looksLikePlaylist = ct.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"

            if trimmed.hasPrefix("#EXTM3U") {
                // ① HLS 清单（视频的分片式）
                p.kind = .hls
                p.media = .video
            } else if ct.hasPrefix("text/html") || head.hasPrefix("<!doctype") || head.hasPrefix("<html") {
                // ② 网页本身 —— **唯一**"认出来了也故意不让下"的类型。
                //    以前 unknown 一律拒，现在 unknown 也允许（见 ⑥），所以必须在这里显式拦。
                //    ★ 顺序在 looksLikePlaylist **之前**：一个 .m3u8 地址如果返回的是网页（多半是
                //      404 页 / 拦截页），那它就不是清单，不能因为后缀像就硬当清单处理。
                p.kind = .unknown
                p.media = .unknown
            } else if looksLikePlaylist {
                // ②' ★ v1.0.136：内容没读成 `#EXTM3U`，但**服务器说它是 mpegurl / 地址是 .m3u8**
                //    → 仍然走清单这条路。宁可进去之后报"清单里没有分片（附开头）"，
                //    也不能把它当直链文件下下来（那是"静默下错东西"，比报错恶劣）。
                p.kind = .hls
                p.media = .video
            } else {
                // ③④⑤⑥ 依次往下试：Content-Type → 文件头 → 扩展名 → 都不认识也放行
                //
                // ★ v1.0.109 把顺序**反过来**了（原来是"扩展名优先"）。
                //   这是"不带后缀的地址一律下不了"的根因：/media?id=8823 这种
                //   明明 Content-Type 写着 image/jpeg，却因为没后缀被判"认不出"。
                let ext = url.pathExtension.lowercased()
                p.kind = .file
                if let m = Self.byContentType(ct) {
                    p.media = m
                } else if let m = Self.byMagic(Data(data.prefix(16))) {
                    // 文件头 —— 这 2KB 我们**本来就在取**，只是以前没拿去比对
                    p.media = m
                } else if let m = Self.byExtension(ext) {
                    p.media = m
                } else if ct.contains("octet-stream") {
                    p.media = .unknown
                } else {
                    // 什么都不认识 —— 仍然允许下载（存成文件总比"直接失败"有用）
                    p.media = .unknown
                }
            }
            p.headText = Self.oneLine(String(trimmed.prefix(160)))
        } catch {
            p.httpStatus = -1
            p.headText = "请求出错：\(error.localizedDescription)"
        }
        return p
    }

    /// Content-Type → 类型（最权威，服务器自己说的）
    private static func byContentType(_ ct: String) -> MediaClass? {
        if ct.hasPrefix("video/") || ct == "application/mp2t" { return .video }
        if ct.hasPrefix("image/") { return .image }
        if ct.hasPrefix("audio/") { return .audio }
        let docTypes = ["application/pdf", "application/zip", "application/x-zip",
                        "application/x-rar", "application/x-7z-compressed",
                        "application/epub+zip", "text/plain", "text/csv",
                        "application/msword", "application/vnd.ms-excel",
                        "application/vnd.ms-powerpoint",
                        "application/vnd.openxmlformats-officedocument"]
        for d in docTypes where ct.hasPrefix(d) { return .doc }
        return nil
    }

    /// 文件头（magic bytes）→ 类型。Content-Type 不可靠时的兜底
    /// （很多站把什么都写成 application/octet-stream）。
    private static func byMagic(_ d: Data) -> MediaClass? {
        guard d.count >= 12 else { return nil }
        let b = [UInt8](d)
        func at(_ i: Int, _ s: [UInt8]) -> Bool {
            guard i + s.count <= b.count else { return false }
            for (k, v) in s.enumerated() where b[i + k] != v { return false }
            return true
        }
        func text(_ i: Int, _ t: String) -> Bool { at(i, [UInt8](t.utf8)) }

        if at(0, [0xFF, 0xD8, 0xFF]) { return .image }                     // JPEG
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return .image }               // PNG
        if text(0, "GIF8") { return .image }                               // GIF
        if text(0, "RIFF"), text(8, "WEBP") { return .image }              // WebP
        if text(0, "RIFF"), text(8, "WAVE") { return .audio }              // WAV
        if at(0, [0x25, 0x50, 0x44, 0x46]) { return .doc }                 // PDF
        if at(0, [0x50, 0x4B, 0x03, 0x04]) || at(0, [0x50, 0x4B, 0x05, 0x06]) { return .doc }  // ZIP
        if text(0, "Rar!") { return .doc }                                 // RAR
        if at(0, [0x37, 0x7A, 0xBC, 0xAF]) { return .doc }                 // 7z
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) { return .video }               // MKV / WebM
        if text(0, "ID3") { return .audio }                                // MP3（带 ID3）
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return .audio }           // MP3（裸帧）
        if text(0, "OggS") { return .audio }                               // OGG
        if text(0, "fLaC") { return .audio }                               // FLAC
        if text(4, "ftyp") {                                               // MP4 / MOV / M4A / HEIC
            let brand = String(bytes: b[8..<min(12, b.count)], encoding: .ascii) ?? ""
            if brand.hasPrefix("heic") || brand.hasPrefix("heix")
                || brand.hasPrefix("avif") || brand.hasPrefix("mif1") { return .image }
            if brand.hasPrefix("M4A") { return .audio }
            return .video
        }
        return nil
    }

    /// 扩展名 → 类型（最后的兜底）
    private static func byExtension(_ ext: String) -> MediaClass? {
        if ["mp4", "m4v", "mov", "webm", "mkv", "flv", "f4v", "avi", "ts", "m4s"].contains(ext) { return .video }
        if ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "svg"].contains(ext) { return .image }
        if ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(ext) { return .audio }
        if ["pdf", "zip", "rar", "7z", "epub", "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx"].contains(ext) { return .doc }
        return nil
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
