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
        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "服务器返回 HTTP \(c)"
            case .empty: return "服务器返回了空内容"
            }
        }
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
                let (data, resp) = try await URLSession.shared.data(for: req)
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

                let fh = try FileHandle(forWritingTo: options.partURL)
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
                try fh.close()

                done += Int64(data.count)
                onProgress(done, total)
                if total > 0 && done >= total { break }
                if data.count < Int(chunk) { break }     // 最后一段
            }
        } else {
            let (data, resp) = try await URLSession.shared.data(for: request(for: url))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { throw Fail.badStatus(code) }
            guard !data.isEmpty else { throw Fail.empty }
            try data.write(to: options.partURL, options: .atomic)
            done = Int64(data.count)
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
