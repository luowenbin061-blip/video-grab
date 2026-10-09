import Foundation

/// 「粘贴链接」里的 **抖音 / 小红书 / 快手「直解」**（★ v1.0.257）。
///
/// 目标：贴一条分享链接（或整段分享文案）→ **直接解析出无水印视频直链** → 直接下载。
/// （原先这三家只有"开网页 + 嗅探"的兜底路，体验差一档；这条路对齐 B站 的"贴链接就出活"。）
///
/// ★★ 机制全部经 PC 实测冻结（2026-10-09，探针脚本见 `_probe_tmp/sv_probe*.py`）：
///   三家都**不需要官方签名**，走的都是"**分享页里嵌的数据**"（读公开网页，不是破接口）：
///   · **抖音**：短链/整链先归一出 `aweme_id` → `www.iesdouyin.com/share/video/{id}/`
///     页面里的 `window._ROUTER_DATA` → `videoInfoRes.item_list[0].video.play_addr.url_list[0]`
///     （URL 里 `playwm` 换成 `play` = 无水印）。
///     ★★ 必须**同会话抓两遍**：第一遍只为拿 `ttwid` cookie（实测第一遍 34147 字节无数据、
///     带 cookie 第二遍 41799 字节有数据）。
///   · **小红书**：xhslink(.com/.cn) 短链跳转 → 笔记页状态里的 `originVideoKey` → 拼
///     `https://sns-video-bd.xhscdn.com/{key}`（拼出来的就是无水印原片）。
///     ★ **必须手机 UA**（实测：桌面 UA 版本页面拿不到 video key）。
///   · **快手**：v.kuaishou.com 短链跳转 → `m.chenzhongtech.com/fw/photo/{id}` 页里的
///     `"mainMvUrls":[{..."url":"https://xxx.kwaicdn.com/....mp4"}, {CDN 镜像}]`。
///
/// ★★ 这个文件**故意只依赖 Foundation**（和 BiliParse / LinkText 同一份白名单规矩）：
///   不许 import UIKit / WebKit，也不许引用白名单外的文件 —— 这样云端回归测试够得着它。
///   抠数据的函数全是**纯函数**（喂 HTML 字符串就有结果），单测钉的就是它们。
///
/// ★ 口径（经 DP 复核，收据 `ac-6ac8ecf1f8c66794d2addcf5`）：
///   · 直链当"一次性"用：**解析后立即下载，别缓存**（小红书带 sign+t、快手带 pkey，会过期）；
///   · 解析失败重试**只做一次**（就是上面那"第二遍"，顺带解决抖音 cookie）；
///   · 下载失败（403/410 这类签名过期）：**重解析一次换新链**，再不行才回落嗅探
///     （见 LinkGrabber.runShortVideo）；下载的 UA / Referer 与解析保持一致；
///   · 并发限 1（用户手动单条，频率天然低）；日志别打完整签名 URL。
///   · 页面结构改版时这套要跟着修 —— "偶尔维护"量级，别当永久接口用。
enum ShortVideoParse {

    /// 解析结果。
    struct Resolved {
        var title: String
        /// 候选直链（按优先级）。抖音给多 CDN、快手给双镜像；下载失败可换下一个试。
        /// ★ 顺序：先去水印版，再多 CDN 原串（见 `douyinVideo` 的组装）。
        var videoURLs: [URL]
        /// 下载时要带的请求头 —— 与解析保持一致（UA 必须同款）。
        var userAgent: String
        var referer: String
    }

