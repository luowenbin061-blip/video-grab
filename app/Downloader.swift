import CommonCrypto
import Foundation

/// 下载 + 拼接 + 导出。纯 URLSession，无第三方依赖。
///
/// 设计要点（来自审查意见）：
///  · 分片不能全塞内存：694 个 × 约 700KB ≈ 460MB。所以下载时逐个落到临时目录，
///    拼接时按顺序「读一个 → 追加写 → 删一个」，峰值磁盘占用约等于成品大小。
///  · 后台不可靠：iOS 侧 beginBackgroundTask 只有约 30 秒，TrollStore 侧载又没有真实
///    provisioning profile，URLSession 的 background session 回调没保证。所以这里
///    不依赖后台，而是把「已下好的分片文件」当作断点，支持再次启动时跳过。
///  · 支持 AES-128-CBC 解密（CryptoKit 不做 CBC，用 CommonCrypto）。
struct HLSDownloader {

    struct Options {
        var concurrency = 4
        var timeout: TimeInterval = 20
        var retry = 2
        var userAgent: String
        var referer: String?
        /// 分片临时目录
        var tempDir: URL
        /// 最终产物
        var outputURL: URL
        /// Cookie —— 防盗链/需登录的站要带；取 AES key 的请求也用它
        var cookie: String? = nil
    }

