import CryptoKit
import Foundation

/// 「粘贴链接」里的 **B站解析**。
///
/// 目标：给一条 B站 链接 → 拿到**无水印的原始流地址**（音视频是分开的两条 DASH 流）。
///
/// ★ 为什么叫「无水印」：不是把水印擦掉，而是走平台接口取那条**本来就没叠水印**的原始流。
///   代价是要算签名（wbi）—— 这个文件里最要紧的就是那个签名。
///
/// ★★ 这个文件**故意只依赖 Foundation + CryptoKit**，不许 import UIKit、
///   也不许引用工程里其它文件 —— 因为 `project.yml` 的测试目标只编译一份白名单里的
///   纯逻辑文件，只有保持"自包含"，它才能进云端回归测试。
///
/// ★★ wbi 签名算法是**对拍验证过**的：同一套输入分别用 JS（照官方示例逐字照搬）
///   和本文件的等价写法算过，结果逐字节一致（含中文、空格的 URL 编码，
///   以及 `!'()*` 这五个字符的过滤）。单测里钉的就是那次对拍出来的标准答案。
///   **别凭感觉改这个算法** —— 它错了不会崩，只会静默拿不到高清流。
enum BiliParse {

    // MARK: - 认链接

    /// 从链接里认出的视频标识。
    enum Ref: Equatable {
        case bvid(String)
        case aid(Int)

        /// 拼进接口查询串时的样子（`bvid=BV...` / `aid=123`）
        var queryItem: String {
            switch self {
            case .bvid(let b): return "bvid=" + b
            case .aid(let a): return "aid=" + String(a)
            }
        }
    }

    /// 这个链接是不是 B站 的（含短链域名）。
    static func isBiliLink(_ link: String) -> Bool {
        guard let h = host(of: link) else { return false }
        return h == "bilibili.com" || h.hasSuffix(".bilibili.com")
            || h == "b23.tv" || h == "acg.tv" || h == "bili2233.cn"
    }

    /// 是不是短链 —— 短链里没有视频号，必须**先跟一次重定向**才知道真正的地址。
    static func isShortLink(_ link: String) -> Bool {
        guard let h = host(of: link) else { return false }
        return h == "b23.tv" || h == "acg.tv" || h == "bili2233.cn"
    }

