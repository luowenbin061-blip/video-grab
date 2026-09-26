import Foundation

/// 直链单文件下载（mp4 这类）。
///
/// 为什么单独写一个：原来所有下载都塞给 m3u8 解析器 —— mp4 直链进去就是
/// 「没有解析出任何分片」。这条路径直接把文件拉下来。
///
/// 大文件按 16MB 一段拉（和服务端协商 Range），好处有两个：
///   ① 进度按真实字节走（不是猜的）
///   ② 断了以后 .part 还在 → 再点继续就从断的地方接着拉
/// 服务端不支持 Range 时退回「一次拉完」。
struct FileDownloader {

    struct Options {
        var userAgent: String
        var referer: String?
        var cookie: String?
        var timeout: TimeInterval = 30
        var outputURL: URL
        var partURL: URL
        var expectedLength: Int64 = 0
        var acceptsRange = false
    }

    enum Fail: LocalizedError {
        case badStatus(Int)
        case empty
        case noSpace
        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "服务器返回 HTTP \(c)"
            case .empty: return "服务器返回了空内容"
            case .noSpace:
                // ★ v1.0.101：会诊指出"磁盘满"的报错在不同路径上完全不一样
                //（URLError / NSPOSIXErrorDomain 28 / NSFileWriteOutOfSpaceError），
                // 不识别就会显示成一句看不懂的系统错误。
                return "手机空间不够了（写文件失败）。先清一下空间再点重试。"
            }
        }
    }

    /// ★ v1.0.101：直链下载改用 **ephemeral** 会话 ——
    /// 默认的 shared 会话会把响应塞进 URLCache、还带上凭据存储，全在进程内存里；
    /// 下大文件时这是白白多占一份。
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// 判断"写不下去"是不是因为空间满了（各家错误域都算上）
    static func isNoSpace(_ e: Error) -> Bool {
        let ns = e as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 28 { return true }      // ENOSPC
        if ns.domain == NSCocoaErrorDomain && ns.code == 640 { return true }     // fileWriteOutOfSpace
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotWriteToFile { return true }
        return false
    }

    let options: Options
    /// (已下字节, 总字节；总长不知道时给 0)
    var onProgress: (Int64, Int64) -> Void = { _, _ in }

    func run(url: URL) async throws -> Int64 {
        let fm = FileManager.default
        try? fm.createDirectory(at: options.partURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // 断点：.part 里已有的字节数
        var done: Int64 = 0
        if let sz = try? fm.attributesOfItem(atPath: options.partURL.path)[.size] as? Int64, sz > 0 {
            done = sz
        } else {
            fm.createFile(atPath: options.partURL.path, contents: nil)
        }

        let total = options.expectedLength
        let chunk: Int64 = 16 * 1024 * 1024

        if options.acceptsRange {
            while true {
                let start = done
                var req = request(for: url)
                req.setValue("bytes=\(start)-\(start + chunk - 1)", forHTTPHeaderField: "Range")
                let (data, resp) = try await Self.session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

                if code == 200 && start > 0 {
                    // 服务端忽略了我们带 Range 的请求、直接把整份发回来 → 只能从头再来
                    try? fm.removeItem(at: options.partURL)
                    fm.createFile(atPath: options.partURL.path, contents: nil)
                    done = 0
                } else if code != 206 && code != 200 {
                    throw Fail.badStatus(code)
                }
                guard !data.isEmpty else { break }

                do {
                    let fh = try FileHandle(forWritingTo: options.partURL)
                    try fh.seekToEnd()
                    try fh.write(contentsOf: data)
                    try fh.close()
                } catch {
                    if Self.isNoSpace(error) { throw Fail.noSpace }
                    throw error
                }

                done += Int64(data.count)
                onProgress(done, total)
                if total > 0 && done >= total { break }
                if data.count < Int(chunk) { break }     // 最后一段
            }
        } else {
            // ★★ v1.0.101（会诊两家都点了这条，属"必崩点"）：
            //   服务端不支持分段时，**绝不能把整份文件读进内存** ——
            //   原来这里是 data(for:) 拿到整份再 write(.atomic)，1GB 的片子就是 1GB 内存。
            //   改成 download(for:)：由系统流式落到临时文件，内存只占缓冲区。
            //   代价：.part 里已有的字节作废（服务端不给 Range，本来也接不上）。
            if done > 0 {
                try? fm.removeItem(at: options.partURL)
                done = 0
                fm.createFile(atPath: options.partURL.path, contents: nil)
            }
            let (tmp, resp) = try await Self.session.download(for: request(for: url))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { throw Fail.badStatus(code) }
            // download(for:) 给的临时文件在回调返回后会被系统删掉 → 必须立刻挪走
            try? fm.removeItem(at: options.partURL)
            do {
                try fm.moveItem(at: tmp, to: options.partURL)
            } catch {
                if Self.isNoSpace(error) { throw Fail.noSpace }
                throw error
            }
            let sz = (try? fm.attributesOfItem(atPath: options.partURL.path)[.size] as? Int64) ?? 0
            done = sz
            onProgress(done, total)
        }

        guard done > 0 else { throw Fail.empty }
        if fm.fileExists(atPath: options.outputURL.path) {
            try? fm.removeItem(at: options.outputURL)
        }
        try fm.moveItem(at: options.partURL, to: options.outputURL)
        return done
    }

    private func request(for url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: options.timeout)
        r.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        if let ref = options.referer, !ref.isEmpty {
            r.setValue(ref, forHTTPHeaderField: "Referer")
        }
        if let ck = options.cookie, !ck.isEmpty {
            r.setValue(ck, forHTTPHeaderField: "Cookie")
        }
        return r
    }
}