    enum SVError: LocalizedError {
        case badLink
        case noID
        /// 页面结构里没找到视频数据（图文 / 直播 / 已删除 / 风控验证 都会落这里）
        case noData(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badLink:  return "链接格式不认识"
            case .noID:     return "链接里找不到视频编号"
            case .noData(let why):  return why
            case .network(let why): return why
            }
        }
    }

    /// 手机 Safari UA —— 三家解析都用它（实测：桌面 UA 在小红书拿不到数据）。
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    // MARK: - 会话（同会话自动带 cookie —— 抖音 ttwid 的关键）

    /// ★ ephemeral：cookie 只活在内存里（应用本次运行内自然复用；不写盘、不污染别处）。
    ///   抖音要"同一会话内先拿 ttwid 再抓第二遍"，实测缺此 cookie 拿不到数据。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 带 header 的 GET（自动跟重定向；返回最终 URL / 页面文本 / 状态码）。
    private static func fetch(_ url: String, referer: String? = nil)
        async throws -> (final: String, body: String, code: Int) {
        guard let u = URL(string: url) else { throw SVError.badLink }
        var r = URLRequest(url: u)
        r.timeoutInterval = 12
        r.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer, !referer.isEmpty { r.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: d, encoding: .utf8)
                ?? String(data: d, encoding: .isoLatin1) ?? ""
            return (resp.url?.absoluteString ?? url, body, code)
        } catch {
            throw SVError.network("网络请求失败，稍后再试")
        }
    }

    // MARK: - 对外入口

    /// 解析一条分享链接。三家流程同构：归一 → 抓两遍（第二遍拿 cookie/重试）→ 抠数据。
    static func resolve(link: String, platform: LinkText.Kind.Platform) async throws -> Resolved {
        switch platform {
        case .douyin:      return try await douyin(link)
        case .xiaohongshu: return try await xhs(link)
        case .kuaishou:    return try await kuaishou(link)
        }
    }

    // MARK: - 抖音

    private static let douyinReferer = "https://www.douyin.com/"

    private static func douyin(_ link: String) async throws -> Resolved {
        // ① 归一出 aweme_id
        let shareURL: String
        if let id = longID(in: link) {
            shareURL = "https://www.iesdouyin.com/share/video/\(id)/"
        } else {
            // 短链：跟一次跳转（顺便把 ttwid 拿进会话）
            let r1 = try await fetch(link)
            guard let id = longID(in: r1.final) else { throw SVError.noID }
            shareURL = "https://www.iesdouyin.com/share/video/\(id)/"
        }
        // ② 抓两遍：第一遍可能只为拿 cookie（实测如此），第二遍才有数据
        var resp = try await fetch(shareURL, referer: douyinReferer)
        if douyinVideo(in: resp.body) == nil {
            resp = try await fetch(shareURL, referer: douyinReferer)
        }
        guard let picked = douyinVideo(in: resp.body) else {
            throw SVError.noData(resp.code != 200
                ? "分享页打不开（HTTP \(resp.code)，可能被平台风控）"
                : "分享页里没找到视频（可能：已删除 / 是图文或直播 / 被风控了）")
        }
        return Resolved(title: picked.title.isEmpty ? "抖音视频" : picked.title,
                        videoURLs: picked.urls, userAgent: mobileUA, referer: douyinReferer)
    }

    // MARK: - 小红书

    private static func xhs(_ link: String) async throws -> Resolved {
        // 短链跟跳转（输入本身是笔记页链接时也无害）
        let r1 = try await fetch(link)
        var resp = r1
        if xhsVideo(in: resp.body) == nil {
            resp = try await fetch(r1.final)
        }
        guard let picked = xhsVideo(in: resp.body) else {
            throw SVError.noData(resp.code != 200
                ? "笔记页打不开（HTTP \(resp.code)，可能被限流）"
                : "笔记页里没找到视频（可能：是图文笔记 / 平台要登录 / 被限流了）")
        }
        return Resolved(title: picked.title.isEmpty ? "小红书视频" : picked.title,
                        videoURLs: picked.urls, userAgent: mobileUA, referer: "")
    }

    // MARK: - 快手

    private static func kuaishou(_ link: String) async throws -> Resolved {
        let r1 = try await fetch(link)
        var resp = r1
        if kwaiVideo(in: resp.body) == nil {
            resp = try await fetch(r1.final)
        }
        guard let picked = kwaiVideo(in: resp.body) else {
            throw SVError.noData(resp.code != 200
                ? "分享页打不开（HTTP \(resp.code)，可能被平台风控）"
                : "分享页里没找到视频（可能：是图集 / 已删除 / 被风控了）")
        }
        return Resolved(title: picked.title.isEmpty ? "快手视频" : picked.title,
                        videoURLs: picked.urls, userAgent: mobileUA, referer: "")
    }

    // MARK: - 抠数据（纯函数，单测钉的就是这一片）

    /// 从抖音分享页 HTML 里抠直链与标题。
    /// 先走 JSON（`window._ROUTER_DATA` 的完整对象，最稳），失败再退正则。
    static func douyinVideo(in html: String) -> (title: String, urls: [URL])? {
        // ① JSON 路线
        if let root = jsonAfter(marker: "_ROUTER_DATA", in: html),
           let item = firstDict(in: root, where: { d in
               (d["video"] as? [String: Any])?["play_addr"] != nil
           }),
           let video = item["video"] as? [String: Any],
           let playAddr = video["play_addr"] as? [String: Any],
           let list = playAddr["url_list"] as? [String] {
            let urls = urlCandidates(list)
            if !urls.isEmpty {
                return (cleanTitle((item["desc"] as? String) ?? ""), urls)
            }
        }
        // ② 正则兜底（JSON 切片失败时 —— 页面改版/截断）
        if let raw = firstMatch(#""play_addr"\s*:\s*\{[^}]*?"url_list"\s*:\s*\[\s*"([^"]+)""#, in: html),
           let u = URL(string: noWatermark(unescape(raw))) {
            let t = firstMatch(#""desc"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: html) ?? ""
            return (cleanTitle(t), [u])
        }
        return nil
    }

    /// 从笔记页 HTML 抠 key 拼直链。
    /// `originVideoKey` 拼出来的是**无水印原片**（带水印的是另一套 259 串，实测对照过）。
    static func xhsVideo(in html: String) -> (title: String, urls: [URL])? {
        guard let rawKey = firstMatch(#"originVideoKey"\s*:\s*"([^"]+)""#, in: html) else { return nil }
        let key = unescape(rawKey)
        guard let u = URL(string: "https://sns-video-bd.xhscdn.com/" + key) else { return nil }
        let t = firstMatch(#""title"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: html) ?? ""
        return (cleanTitle(t), [u])
    }

    /// 从快手分享页 HTML 抠主视频直链（双 CDN 镜像都给）。
    static func kwaiVideo(in html: String) -> (title: String, urls: [URL])? {
        // 在 `"mainMvUrls"` 到下一个 `]` 之间找所有 `"url":"..."`（实测该数组里就是主视频）
        guard let seg = slice(html, from: "\"mainMvUrls\"", to: "]") else { return nil }
        let urls = allMatches(#""url"\s*:\s*"([^"]+)""#, in: seg)
            .compactMap { URL(string: unescape($0)) }
        guard !urls.isEmpty else { return nil }
        let t = firstMatch(#""caption"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: html) ?? ""
        return (cleanTitle(t), urls)
    }

    /// 抖音 url_list → 候选直链列表：**先去水印版（playwm→play），再原串兜底**，
    /// 并按 URL 去重（同一条链可能只有一种形态）。
    static func urlCandidates(_ list: [String]) -> [URL] {
        let plays = list.map { noWatermark($0) }.compactMap { URL(string: $0) }
        let origins = list.compactMap { URL(string: $0) }
        var seen = Set<String>()
        return (plays + origins).filter { seen.insert($0.absoluteString).inserted }
    }

    /// `playwm`（带水印版）→ `play`（无水印版）。没有 playwm 就原样返回。
    static func noWatermark(_ s: String) -> String {
        s.contains("playwm") ? s.replacingOccurrences(of: "playwm", with: "play") : s
    }

    /// 从链接里找视频长编号（抖音都是 19 位数字）。
    /// ★ 先认路径（`/video/`、`/note/`），拿不到再退"第一段 ≥15 位数字"兜底 ——
    ///   直接扫数字会把 `mid=` 之类的参数也扫进来，所以路径优先。
    static func longID(in link: String) -> String? {
        for marker in ["/video/", "/note/"] {
            if let r = link.range(of: marker) {
                let digits = link[r.upperBound...].prefix { $0.isNumber }
                if digits.count >= 15 { return String(digits) }
            }
        }
        var run = ""
        for ch in link {
            if ch.isNumber {
                run.append(ch)
            } else {
                if run.count >= 15 { return run }
                run = ""
            }
        }
        return run.count >= 15 ? run : nil
    }

    /// 正则路线用：还原页面里的转义。
    /// ★ 顺序照 DP 复核建议：unicode 转义 → HTML 实体；**不做**整体 percent-decode
    ///   （URL 里本来就有 `%3D` 这类合法转义，解了反而坏）。
    static func unescape(_ s: String) -> String {
        var t = s
        let pairs: [(String, String)] = [
            ("\\u002F", "/"), ("\\u0026", "&"), ("\\u003D", "="), ("\\u003F", "?"),
            ("\\/", "/"),
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ]
        for (k, v) in pairs { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    /// 标题洗成一行干净的。
    /// ★ 两种来源形态不一样：**JSON 路线**解出来的是**真换行符**；
    ///   **正则路线**拿到的是 `\n` 两字符字面 —— 两种都要洗（单测各钉了一条）。
    static func cleanTitle(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "\r", with: " ")
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "\t", with: " ")
        let pairs: [(String, String)] = [
            ("\\n", " "), ("\\r", " "), ("\\t", " "), ("\\\"", "\""), ("\\\\", "\\"),
        ]
        for (k, v) in pairs { t = t.replacingOccurrences(of: k, with: v) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 小工具（正则 / JSON 切片）

    /// 找 `marker` 之后第一个 `{`，切到 `</script` 为止，当 JSON 解析。
    private static func jsonAfter(marker: String, in html: String) -> Any? {
        guard let r = html.range(of: marker),
              let brace = html[r.upperBound...].firstIndex(of: "{") else { return nil }
        // ★ 先转成 String 再找结束标记 —— `range(of:)` 在 Substring 上容易踩编译歧义，不值当。
        let tail = String(html[brace...])
        let end = tail.range(of: "</script")?.lowerBound ?? tail.endIndex
        var slice = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        while slice.hasSuffix(";") { slice.removeLast() }
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// 在 JSON 树里递归找第一个满足条件的字典（找 item_list[0] 那一层用）。
    private static func firstDict(in any: Any, where pred: ([String: Any]) -> Bool) -> [String: Any]? {
        if let d = any as? [String: Any] {
            if pred(d) { return d }
            for v in d.values {
                if let found = firstDict(in: v, where: pred) { return found }
            }
        } else if let a = any as? [Any] {
            for v in a {
                if let found = firstDict(in: v, where: pred) { return found }
            }
        }
        return nil
    }

    /// 取正则第一个捕获组。
    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 取正则全部捕获组。
    private static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    /// 取 `from` 之后到第一个 `to` 之间的片段（快手主视频数组用）。
    private static func slice(_ s: String, from: String, to: String) -> String? {
        guard let r = s.range(of: from) else { return nil }
        let tail = String(s[r.upperBound...])          // 同上：先转 String 再查
        guard let e = tail.range(of: to) else { return nil }
        return String(tail[..<e.lowerBound])
    }
}
