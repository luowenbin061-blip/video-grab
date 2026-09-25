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

    var kind: Kind = .unknown
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
        case .file: return "单个文件"
        case .unknown: return "认不出"
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

            let text = String(data: Data(data.prefix(2048)), encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTM3U") {
                p.kind = .hls
            } else if p.contentType.hasPrefix("video/") || p.contentType.hasPrefix("audio/")
                        || p.contentType.contains("octet-stream") {
                p.kind = .file
            } else {
                let ext = url.pathExtension.lowercased()
                let fileExts = ["mp4", "m4v", "mov", "webm", "mkv", "flv", "avi", "ts", "mp3", "m4a"]
                p.kind = fileExts.contains(ext) ? .file : .unknown
            }
            p.headText = Self.oneLine(String(trimmed.prefix(160)))
        } catch {
            p.httpStatus = -1
            p.headText = "请求出错：\(error.localizedDescription)"
        }
        return p
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
