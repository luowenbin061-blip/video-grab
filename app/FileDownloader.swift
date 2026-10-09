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

        // ★ v1.0.260：总长**优先用调用方传的**；没传（=0）就从响应头自取 ——
        //   Range 段（206）的 `Content-Range: bytes X-Y/总长` 自带总长、200 用
        //   expectedContentLength。以前 total=0 时调用方算不出比例，进度条永远不动
        //   （用户实测"工具箱直解下载一直显示 1%"的根因之一）。
        var total = options.expectedLength
        // ★ 这里**故意**是固定的 16MB 段，别再改成"自适应小段"。
        //   2026-09-27 试过 v1.0.114：段长 = 总长/10（夹 1MB~16MB），
        //   好处是小文件也能看到进度（16MB 一段时，<16MB 的文件全程只有 1 次回调）；
        //   **代价是每多一段要多花一次往返**（请求→首字节），中小文件会慢零点几秒
        //   → 用户权衡后选择**保留 v1.0.113 的固定 16MB**，放弃那次优化。
        //   大文件的段数两种方案完全一样（都是 16MB 一段），所以只影响中小文件。
        let chunk: Int64 = 16 * 1024 * 1024

        if options.acceptsRange {
            while true {
                let start = done
                var req = request(for: url)
                req.setValue("bytes=\(start)-\(start + chunk - 1)", forHTTPHeaderField: "Range")
                // ★ v1.0.260：流式收数据时把"空闲超时"放宽（DP 审查建议）——
                //   30s 的 resource 超时对"等下一个数据包"太紧，CDN 首字节慢会被切。
                req.timeoutInterval = 90
                let (stream, resp) = try await Self.session.bytes(for: req)
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0

                if code == 200 && start > 0 {
                    // 服务端忽略了我们带 Range 的请求、直接把整份发回来 → 只能从头再来
                    try? fm.removeItem(at: options.partURL)
                    fm.createFile(atPath: options.partURL.path, contents: nil)
                    done = 0
                } else if code != 206 && code != 200 {
                    throw Fail.badStatus(code)
                }
                // ★ v1.0.260：响应头自取总长（容错：解析不出就保持 0，绝不给假总长）
                if total <= 0, let http {
                    if code == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let slash = cr.range(of: "/"),
                       let t = Int64(cr[slash.upperBound...].trimmingCharacters(in: .whitespaces)) {
                        total = t
                    } else if code == 200 {
                        // ★ expectedContentLength 是**非可选 Int64**（未知时 -1，不能 let 绑定）
                        let t = http.expectedContentLength
                        if t > 0 { total = t }
                    }
                }

                // ★★ v1.0.260：**流式收 + 批量落盘** —— 以前 `data(for:)` 要等整段
                //   16MB 到齐才返回、才回调一次进度（快网 3-5 秒一跳、慢网几十秒一跳，
                //   用户看到的就是"不动了"）。现在边收边写、每 256KB 报一次。
                //   断点语义不变：.part 追加写；服务端截断（segGot < 期望段长）且
                //   总长未到 → 不退出，循环里接着 Range 拉（原来直接 break 会把
                //   不完整的文件当成功）。
                let fh = try FileHandle(forWritingTo: options.partURL)
                try fh.seekToEnd()
                var buf = Data()
                buf.reserveCapacity(256 * 1024)
                let segStart = done
                do {
                    for try await b in stream {
                        try Task.checkCancellation()      // ★ v1.0.260：AsyncBytes 的取消传播有缺陷，显式检查
                        buf.append(b)
                        if buf.count >= 256 * 1024 {
                            try fh.write(contentsOf: buf)
                            done += Int64(buf.count)
                            buf.removeAll(keepingCapacity: true)
                            onProgress(done, total)
                        }
                    }
                    if !buf.isEmpty {
                        try fh.write(contentsOf: buf)
                        done += Int64(buf.count)
                        onProgress(done, total)
                    }
                    try fh.close()
                } catch {
                    try? fh.close()
                    if Self.isNoSpace(error) { throw Fail.noSpace }
                    throw error
                }

                if total > 0 && done >= total { break }
                let segGot = done - segStart
                if segGot == 0 { break }                  // ★ 服务端这次一个字节都没给（原 data 版的空段防护，别死循环）
                if code == 200 { break }                  // 服务端不支持 Range，这份就是完整的
                if total <= 0 && segGot < chunk { break } // 没总长时，段没拉满 = 最后一段
                // 总长已知但段没拉满 → 服务端截断，循环继续接着拉
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
            // ★ v1.0.260：这条退路也顺手把总长补上（一致性；虽然此刻下载已完成）
            if total <= 0, let t = (resp as? HTTPURLResponse)?.expectedContentLength, t > 0 {
                total = t
            }
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
