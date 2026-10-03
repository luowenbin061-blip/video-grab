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
/// 分片/钥匙的文件命名 —— **只在这里定义一份**（下载器与边下边播都取这里的）。
///
/// ★★ v1.0.141：后缀从 `.part` 改成 `.ts`。为什么必须改（**本机跑真 ffmpeg 实测出来的，不是猜**）：
///   FFmpeg 的 hls 解复用器有一份「允许的分片后缀」白名单，另外对**钥匙**还有协议白名单
///   （只允许 `file/crypto/data`）。实测三种组合：
///     · 分片 `.ts` + 钥匙走 http              → ❌ `Protocol 'http' not on whitelist 'file,crypto,data'`
///     · 分片 `.ts` + 钥匙 `.part`（本地）      → ❌ `.part` 不在文件后缀白名单
///     · **分片和钥匙都叫 `.ts`、清单放同目录用相对名** → ✅ 通过（退出码 0、轨齐全、38.96 秒）
///   所以统一用 `.ts` —— 这也是**在老版本 ffmpeg 上同样安全**的写法（新版的白名单在老版里不存在）。
///   而**升级前已经下好的 `.part` 分片仍然认**（见 `oldSegment`），不会让它们白下。
enum DLName {
    /// 现在的分片名
    static func segment(_ i: Int) -> String { String(format: "seg_%06d.ts", i) }
    /// 升级前的老分片名（只在"读"的时候兜底找它）
    static func oldSegment(_ i: Int) -> String { String(format: "seg_%06d.part", i) }
    /// 本地钥匙文件名（同样 `.ts` 后缀 —— 原因见上面实测）
    static func key(_ n: Int) -> String { String(format: "key_%d.ts", n) }
    /// 本地清单名：**放在分片同目录**，里面的地址写相对名
    static let playlist = "local.m3u8"
}

struct HLSDownloader {