    enum Fail: LocalizedError {
        case badStatus(Int, String)
        case noVariant
        case noSegment
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .badStatus(let c, let u): return "HTTP \(c)：\(u)"
            case .noVariant: return "这是 master 列表，但里面没有可用的清晰度"
            case .noSegment: return "m3u8 里没有解析出任何分片"
            case .decryptFailed: return "分片解密失败（AES-128）"
            }
        }
    }

    let options: Options
    /// (已完成, 总数, 阶段文字)
    var onProgress: (Int, Int, String) -> Void = { _, _, _ in }

    /// 下载产物。除了文件本身，还带出时长和分片数 ——
    /// 时长要用来写一条只含单个分片的 m3u8（播放器需要 #EXTINF）。
    struct Output {
        let fileURL: URL
        let duration: Double
        let segmentCount: Int
    }

    // MARK: - 主流程

    func run(sourceURL: URL) async throws -> Output {
        try FileManager.default.createDirectory(at: options.tempDir,
                                                withIntermediateDirectories: true)

        onProgress(0, 0, "读取 m3u8…")
        let first = try await loadPlaylist(url: sourceURL)

        // ★ 关键：master playlist 不含分片，必须先挑一个清晰度再取子列表。
        // 这里用 let 而不是 var —— 下面的并发闭包要捕获它，
        // 捕获 var 在并发代码里会报 "reference to captured var"。
        let playlist: M3U8Playlist
        if first.isMaster {
            guard let v = first.bestVariant() else { throw Fail.noVariant }
            let label = v.resolution ?? (v.bandwidth.map { "\($0 / 1000)kbps" } ?? "默认清晰度")
            onProgress(0, 0, "选中清晰度 \(label)，读取分片列表…")
            playlist = try await loadPlaylist(url: v.url)
        } else {
            playlist = first
        }

        guard !playlist.segmentURLs.isEmpty else { throw Fail.noSegment }
        let segs = playlist.segmentURLs
        let total = segs.count

        // 1) 并发下载（已存在的分片文件直接跳过 = 天然断点续传）
        var done = 0
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            var inflight = 0
            let limit = max(1, options.concurrency)

            func addTask(_ i: Int) {
                group.addTask {
                    do {
                        try await downloadSegment(index: i,
                                                  url: segs[i],
                                                  playlist: playlist)
                        return true
                    } catch {
                        return false
                    }
                }
                inflight += 1
            }

            while next < total && inflight < limit {
                addTask(next); next += 1
            }
            while let ok = await group.next() {
                inflight -= 1
                if !ok {
                    group.cancelAll()
                    break
                }
                done += 1
                onProgress(done, total, "下载分片 \(done)/\(total)")
                if next < total { addTask(next); next += 1 }
            }
        }

        guard done == total else {
            throw Fail.badStatus(0, "有 \(total - done) 个分片没下完，已保留已下载的部分，可再点一次继续")
        }

        // 2) 按顺序拼接（边拼边删，控制磁盘占用）
        onProgress(total, total, "正在拼接…")
        let fm = FileManager.default
        if fm.fileExists(atPath: options.outputURL.path) {
            try? fm.removeItem(at: options.outputURL)
        }
        fm.createFile(atPath: options.outputURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: options.outputURL)

        // 一个 key 只拉一次。整条清单共用同一个 key，
        // 逐分片去拉的话 694 个分片就是 694 次多余请求（还容易被判定为异常流量）。
        var keyCache: [URL: Data] = [:]
        for (i, _) in segs.enumerated() {
            let part = partURL(i)
            guard let data = try? Data(contentsOf: part) else { continue }
            let payload = try await decodeIfNeeded(data: data, playlist: playlist, index: i,
                                                   keyCache: &keyCache)
            out.write(payload)
            try? fm.removeItem(at: part)
            if i % 25 == 0 {
                onProgress(total, total, "拼接 \(i + 1)/\(total)")
            }
        }
        try? out.close()

        try? fm.removeItem(at: options.tempDir)
        onProgress(total, total, "完成")
        return Output(fileURL: options.outputURL,
                      duration: playlist.totalDuration,
                      segmentCount: total)
    }

    // MARK: - 网络

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

    /// 取 m3u8 文本。返回 (文本, 最终地址) —— 最终地址要作为相对路径的基准。
    private func loadPlaylist(url: URL) async throws -> M3U8Playlist {
        let (data, resp) = try await URLSession.shared.data(for: request(for: url))
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw Fail.badStatus(h.statusCode, url.absoluteString)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        let finalURL = resp.url ?? url
        return M3U8Playlist.parse(text: text, baseURL: finalURL)
    }

    private func partURL(_ i: Int) -> URL {
        options.tempDir.appendingPathComponent(String(format: "seg_%06d.part", i))
    }

    private func downloadSegment(index: Int, url: URL, playlist: M3U8Playlist) async throws {
        let dest = partURL(index)
        // 已经下过就跳过（断点续传 / 重复点击不重下）
        if let sz = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, sz > 0 {
            return
        }
        var lastErr: Error?
        for attempt in 0...options.retry {
            do {
                let (data, resp) = try await URLSession.shared.data(for: request(for: url))
                if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                    throw Fail.badStatus(h.statusCode, url.lastPathComponent)
                }
                guard !data.isEmpty else { throw Fail.badStatus(0, "空响应") }
                try data.write(to: dest, options: .atomic)
                return
            } catch {
                lastErr = error
                if attempt < options.retry {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastErr ?? Fail.badStatus(0, "下载失败")
    }

    // MARK: - 解密（只有 AES-128 需要）

    private func decodeIfNeeded(data: Data, playlist: M3U8Playlist, index: Int,
                                keyCache: inout [URL: Data]) async throws -> Data {
        guard let key = playlist.key,
              key.method.uppercased() == "AES-128",
              let keyURI = key.uri else {
            return data   // 明文，直接返回
        }

        // 取 key 走 async —— 不要在 async 上下文里用信号量阻塞，容易死锁。
        let kRaw: Data
        if let cached = keyCache[keyURI] {
            kRaw = cached
        } else {
            let (d, resp) = try await URLSession.shared.data(for: request(for: keyURI))
            if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                throw Fail.decryptFailed
            }
            guard d.count >= 16 else { throw Fail.decryptFailed }
            keyCache[keyURI] = d
            kRaw = d
        }

        // IV：清单里写了就用它；没写的话规范规定用「该分片的媒体序号」——
        // 是 #EXT-X-MEDIA-SEQUENCE + 分片下标，不是下标本身。转 16 字节大端。
        var iv: Data
        if let explicit = key.iv {
            iv = explicit
        } else {
            var be = UInt32(playlist.mediaSequence + index).bigEndian
            iv = Data(count: 16)
            withUnsafeBytes(of: &be) { iv.replaceSubrange(12..<16, with: $0) }
        }

        return try Self.aes128CBCDecrypt(data: data,
                                        key: Data(kRaw.prefix(16)),
                                        iv: Data(iv.prefix(16)))
    }

    /// CryptoKit 只提供 AES.GCM / ChaChaPoly，不提供 AES-CBC，所以走 CommonCrypto。
    static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let status: CCCryptorStatus = key.withUnsafeBytes { (kp: UnsafeRawBufferPointer) -> CCCryptorStatus in
            iv.withUnsafeBytes { (ip: UnsafeRawBufferPointer) -> CCCryptorStatus in
                data.withUnsafeBytes { (dp: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    out.withUnsafeMutableBytes { (op: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
                        guard let k = kp.baseAddress,
                              let i = ip.baseAddress,
                              let d = dp.baseAddress,
                              let o = op.baseAddress else {
                            return CCCryptorStatus(kCCMemoryFailure)
                        }
                        return CCCrypt(CCOperation(kCCDecrypt),
                                       CCAlgorithm(kCCAlgorithmAES),
                                       CCOptions(kCCOptionPKCS7Padding),
                                       k, kCCKeySizeAES128,
                                       i,
                                       d, data.count,
                                       o, op.count,
                                       &moved)
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw Fail.decryptFailed }
        return out.prefix(moved)
    }
}