    /// 从链接里认出 `BV...`（12 个字符：BV + 10 位字母数字）。
    ///
    /// ★ 为什么不直接用正则：这个函数要进纯逻辑回归集，
    ///   手写扫描没有额外依赖、行为也更清楚（越界边界一眼能看出）。
    static func bvid(inLink link: String) -> String? {
        let c = Array(link)
        guard c.count >= 12 else { return nil }
        var i = 0
        while i + 12 <= c.count {
            if c[i] == "B", c[i + 1] == "V" {
                let body = c[(i + 2)..<(i + 12)]
                if body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    // ★ 这里逐字符拼，不用 `String(ArraySlice)` —— 那个重载在标准库里
                    //   是否跟 `[Character]` 一视同仁，不值得为省一行去赌一次云端编译。
                    var out = ""
                    out.reserveCapacity(12)
                    for k in i..<(i + 12) { out.append(c[k]) }
                    return out
                }
            }
            i += 1
        }
        return nil
    }

    /// 从链接里认出 `av` 号（老格式）。只在 `/av123` 或 `aid=123` 这种**明确**的写法上认，
    /// 免得把普通单词里的 "av" 当成视频号。
    static func aid(inLink link: String) -> Int? {
        for marker in ["/av", "aid=", "?av"] {
            guard let r = link.range(of: marker) else { continue }
            let digits = link[r.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty, let n = Int(digits) { return n }
        }
        return nil
    }

    /// 认出一条链接对应的视频标识（先认 BV，再认 av）。
    static func ref(inLink link: String) -> Ref? {
        if let b = bvid(inLink: link) { return .bvid(b) }
        if let a = aid(inLink: link) { return .aid(a) }
        return nil
    }

    /// 分 P：`?p=3` → 3。认不出来就是 1。
    static func page(inLink link: String) -> Int {
        guard let r = link.range(of: "p=") else { return 1 }
        let digits = link[r.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n >= 1 else { return 1 }
        return n
    }

    static func host(of link: String) -> String? {
        URL(string: link)?.host?.lowercased()
    }

    // MARK: - wbi 签名（这个文件里最要紧的一段）

    /// 官方的固定重排表（64 项）。
    /// ★ 这张表是平台前端写死的，**不是**每次请求变；变的是 img_key / sub_key。
    static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    /// 用 img_key + sub_key 重排出 32 位的 mixinKey。
    /// 两个 key 拼起来不足 64 位就返回空串（调用方据此判定"没拿到 key"）。
    static func mixinKey(imgKey: String, subKey: String) -> String {
        let raw = Array(imgKey + subKey)
        guard raw.count >= 64 else { return "" }
        var out = ""
        out.reserveCapacity(32)
        for i in mixinKeyEncTab { out.append(raw[i]) }
        return String(out.prefix(32))
    }

    /// MD5 十六进制小写。CryptoKit 的 `Insecure.MD5` 够用（这里不是安全场景，是平台的完整性校验）。
    static func md5Hex(_ s: String) -> String {
        let d = Insecure.MD5.hash(data: Data(s.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    /// `encodeURIComponent` 的等价物。
    ///
    /// ★ 这里有个容易错的点：JS 的 encodeURIComponent **不转义** `-_.!~*'()`，
    ///   而值里的 `!'()*` 会**先被过滤掉** → 剩下的"不转义集合"就是
    ///   `A-Za-z0-9` 加 `-` `_` `.` `~`。别的都要转义。
    ///   （中文走 UTF-8 逐字节转义 —— 对拍用例里专门有一条中文的。）
    static func uriEncode(_ s: String) -> String {
        var safe = CharacterSet()
        safe.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        safe.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        safe.insert(charactersIn: "0123456789")
        safe.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: safe) ?? s
    }

    /// 算出带 `w_rid` 的完整查询串（不含问号）。
    ///
    /// 步骤照平台前端：把 `wts` 先塞进参数 → 按 key 升序 → 值里滤掉 `!'()*`
    /// → 各自 `encodeURIComponent` → 用 `&` 连起来 → 末接 mixinKey 求 MD5。
    ///
    /// ★ `wts` 由调用方给（不在这里取当前时间）：**可测**比"省一行"重要得多。
    static func wbiQuery(params: [String: String], imgKey: String, subKey: String,
                         wts: Int) -> String {
        var p = params
        p["wts"] = String(wts)
        let mixin = mixinKey(imgKey: imgKey, subKey: subKey)
        let body = p.keys.sorted().map { k -> String in
            let filtered = String(p[k]!.filter { !"!'()*".contains($0) })
            return uriEncode(k) + "=" + uriEncode(filtered)
        }.joined(separator: "&")
        return body + "&w_rid=" + md5Hex(body + mixin)
    }

    // MARK: - 解析平台返回的 JSON（纯函数，可测）

    /// 从 `nav` 接口的响应里抠出 img_key / sub_key。
    ///
    /// ★ 两个 key 藏在图片 URL 的**文件名**里：
    ///   `.../bfs/wbi/7cd084941338484aae1ad9425b84077c.png` → `7cd084941338484aae1ad9425b84077c`
    /// ★★ 注意：**没登录时这个接口会返回 code:-101，但里面的 wbi_img 照样是有的**。
    ///   所以这里**不看 code**，只看能不能抠出两个 key —— 这是"未登录也能解析"的前提。
    static func imgSubKeys(navJSON data: Data) -> (imgKey: String, subKey: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let wbi = d["wbi_img"] as? [String: Any],
              let imgURL = wbi["img_url"] as? String,
              let subURL = wbi["sub_url"] as? String else { return nil }
        let img = fileNameStem(imgURL)
        let sub = fileNameStem(subURL)
        guard img.count >= 32, sub.count >= 32 else { return nil }
        return (img, sub)
    }

    /// 从 `.../7cd0....png` 里取出 `7cd0...`（去目录、去扩展名）。
    static func fileNameStem(_ url: String) -> String {
        let last = url.split(separator: "/").last.map(String.init) ?? url
        if let dot = last.lastIndex(of: ".") { return String(last[last.startIndex..<dot]) }
        return last
    }

    /// 从 `view` 接口的响应里取出这个分 P 的 cid / aid / 标题 / 时长。
    ///
    /// ★ 分 P：`data.pages` 是每一 P 的清单，`pages[p-1].cid` 才是那一 P 的 cid。
    ///   单 P 视频 `pages` 只有一项，`data.cid` 跟它一样 —— 两条路都留着，
    ///   免得遇到"没有 pages 字段"的老响应直接解析失败。
    static func videoInfo(viewJSON data: Data, page: Int = 1) -> (cid: Int64, aid: Int64,
                                                                  title: String,
                                                                  duration: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }
        let title = (d["title"] as? String) ?? ""
        let aid = int64(d["aid"]) ?? 0
        var cid = int64(d["cid"]) ?? 0
        if let pages = d["pages"] as? [[String: Any]], page >= 1, page <= pages.count {
            cid = int64(pages[page - 1]["cid"]) ?? cid
        }
        guard cid > 0 else { return nil }
        var dur = double(d["duration"]) ?? 0
        if let pages = d["pages"] as? [[String: Any]], page >= 1, page <= pages.count {
            dur = double(pages[page - 1]["duration"]) ?? dur
        }
        return (cid, aid, title, dur)
    }

    /// 一条媒体流。
    struct Stream: Equatable {
        var url: String
        var quality: Int        // 清晰度码：80=1080P, 64=720P, 32=480P, 16=360P…
        var codecs: String      // avc1 / hev1 / av01 / mp4a
        var width: Int
        var height: Int
        var bandwidth: Int
    }

    /// ★ v1.0.254：一条**可选清晰度档位** —— 界面给用户挑的就是它。
    ///   来源 = `dash.video` 里**实际下发**的档位（不是 accept_quality：
    ///   那个含"账号权限里有、但这次没下发"的档 —— 列出来也下不到，别骗用户）。
    ///   音频不分档（dash.audio 与清晰度无关），由 `Resolved.audioURL` 统一带。
    struct Quality: Equatable {
        var value: Int          // 清晰度码
        var name: String        // 给人看的名字（1080P / 480P…）
        var videoURL: URL       // 这一档的视频流地址（已挑好最优编码：avc1 优先）
    }

    /// ★ v1.0.254：把 dash.video 里实际下发的**全部清晰度档**列出来（降序）。
    ///   每档挑一条最优编码（avc1 优先、同编码带宽大者 —— 与 `pickVideo` 同规则）。
    ///   没有 dash / 没有可用流 → nil（调用方走 durl 退路或报错）。
    static func allQualities(playURLJSON data: Data) -> [Quality]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let dash = d["dash"] as? [String: Any],
              let vids = dash["video"] as? [[String: Any]], !vids.isEmpty else { return nil }
        let videos = vids.compactMap(stream(from:))
        guard !videos.isEmpty else { return nil }
        // 按清晰度码分组 → 每组挑最优编码
        var groups: [Int: [Stream]] = [:]
        for v in videos { groups[v.quality, default: []].append(v) }
        var out: [Quality] = []
        for (q, list) in groups {
            guard let best = pickVideo(list), let u = URL(string: best.url) else { continue }
            out.append(Quality(value: q, name: qualityName(q), videoURL: u))
        }
        out.sort { $0.value > $1.value }        // 降序：高清在前
        return out.isEmpty ? nil : out
    }

    /// 从 `playurl` 的响应里挑出**一条视频 + 一条音频**。
    ///
    /// 挑法：
    ///   · 视频 —— 先取清晰度码最大的那一档；同一档里可能有多个编码
    ///     （avc1 / hev1 / av01），**优先 avc1（H.264）**：兼容性最好，
    ///     而且在 iOS 上无论如何都能播、能再转码。
    ///   · 音频 —— 优先 mp4a 里带宽最大的那条。
    ///   · 如果响应里没有 DASH（老接口 / 只有 `durl`），退化成"整段 mp4 一条流"。
    static func streams(playURLJSON data: Data) -> (video: Stream, audio: Stream?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }

        // ① DASH：音视频分开
        if let dash = d["dash"] as? [String: Any],
           let vids = dash["video"] as? [[String: Any]], !vids.isEmpty {
            let videoStreams = vids.compactMap(stream(from:))
            guard let best = pickVideo(videoStreams) else { return nil }
            // ★ v1.0.254：音频挑选抽到 `bestAudio`（"列档位"那条新路也要它，别写两份）
            return (best, bestAudio(playURLJSON: data))
        }

        // ② 退路：durl（一个完整 mp4，音视频在一起）
        if let durl = d["durl"] as? [[String: Any]],
           let first = durl.first, let u = first["url"] as? String {
            let s = Stream(url: u, quality: Int(int64(d["quality"]) ?? 0),
                           codecs: "durl", width: 0, height: 0, bandwidth: 0)
            return (s, nil)
        }
        return nil
    }

    /// 把 DASH 里的一个数组元素读成 `Stream`。
    private static func stream(from o: [String: Any]) -> Stream? {
        guard let u = o["baseUrl"] as? String ?? (o["base_url"] as? String) else { return nil }
        return Stream(url: u,
                      quality: Int(int64(o["id"]) ?? 0),
                      codecs: (o["codecs"] as? String) ?? "",
                      width: Int(int64(o["width"]) ?? 0),
                      height: Int(int64(o["height"]) ?? 0),
                      bandwidth: Int(int64(o["bandwidth"]) ?? 0))
    }

    /// 挑最高清晰度的视频流；同档优先 H.264。
    static func pickVideo(_ list: [Stream]) -> Stream? {
        guard !list.isEmpty else { return nil }
        let top = list.map(\.quality).max() ?? 0
        let sameQuality = list.filter { $0.quality == top }
        let rank: (String) -> Int = { c in
            if c.hasPrefix("avc1") { return 0 }          // H.264：兼容性最好
            if c.hasPrefix("hev1") || c.hasPrefix("hvc1") { return 1 }
            if c.hasPrefix("av01") { return 2 }
            return 3
        }
        return sameQuality.min { a, b in
            let ra = rank(a.codecs), rb = rank(b.codecs)
            if ra != rb { return ra < rb }
            return a.bandwidth > b.bandwidth
        }
    }

    /// 挑音频流：优先 mp4a，其次带宽最大。
    static func pickAudio(_ list: [Stream]) -> Stream? {
        guard !list.isEmpty else { return nil }
        let mp4a = list.filter { $0.codecs.hasPrefix("mp4a") }
        let pool = mp4a.isEmpty ? list : mp4a
        return pool.max { $0.bandwidth < $1.bandwidth }
    }

    /// ★ v1.0.254：从 playurl 响应里直接挑一条最优音频。
    ///   （从原 `streams()` 里抽出来 —— 现在"列全部档位"和"挑最高档"两条路都要它。）
    static func bestAudio(playURLJSON data: Data) -> Stream? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let dash = d["dash"] as? [String: Any] else { return nil }
        var audios = (dash["audio"] as? [[String: Any]] ?? []).compactMap(stream(from:))
        // ★ 杜比 / 无损单独挂在 dash 下（要会员）—— 能拿到就用，拿不到就算了
        if let dolby = dash["dolby"] as? [String: Any],
           let a = (dolby["audio"] as? [[String: Any]] ?? []).compactMap(stream(from:)).first {
            audios.append(a)
        }
        // ★ 这两个的形状**不一样**（照平台实际响应写的，别想当然）：
        //   · `dash.dolby.audio` 是**数组**
        //   · `dash.flac.audio`  是**单个对象**
        //   写成一样的话，`?? []` 会把类型推成字典、直接编译不过（run #244 就栽在这）。
        if let flac = dash["flac"] as? [String: Any],
           let fa = flac["audio"] as? [String: Any],
           let a = stream(from: fa) {
            audios.append(a)
        }
        return pickAudio(audios)
    }

    /// `accept_quality`（当前登录状态能拿到哪些清晰度）—— 用来提示"未登录只有 480P"。
    static func acceptQuality(playURLJSON data: Data) -> [Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let qs = d["accept_quality"] as? [Any] else { return [] }
        return qs.compactMap { q in BiliParse.int64(q).map { Int($0) } }
    }

    /// 清晰度码 → 给人看的名字。
    static func qualityName(_ q: Int) -> String {
        switch q {
        case 127: return "8K"
        case 126: return "杜比视界"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P60"
        case 112: return "1080P+"
        case 80: return "1080P"
        case 74: return "720P60"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        default: return "清晰度 \(q)"
        }
    }

    // MARK: - 数字宽容读取（JSON 里 number 可能是 Int / Double / String）

    static func int64(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - 联网解析（把上面那些零件串起来）

    /// 解析出来的结果 —— 足够发起下载。
    struct Resolved {
        var title: String
        /// 默认档（最高档）的视频地址 —— 用户选定后会被换成挑中的那档
        /// （见 `LinkGrabber.downloadSelected`）。
        var videoURL: URL
        var audioURL: URL?      // nil = 这条流本身就是完整的（durl 那条退路）
        var quality: Int
        var qualityText: String
        var loggedIn: Bool
        /// ★ v1.0.254：全部可选档位（降序；durl 退路时只有一条）。
        var qualities: [Quality] = []
        /// ★ v1.0.254：accept_quality（账号权限内可接受的档位池）——
        ///   只用来生成"登录可解锁更高画质"的提示，**不作为可选项**
        ///   （池里有的档实际没下发，列出来也下不到）。
        var allowedQualities: [Int] = []
    }

    enum ParseError: LocalizedError {
        case notBiliLink
        case noVideoID
        case noWbiKeys
        case apiFailed(String, Int)
        case noStream(String)

        var errorDescription: String? {
            switch self {
            case .notBiliLink:  return "这不是 B站 的链接"
            case .noVideoID:    return "链接里找不到视频编号（BV 号 / av 号）"
            case .noWbiKeys:    return "拿不到 B站 的签名密钥（接口可能改版了）"
            case .apiFailed(let api, let code): return "B站 接口 \(api) 返回错误码 \(code)"
            case .noStream(let why): return "没解析出可下载的流：\(why)"
            }
        }
    }

    /// 下载这些流时必须带的请求头 —— **不带 Referer 会被 403**，这是最容易漏的一步。
    static let mediaReferer = "https://www.bilibili.com/"
    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 把一条 B站 链接解析成「一条视频流 + 一条音频流」。
    ///
    /// - Parameters:
    ///   - cookie: 登录后的 Cookie（主要是 `SESSDATA`）。**空串也能解析** ——
    ///     只是清晰度被限到 480P（平台对未登录就是这个待遇）。
    ///   - userAgent: 默认给桌面版 UA（移动端 UA 拿到的流不一样）。
    static func resolve(link: String, cookie: String = "",
                        userAgent: String = defaultUA) async throws -> Resolved {
        // ① 短链先跟一次跳转，否则里面根本没有视频号
        var real = link
        if isShortLink(link) {
            real = await followRedirect(link, userAgent: userAgent) ?? link
        }
        guard isBiliLink(real) || isBiliLink(link) else { throw ParseError.notBiliLink }
        guard let ref = ref(inLink: real) else { throw ParseError.noVideoID }
        let page = page(inLink: real)

        // ② ★ v1.0.254：游客指纹 —— cookie 里没有 buvid3 时先补一份（官方 finger/spi）。
        //   B站 对"完全无指纹"的请求会概率性给风控空响应（用户实测"多点几次才能下"
        //   的来源之一）。失败就原样返回 —— 绝不因此中断解析。
        let ck = await ensureBuvid(cookie: cookie, userAgent: userAgent)

        // ③ 密钥（★ 未登录时这个接口 code 是 -101，但 wbi_img 照样有 —— 判据里不看 code）
        let nav = try await get("https://api.bilibili.com/x/web-interface/nav",
                                cookie: ck, userAgent: userAgent, referer: nil)
        guard let keys = imgSubKeys(navJSON: nav.data) else { throw ParseError.noWbiKeys }
        let loggedIn = (int64(jsonValue(nav.data, "code")) ?? -101) == 0

        // ④ 视频信息（拿 cid / 标题）
        let view = try await get("https://api.bilibili.com/x/web-interface/view?"
                                 + ref.queryItem,
                                 cookie: ck, userAgent: userAgent, referer: nil)
        guard let info = videoInfo(viewJSON: view.data, page: page) else {
            let code = Int(int64(jsonValue(view.data, "code")) ?? -1)
            throw ParseError.apiFailed("view", code)
        }

        // ⑤ 播放地址（这条接口要 wbi 签名 —— 每次请求都重新签名）。
        // ★★ v1.0.254：**自动重试** —— 把用户"多点几次开始才能下载"的痛点一次点掉：
        //   · code=0 却没流（风控"伪装成功"，data 里只有 v_voucher 之类）；
        //   · 风控错误码 -352 / -412；
        //   · 网络层瞬时错误（超时/抖动）。
        //   以上都自动重试（最多 3 次尝试，间隔 0.8s / 1.6s 指数退避）。
        //   ★ 重试**不重跑 nav/view** —— 那两个不参与风控判定，重跑只是多两次请求。
        var lastData = Data()
        var dashList: [Quality]?
        var durlPick: (video: Stream, audio: Stream?)?
        for attempt in 0..<3 {
            let params: [String: String] = [
                "cid": String(info.cid),
                "qn": "127",            // 要最高；实际给多少由平台的权限决定
                "fnval": "4048",        // 要 DASH（音视频分开的那套）
                "fnver": "0",
                "fourk": "1",
            ]
            let qq = ref.queryItem + "&" + wbiQuery(params: params, imgKey: keys.imgKey,
                                                    subKey: keys.subKey,
                                                    wts: Int(Date().timeIntervalSince1970))
            let full = "https://api.bilibili.com/x/player/wbi/playurl?"
                + qq + (page > 1 ? "&p=" + String(page) : "")

            let playData: Data
            do {
                playData = try await get(full, cookie: ck, userAgent: userAgent,
                                         referer: nil).data
            } catch {
                // 网络层错误也重试；最后一次仍失败 → 原样抛（那个文案本来就是对的）
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(800_000_000) << attempt)
                    continue
                }
                throw error
            }
            lastData = playData

            // 拿到 DASH 档位 → 成功
            if let qs = allQualities(playURLJSON: playData), !qs.isEmpty {
                dashList = qs
                break
            }
            // durl 退路（老接口 / 只有整段 mp4）→ 也是合法结果，重试没有意义
            if let picked = streams(playURLJSON: playData), picked.video.codecs == "durl" {
                durlPick = picked
                break
            }
            // 失败：只有"值得重试的"才重试（code=0 的无流 / 风控码）
            let code = Int(int64(jsonValue(playData, "code")) ?? -1)
            let retryable = (code == 0 || code == -352 || code == -412)
            if !retryable || attempt >= 2 { break }
            // 风控是概率性的：等一拍再试（立刻重试反而更容易撞上）
            try? await Task.sleep(nanoseconds: UInt64(800_000_000) << attempt)
        }

        // ⑥ 组装结果
        if let qs = dashList, let top = qs.first {
            return Resolved(title: info.title.isEmpty ? "B站视频" : info.title,
                            videoURL: top.videoURL,
                            audioURL: bestAudio(playURLJSON: lastData)
                                .flatMap { URL(string: $0.url) },
                            // ★ 以**实际下发的流**为准 —— data.quality 字段实测不可靠
                            //   （报 720P 而实际流只有 480P）
                            quality: top.value,
                            qualityText: top.name,
                            loggedIn: loggedIn,
                            qualities: qs,
                            allowedQualities: acceptQuality(playURLJSON: lastData))
        }
        if let picked = durlPick, let video = URL(string: picked.video.url) {
            let gq = picked.video.quality
            return Resolved(title: info.title.isEmpty ? "B站视频" : info.title,
                            videoURL: video,
                            audioURL: nil,
                            quality: gq,
                            qualityText: qualityName(gq),
                            loggedIn: loggedIn,
                            qualities: [Quality(value: gq, name: qualityName(gq), videoURL: video)],
                            allowedQualities: acceptQuality(playURLJSON: lastData))
        }
        // 全失败 → 分类报错（风控伪装成功 / 空响应 / 真·无流，分开说）
        throw ParseError.noStream(noStreamReason(lastData))
    }

    /// 跟一次 302，返回最终地址（拿不到就返回 nil，调用方退回原链接）。
    static func followRedirect(_ link: String, userAgent: String) async -> String? {
        guard let u = URL(string: link) else { return nil }
        var r = URLRequest(url: u)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: r) else {
            return nil
        }
        return resp.url?.absoluteString
    }

    /// 一个最小的带 header 的 GET（只用来打平台接口 —— 媒体流不走这里）。
    static func get(_ link: String, cookie: String, userAgent: String,
                    referer: String?) async throws -> (data: Data, status: Int) {
        guard let u = URL(string: link) else { throw ParseError.noStream("接口地址不合法") }
        var r = URLRequest(url: u)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty { r.setValue(referer, forHTTPHeaderField: "Referer") }
        if !cookie.isEmpty { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        r.timeoutInterval = 20
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        do {
            let (d, resp) = try await URLSession(configuration: cfg).data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { throw ParseError.apiFailed(host(of: link) ?? "接口", code) }
            return (d, code)
        } catch let e as ParseError {
            throw e
        } catch {
            throw ParseError.apiFailed(host(of: link) ?? "接口", -1)
        }
    }

    /// 从响应 JSON 顶层取一个字段（错误码用）。
    static func jsonValue(_ data: Data, _ key: String) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root[key]
    }

    /// ★ v1.0.254：游客指纹（buvid3 / buvid4）—— cookie 里没有时向官方
    ///   `finger/spi` 接口要一份补上。
    ///   为什么：B站 对"完全无指纹"的请求会概率性给风控空响应（用户实测
    ///   "多点几次开始才能下载"的来源之一）。用**真实接口**拿（不自造）。
    ///   ★ 已有 buvid3 就直接返回（别覆盖用户的登录态指纹）；
    ///   ★ 请求失败 / 解析不出 → 原样返回，绝不因此中断解析。
    static func ensureBuvid(cookie: String, userAgent: String) async -> String {
        if cookie.contains("buvid3=") { return cookie }
        guard let (data, _) = try? await get("https://api.bilibili.com/x/frontend/finger/spi",
                                             cookie: cookie, userAgent: userAgent,
                                             referer: nil),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return cookie }
        let b3 = (d["b_3"] as? String) ?? ""
        let b4 = (d["b_4"] as? String) ?? ""
        if b3.isEmpty && b4.isEmpty { return cookie }
        var parts: [String] = []
        if !cookie.isEmpty { parts.append(cookie) }
        if !b3.isEmpty { parts.append("buvid3=" + b3) }
        if !b4.isEmpty { parts.append("buvid4=" + b4) }
        return parts.joined(separator: "; ")
    }

    /// ★ v1.0.254：playurl"没有流"时的**分类**（纯函数、可单测）。
    ///   用户实测"多点几次就能成"的真身：B站风控有时返回 code=0 的**伪装成功**
    ///   （data 里只有 `v_voucher` 验证挑战，没有 dash/durl）。
    ///   以前一律报"响应里既没有 DASH 也没有 durl"——含糊且吓人；
    ///   现在分开说：风控验证 / 空响应 / 真·无流（附诊断键名）。
    static func noStreamReason(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "响应不是 JSON（网络截断？）。再点一次「开始」试试。"
        }
        let code = int64(root["code"]) ?? -1
        if code != 0 { return "playurl 返回错误码 \(code)" }
        let dv = root["data"]
        if dv == nil || dv is NSNull {
            return "B站 返回了空响应（可能被限流）。等几秒再点一次「开始」。"
        }
        let dataKeys = (dv as? [String: Any]).map { Array($0.keys) } ?? []
        if dataKeys.contains("v_voucher") {
            return "B站 要求安全验证（风控拦截）。再点一次「开始」通常能过；"
                + "还不行就等一分钟再试。"
        }
        return "B站 返回的响应里没有可下载的流（诊断：data 键=["
            + dataKeys.prefix(6).joined(separator: ",") + "]）。"
    }
}