    struct Options {
        /// v1.0.101：4 → 6。两家会诊一致建议 6
        ///（8 会被部分 CDN 判异常流量 / 触发挑战页）。
        var concurrency = 6
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
        case noSegment(String)
        /// ★ v1.0.134：清单里有分片行，但**每一行都解析不出地址**。
        ///   以前这种情况会走到 noSegment，报出"没有解析出任何分片"——
        ///   看着像"清单是空的"，其实清单里有东西，是我们读不懂它的地址。
        ///   分开报，用户和排查都能一眼看出是哪一类。
        case noAddress(String, [String])
        case decryptFailed
        case unsupported(String)
        /// ★ v1.0.140：拼接时发现**分片文件不见了**（下载过了但磁盘上没了）。
        ///   旧代码遇到这种情况是 `continue` **静默跳过**，然后产出一个残缺的 .ts，
        ///   还因为"成品大小 == 写入字节数"（两个同源的数）被判成"拼接校验通过"——
        ///   于是坏文件被当成成功（2026-09-28 外部审查指出，已核实）。
        case missingSegment([Int])
        /// ★ v1.0.140：分片内容**看着就不对**（例如回的是错误页、或者长度对不上）。
        ///   以前只要 HTTP 2xx + 非空就落盘，服务器给个 200 的错误页也会被当成分片。
        case badContent(Int, String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let c, let u): return "HTTP \(c)：\(u)"
            case .noVariant: return "这是 master 列表，但里面没有可用的清晰度"
            case .noSegment(let head):
                return "m3u8 里没有解析出任何分片"
                    + (head.isEmpty ? "" : " —— 取回内容开头：\(head)")
            case .noAddress(let head, let bad):
                // 说清"清单里其实有分片，是地址读不懂"——比笼统一句"没解析出分片"有用得多
                var s = "这份清单里的分片地址读不懂（\(bad.count) 条）"
                s += bad.isEmpty ? "" : " —— 例如：\(bad[0])"
                if !head.isEmpty { s += "\n取回内容开头：\(head)" }
                return s
            case .decryptFailed: return "分片解密失败（AES-128）"
            case .unsupported(let why):
                // ★ 宁可诚实地失败，也不产出「打不开但显示成功」的残缺文件
                return "这种视频暂时下不了：\(why)。"
                    + "硬拼只会得到一个打不开的残缺文件，所以这次直接停下（不浪费你流量）。"
            case .missingSegment(let list):
                let head = list.prefix(5).map(String.init).joined(separator: "、")
                return "有 \(list.count) 个分片在磁盘上不见了（第 \(head) 个…）。"
                    + "没有硬拼成残缺文件 —— 已下载的分片都保留着，再点一次「重试」会只补这几个。"
            case .badContent(let i, let why):
                return "第 \(i) 个分片的内容不对（\(why)）。"
                    + "多半是服务器当时回了一个错误页/被拦了，再点一次「重试」通常就好。"
            }
        }
    }

    let options: Options

    /// 下载进行到哪个阶段 —— 界面的「总百分比」按阶段加权（下载是大头，
    /// 拼接/转码都是秒级）。转码那一档由 DownloadJob 自己接 FFmpeg 的回调。
    enum Stage { case prepare, download, join, convert, finished }

    /// 一次进度上报。done/total 是**本阶段内**的计数（下载=分片数、拼接=分片数）；
    /// bytes 是累计已下载字节数（算 MB/s 用，拿分片个数换算是糊弄人）。
    struct Progress {
        let stage: Stage
        let done: Int
        let total: Int
        let bytes: Int64
        let message: String
    }

    var onProgress: (Progress) -> Void = { _ in }

    /// 下载产物。除了文件本身，还带出时长和分片数 ——
    /// 时长要用来写一条只含单个分片的 m3u8（播放器需要 #EXTINF）。
    struct Output {
        let fileURL: URL
        let duration: Double
        let segmentCount: Int
        /// ★ v1.0.101：拼接时**实际写进成品**的字节数（AES 解密后的量）。
        /// 拿它和成品大小对比，才敢断定"拼接真的成功了"—— 会诊两家都指出
        /// 光靠分片个数 / 名义大小不可靠（半文件也可能凑巧对上）。
        let joinedBytes: Int64
        /// ★ v1.0.140：拼接时**真的写进成品的分片个数**。
        ///   为什么还要它：`joinedBytes` 和成品大小是**同源**的（都是"我们刚写了多少"），
        ///   拿它们互相比是**自洽校验** —— 缺了分片也照样相等，什么都发现不了。
        ///   现在缺分片会直接抛错，DownloadJob 还会再核对一次
        ///   "写入个数 == 期望个数"，**两处独立计数**才算真的对上。
        let writtenSegments: Int
        /// ★ v1.0.141：`skipJoin` 模式下把清单带回去 —— 调用方要靠它（含 `rawText` 原文）
        /// 生成"喂给 ffmpeg 的本地清单"。正常模式为 nil。
        let playlist: M3U8Playlist?
    }

    // MARK: - 主流程

    /// 跑一次。
    ///
    /// ★★ `skipJoin` **必须是参数、不能是 `Options` 的字段**（v1.0.142 踩过这个坑）：
    ///   调用方是 `var opt = Options(...)` → `var dl = HLSDownloader(options: opt)` → 再改 `opt.xxx`。
    ///   而 `Options` 是 **struct**，构造时已经**复制了一份**进 `dl`；
    ///   构造之后再改 `opt` 里的字段，**`dl` 手里那份完全不受影响**（静默不生效）。
    ///   run #142 的真机日志就是这么废的：拼接照旧跑了 → 只用了最后一把钥匙 → 成品 1%，
    ///   而且老路返回的清单是 nil → 新路拿到空清单自己放弃。
    ///   做成参数就没有"哪份副本"的问题了。
    func run(sourceURL: URL, skipJoin: Bool = false) async throws -> Output {
        try FileManager.default.createDirectory(at: options.tempDir,
                                                withIntermediateDirectories: true)

        onProgress(Progress(stage: .prepare, done: 0, total: 0, bytes: 0, message: "读取 m3u8…"))
        let firstLoad = try await loadPlaylist(url: sourceURL)
        let first = firstLoad.playlist
        // 取回内容的开头（诊断用）
        var head = firstLoad.head

        // ★ 关键：master playlist 不含分片，必须先挑一个清晰度再取子列表。
        // 这里用 let 而不是 var —— 下面的并发闭包要捕获它，
        // 捕获 var 在并发代码里会报 "reference to captured var"。
        let playlist: M3U8Playlist
        if first.isMaster {
            guard let v = first.bestVariant() else { throw Fail.noVariant }
            let label = v.resolution ?? (v.bandwidth.map { "\($0 / 1000)kbps" } ?? "默认清晰度")
            onProgress(Progress(stage: .prepare, done: 0, total: 0, bytes: 0,
                                message: "选中清晰度 \(label)，读取分片列表…"))
            let vLoad = try await loadPlaylist(url: v.url)
            playlist = vLoad.playlist
            head = vLoad.head
        } else {
            playlist = first
        }

        // ★ 先看这份清单有没有我们拼不出来的写法 —— 有就**现在**停下并说清楚。
        //   以前这些标签被当成「看不懂就跳过」，结果是硬拼出一个缺了开头、播不了的
        //   残缺文件，界面上还显示「下载成功」。产出坏文件却报成功，比直接失败恶劣得多。
        if let why = playlist.unsupportedReason { throw Fail.unsupported(why) }

        // ★ v1.0.134：分清两种"没分片"——
        //   ① 清单里**本来就没有**分片行 → noSegment（清单确实是空的，多半给错了地址）
        //   ② 清单里**有分片行，但地址全读不懂** → noAddress（能指名道姓说是哪条）
        //   以前两种情况都报"没有解析出任何分片"，第二种的真正原因（地址读不懂）被埋掉了。
        guard !playlist.segmentURLs.isEmpty else {
            if !playlist.badAddressLines.isEmpty {
                throw Fail.noAddress(head, playlist.badAddressLines)
            }
            throw Fail.noSegment(head)
        }
        let segs = playlist.segmentURLs
        let total = segs.count

        // ★ v1.0.133：分片时长**先落一份盘**（边下边播现场生成清单时要读，见上面那段说明）。
        //   放在"格式检查通过"之后、"开始下载"之前 —— 早于第一个分片落盘，
        //   所以边下边播那份清单从一开始就能算出像样的总时长。
        writeSegmentDurations(playlist.segmentDurations, dir: options.tempDir)

        // 1) 并发下载（已存在的分片文件直接跳过 = 天然断点续传）
        var done = 0
        var bytesDone: Int64 = 0
        await withTaskGroup(of: Int64?.self) { group in
            var next = 0
            var inflight = 0
            let limit = max(1, options.concurrency)

            func addTask(_ i: Int) {
                group.addTask {
                    do {
                        // 返回本次新下载的字节数 —— 界面的 MB/s 用真实字节算
                        return try await downloadSegment(index: i,
                                                         url: segs[i],
                                                         playlist: playlist)
                    } catch {
                        return nil
                    }
                }
                inflight += 1
            }

            while next < total && inflight < limit {
                addTask(next); next += 1
            }
            while let n = await group.next() {
                inflight -= 1
                guard let n else {
                    group.cancelAll()
                    break
                }
                done += 1
                bytesDone += n
                onProgress(Progress(stage: .download, done: done, total: total,
                                    bytes: bytesDone,
                                    message: "下载分片 \(done)/\(total)"))
                if next < total { addTask(next); next += 1 }
            }
        }

        guard done == total else {
            throw Fail.badStatus(0, "有 \(total - done) 个分片没下完，已保留已下载的部分，可再点一次继续")
        }

        // ★ v1.0.141：只要分片（新的主路径）——**不解密、不拼接**，把清单带回去交给 ffmpeg。
        //   分片本来就是**密文原样落盘**的（解密一直发生在拼接阶段），所以这里天然就是
        //   "我已经把要的东西搬下来了"，ffmpeg 拿到清单+钥匙就能自己拼。
        if skipJoin {
            onProgress(Progress(stage: .finished, done: total, total: total,
                                bytes: bytesDone, message: "分片已下齐"))
            return Output(fileURL: options.outputURL,
                          duration: playlist.totalDuration,
                          segmentCount: total,
                          joinedBytes: 0,
                          writtenSegments: 0,
                          playlist: playlist)
        }

        // 2) 按顺序拼接
        //
        // ★ v1.0.89：**不再边拼边删分片**。
        //   原因（用户报的真问题）：以前拼完一个分片就删一个，最后还删掉整个临时目录 ——
        //   于是**一旦崩在"拼接之后 / 转码途中"（正是最容易崩的环节），续传的底料
        //   已经被程序自己删光了** → 用户点「重试」只能从零重下几百 MB。
        //   现在分片一律留到**整条流程（含转码）成功之后**，由 DownloadJob 统一清理。
        //   代价：峰值磁盘占用约 2 倍（分片 + 成品同时存在）——
        //   换来的是"崩了重试 = 重新拼接十几秒"，而不是"重下一遍"。
        onProgress(Progress(stage: .join, done: 0, total: total, bytes: bytesDone, message: "正在拼接…"))
        let fm = FileManager.default
        if fm.fileExists(atPath: options.outputURL.path) {
            try? fm.removeItem(at: options.outputURL)
        }
        fm.createFile(atPath: options.outputURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: options.outputURL)

        // 一个 key 只拉一次。整条清单共用同一个 key，
        // 逐分片去拉的话 694 个分片就是 694 次多余请求（还容易被判定为异常流量）。
        var keyCache: [URL: Data] = [:]
        var written: Int64 = 0          // ★ v1.0.101：写进成品的真实字节数
        var writtenCount = 0            // ★ v1.0.140：真的写进成品的分片个数
        var missing: [Int] = []         // ★ v1.0.140：拼接时发现磁盘上不见了的分片
        for (i, _) in segs.enumerated() {
            let part = partURL(i)
            // ★★ v1.0.140：这里以前是 `else { continue }` —— 缺分片被**静默跳过**，
            //   然后成品照样被当成"拼接校验通过"（见 Output.writtenSegments 的说明）。
            //   现在先记下来，循环完**明确报错**：宁可失败，也不能给你一个
            //   "能播但缺一段"的文件、还让你以为成功了。
            //   已下载的分片全部保留 → 点「重试」只会补缺的那几个。
            // ★★ v1.0.204（代码体检 P3）：**明文分片改成流式拼**（分块读 → 分块写），
            //   不再 `Data(contentsOf:)` 把整个分片读进内存 —— 遇到 20MB+ 的大分片时，
            //   拼接这一步会瞬时占双份内存（下载侧 v1.0.199 已经改成流式了，这里漏了）。
            //   ★ 加密分片（AES-128）保持整段读：CBC 解密必须按整段算，那条路少见、不折腾。
            let needDecrypt = (playlist.key?.method.uppercased() == "AES-128")
            if needDecrypt {
                guard let data = try? Data(contentsOf: part) else {
                    missing.append(i)
                    continue
                }
                // ★★ v1.0.195（AI 审查 P0）：这一段以前有两个坑 ——
                //   ① `out.write` 是**不抛错**的版本：磁盘满时静默少写，坏文件照样标"成功"；
                //   ② decode 抛错时整段直接 throw 出去：句柄没关、残缺的 .ts 留在盘上。
                //   现在：写入换成会抛错的 `write(contentsOf:)`；本段包 do/catch，
                //   出错先关句柄、删残件，再把错误抛回去（宁可失败，也不给"看似成功"的坏文件）。
                do {
                    let payload = try await decodeIfNeeded(data: data, playlist: playlist, index: i,
                                                           keyCache: &keyCache)
                    try out.write(contentsOf: payload)
                    written += Int64(payload.count)
                    writtenCount += 1
                } catch {
                    try? out.close()
                    try? fm.removeItem(at: options.outputURL)
                    throw error
                }
            } else {
                guard let inFH = try? FileHandle(forReadingFrom: part) else {
                    missing.append(i)
                    continue
                }
                do {
                    while true {
                        let chunk = try inFH.read(upToCount: 1 << 18) ?? Data()   // 256 KB 一块
                        if chunk.isEmpty { break }
                        try out.write(contentsOf: chunk)
                        written += Int64(chunk.count)
                    }
                    try? inFH.close()
                    writtenCount += 1
                } catch {
                    try? inFH.close()
                    try? out.close()
                    try? fm.removeItem(at: options.outputURL)
                    throw error
                }
            }
            // 分片**故意不删** —— 见上面那段说明（v1.0.89）。
            // v1.0.101：改由 DownloadJob 在「拼接校验通过」之后立刻清（不再等转码成功），
            // 所以磁盘 2× 只存在于拼接这一小段，而不是整段转码期间。
            if i % 25 == 0 {
                onProgress(Progress(stage: .join, done: i + 1, total: total,
                                    bytes: bytesDone, message: "拼接 \(i + 1)/\(total)"))
            }
        }
        try? out.close()

        // ★ v1.0.140：缺分片 → **明确失败**，并且**不留下**那个残缺的 .ts。
        //   （留着它会被后面的逻辑当成"上次已经拼好了"→ 永远跳过重下。）
        if !missing.isEmpty {
            try? fm.removeItem(at: options.outputURL)
            throw Fail.missingSegment(missing)
        }

        // ★ 临时目录也**不在这里删** —— 留给 DownloadJob 在"转码也成功"之后统一清。
        //   （以前这里删掉，等于把续传底料在最后一步销毁。）
        onProgress(Progress(stage: .finished, done: total, total: total, bytes: bytesDone, message: "完成"))
        return Output(fileURL: options.outputURL,
                      duration: playlist.totalDuration,
                      segmentCount: total,
                      joinedBytes: written,
                      writtenSegments: writtenCount,
                      playlist: nil)
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

    /// 取回来的一份清单 + 它的开头（开头留着做诊断）
    private struct Loaded {
        let playlist: M3U8Playlist
        let head: String
    }

    /// GB18030（GBK 的超集）—— **中文站的 m3u8 很常是这种编码**。
    /// Foundation 的 `String.Encoding` 没有内置 GBK 常量，得绕一圈 CoreFoundation 拿编码号。
    /// （`BookmarkImporter.decode` 里已经这么用过一次，同一套写法。）
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// 取 m3u8 文本。最终地址要作为相对路径的基准。
    private func loadPlaylist(url: URL) async throws -> Loaded {
        let (data, resp) = try await URLSession.shared.data(for: request(for: url))
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw Fail.badStatus(h.statusCode, url.absoluteString)
        }
        // ★ v1.0.136：文本解码要**给中文站兜底**（跟 v1.0.134 修中文分片地址是同一条线上的事）。
        //
        // 以前是 `utf8 ?? isoLatin1`。isoLatin1 的坏处不是"失败"，而是**悄悄把字节搞错**：
        //   GBK 的 `牛` = 字节 `C5 A3` → isoLatin1 读成 "Å£" 两个字符 →
        //   再经 `sanitizeURLString` 编码时，每个字符又展开成 **2 个 UTF-8 字节**
        //   （`Å` = U+00C5 → `%C3%85`）→ 分片地址整体错位 → 必然 404，
        //   而且报出来像"站上没有这个文件"，完全看不出是编码错了。
        // 所以中间先插一层 GB18030，兜底才落到 isoLatin1（永不失败）。
        let text: String
        let wasUTF8: Bool
        if let u = String(data: data, encoding: .utf8) {
            text = u; wasUTF8 = true
        } else if let g = String(data: data, encoding: Self.gb18030) {
            text = g; wasUTF8 = false
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
            wasUTF8 = false
        }
        let finalURL = resp.url ?? url
        // 记下开头：万一一个分片都没解析出来，把这句带进错误里，
        // 立刻能看出取回的是清单、还是一个跳转页/HTML 错误页
        var head = String(text.prefix(160))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // ★ v1.0.136：不是 UTF-8 就**明说**。以后看到这句就知道分片地址是按 GB18030 解出来的，
        //   省掉"到底是编码还是防盗链"的一轮猜。
        if !wasUTF8 { head = "[这份清单不是 UTF-8，已按 GB18030 读] " + head }
        return Loaded(playlist: M3U8Playlist.parse(text: text, baseURL: finalURL), head: head)
    }

    private func partURL(_ i: Int) -> URL {
        options.tempDir.appendingPathComponent(DLName.segment(i))
    }

    private func oldPartURL(_ i: Int) -> URL {
        options.tempDir.appendingPathComponent(DLName.oldSegment(i))
    }

    /// ★ v1.0.133：把每个分片的**真实时长**落盘（一行一个，按分片序号）。
    ///
    /// 为什么需要：边下边播要在播放中途现场生成清单，可那时手边只有磁盘上的分片文件，
    /// 原始清单对象早就不在了 —— 于是以前只能把 `#EXTINF` 写成固定 10.0 秒，
    /// 播放器算出来的总时长自然是错的（用户报的「看不到视频时长」）。
    /// 单个分片文件的长度**没法反推时长**（TS 里没有时长字段，字节数跟时长不成正比），
    /// 所以只能在下的时候顺手记一份。
    ///
    /// 格式极简：每行 `<秒>`（下标 = 行号 = 分片序号）。缺行 = 那个分片还没下完。
    /// 写完就没什么用了 —— `DownloadJob` 在任务结束清临时目录时会一起清掉。
    private func writeSegmentDurations(_ durs: [Double], dir: URL) {
        guard !durs.isEmpty else { return }
        let text = durs.map { $0.isFinite ? String(format: "%.3f", $0) : "0" }
                      .joined(separator: "\n")
        try? Data(text.utf8).write(to: dir.appendingPathComponent(Self.durationsFileName),
                                   options: .atomic)
    }

    /// 时长旁注文件名（`LivePreview` 读它，两处名字必须一致）
    static let durationsFileName = "durations.txt"

    /// 下载单个分片。返回**本次新下载**的字节数（续传跳过的返回 0）。
    /// 分片的"完成标记"：内容 = 该分片落盘的字节数。
    ///
    /// ★★ v1.0.140：断点续传以前只看"文件存在且 >0 字节"——
    ///   服务器**只要给过一次短响应**，那个半截文件就会被永久当成完整分片，
    ///   以后每次重试都带着它 → 永远失败（2026-09-28 外部审查指出，我逐行核实成立）。
    ///   现在：下载成功就顺手写一个标记；续传时**标记不在、或者对不上**就重下。
    private func doneMarkerURL(_ index: Int) -> URL {
        partURL(index).appendingPathExtension("ok")
    }

    private func downloadSegment(index: Int, url: URL, playlist: M3U8Playlist) async throws -> Int64 {
        let dest = partURL(index)
        // ★ v1.0.141：老任务的分片还叫 `.part` —— 见到就地**改名**成新的 `.ts`
        //   （否则后面"生成本地清单"按新名去找会找不到，等于白下）。只做一次，零成本。
        let old = oldPartURL(index)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dest)
            try? fm.moveItem(at: old.appendingPathExtension("ok"),
                             to: dest.appendingPathExtension("ok"))
        }
        // 已经下过就跳过（断点续传 / 重复点击不重下）。
        // ★ v1.0.140：判据从"文件存在"升级成"**标记存在且字节数对得上**"。
        //   兼容处理：没有标记的**老文件**（升级前下的）先认它一次、并补写标记 ——
        //   否则升级后所有"下到一半"的任务都要从头重下几百 MB。
        if let sz = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, sz > 0 {
            if let marked = try? String(contentsOf: doneMarkerURL(index), encoding: .utf8),
               Int(marked.trimmingCharacters(in: .whitespacesAndNewlines)) == sz {
                return 0                                     // 标记对得上 → 真的是完整的
            }
            if !FileManager.default.fileExists(atPath: doneMarkerURL(index).path) {
                try? String(sz).write(to: doneMarkerURL(index), atomically: true, encoding: .utf8)
                return 0                                     // 老文件：只认这一次
            }
            // 有标记但对不上 → 上次那份是**短内容**，不认，往下重下
        }
        var lastErr: Error?
        for attempt in 0...options.retry {
            do {
                // ★★ v1.0.199（AI 审查 P1）：**改成让 URLSession 下到临时文件**，
                //   不再整段读进内存。以前 data(for:) 每个分片整段进内存，默认并发 6 ——
                //   普通分片（1~3MB）没事，遇到 20MB+ 的大分片就会顶内存被系统杀掉。
                let (tmpURL, resp) = try await URLSession.shared.download(for: request(for: url))
                let http = resp as? HTTPURLResponse
                if let h = http, !(200...299).contains(h.statusCode) {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw Fail.badStatus(h.statusCode, url.lastPathComponent)
                }
                let gotBytes = ((try? FileManager.default.attributesOfItem(atPath: tmpURL.path))?[.size]
                                as? NSNumber)?.intValue ?? 0
                guard gotBytes > 0 else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw Fail.badStatus(0, "空响应")
                }

                // ★★ v1.0.140 的两道内容校验照旧（只是改成读文件、不整读）：
                //   ① 声明了长度就必须对得上（"短响应"当场拦下）
                if let h = http, h.expectedContentLength > 0, Int64(gotBytes) != h.expectedContentLength {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw Fail.badContent(index,
                        "声明 \(h.expectedContentLength) 字节、实际只收到 \(gotBytes) 字节")
                }
                //   ② 首字节必须是 TS 的同步字节 0x47（**只读 1 个字节**，不整读）。
                //   ★★ 这条**只能对"明文 TS 流"用**，否则会把加密流和 fMP4 全判成坏：
                //      · 加密流（AES-128）的分片是**密文**，首字节当然不是 0x47；
                //      · fMP4 分片的扩展名是 .m4s，本来就不是 TS。
                //      解密发生在拼接阶段，所以这里只能按"清单有没有 key + 后缀"来判断。
                let ext = url.pathExtension.lowercased()
                let isPlainTS = (playlist.key == nil) && ext != "m4s" && ext != "mp4"
                if isPlainTS {
                    let fh = try? FileHandle(forReadingFrom: tmpURL)
                    let first = fh?.readData(ofLength: 1).first
                    try? fh?.close()
                    if let first, first != 0x47 {
                        try? FileManager.default.removeItem(at: tmpURL)
                        throw Fail.badContent(index, String(format: "开头是 0x%02X，不像视频分片", first))
                    }
                }

                // 挪进分片目录：同一卷就是"重命名"，很快。
                // ★ 但**不当原子保证**（DeepSeek 复核时点过）：挪不动就退回"拷一份再删"。
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: dest)
                } catch {
                    try? FileManager.default.copyItem(at: tmpURL, to: dest)
                    try? FileManager.default.removeItem(at: tmpURL)
                }
                guard FileManager.default.fileExists(atPath: dest.path) else {
                    throw Fail.badStatus(0, "分片落盘失败")
                }
                // 落盘成功 → 写完成标记（内容 = 字节数），下次续传就靠它
                try? String(gotBytes).write(to: doneMarkerURL(index), atomically: true, encoding: .utf8)
                return Int64(gotBytes)
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
