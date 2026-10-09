import Foundation

/// 「粘贴链接」的**文本识别**：从一段分享文案里抠出真正的链接，并认出它是什么。
///
/// ★★ 为什么单独一个文件、**只 import Foundation**：
///   它要进 `project.yml` 里那份"纯逻辑白名单"，跟 `BiliParse.swift` 一样规矩 ——
///   不许 import UIKit / WebKit，也不许引用工程里别的文件。
///   这样云端回归测试才够得着它（Swift 我在本机跑不了，"看代码觉得对"不算数）。
///
/// ★★ 为什么要有这个文件（v1.0.245 的两个真 bug 都出在这儿）：
///   ① **分享出去的链接永远带标题文字** —— B站 分享出来是
///      「【第一眼就惊艳的汉服摄影! -哔哩哔哩】 https://b23.tv/xxxx」，
///      而用户点"粘贴"拿到的是**整段文案**。按"整段是一个网址"去认必然认不出。
///   ② **b23.tv 短链里没有 BV 号** —— 老判据要求"必须认出 BV 号"，
///      于是连干净的短链也一律认不出。短链要先跟一次跳转才知道真身。
enum LinkText {

    /// 认出来的链接类型。
    enum Kind: Equatable {
        case magnet
        case bili
        case web(Platform)

        enum Platform: String, Equatable {
            case douyin = "抖音"
            case xiaohongshu = "小红书"
            case kuaishou = "快手"
        }
    }

    // MARK: - 从文案里抠链接

    /// URL 里允许出现的字符（RFC 3986 的 unreserved + reserved，够用了）。
    /// ★ 凡是**不在**这个集合里的字符（中文、全角括号、空格…）都当成"链接到头了"。
    ///   这样 `https://b23.tv/abcd（来自哔哩哔哩）` 这种就能在 `）` 处干净截断。
    private static let urlChars = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        + "-._~:/?#[]@!$&'()*+,;=%")

    /// 链接**尾巴上**常粘的标点（句号、逗号、右括号、右引号…）。
    /// ★ 这些字符本身是合法的 URL 字符（所以上面那个集合里有），
    ///   但出现在**结尾**时几乎一定是文案的标点而不是链接的一部分。
    private static let trailingJunk = Set(".,;:!?)]}'\"、，。；：！？）】」”’…")

    /// 从任意文本里抠出**第一条**链接。抠不到就返回 nil。
    ///
    /// 支持两种：`magnet:?xt=...` 和 `http(s)://...`。
    /// 链接**不带协议头**的（`b23.tv/xxxx`）在这里也认 —— 见下面的兜底。
    static func firstLink(in text: String) -> String? {
        // ★ 用 `range(of:options:.caseInsensitive)` 而不是"先 lowercased 再找"：
        //   后者拿到的索引属于**另一个字符串**，遇到某些字符会越界（String.Index 不能跨串用）。
        if let r = text.range(of: "magnet:", options: .caseInsensitive) {
            if let s = takeMagnet(text, from: r.lowerBound) { return s }
        }
        // ①b 全角冒号的变体「magnet：」—— 某些来源的分享文本里冒号也是全角
        let fwMagnet = "magnet："
        if let r = text.range(of: fwMagnet, options: .caseInsensitive) {
            let after = text.index(r.lowerBound, offsetBy: fwMagnet.count)
            if let tail = takeMagnet(text, from: after) { return "magnet:" + tail }
        }

        // ② http / https：从协议头开始截
        for scheme in ["https://", "http://"] {
            if let r = text.range(of: scheme, options: .caseInsensitive) {
                if let s = takeURL(text, from: r.lowerBound) { return s }
            }
        }

        // ③ 兜底：整段没有协议头。取第一个"空白分隔的片段"，只要它像域名就认
        //    （例：`b23.tv/abcd`、`www.bilibili.com/video/BV1xx411c7mD`）。
        //    ★ 判据收紧到"含点 + 不含中文"，免得把一句中文当链接。
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let t = trimTrailingPunctuation(String(token))
            if looksLikeBareDomain(t) { return t }
        }
        return nil
    }

    /// 从句子里某个位置往后取一段连续的 URL 字符，再去掉尾巴上的标点。
    private static func takeURL(_ text: String, from start: String.Index) -> String? {
        var out = ""
        for ch in text[start...] {
            if urlChars.contains(ch) { out.append(ch) } else { break }
        }
        out = trimTrailingPunctuation(out)
        return out.isEmpty ? nil : out
    }

    /// 磁力链接里常见的**全角标点** → 半角。
    /// ★★ v1.0.249：国内文本环境（输入法、分享文案）粘贴来的链接常混全角，
    ///   例：「magnet:？xt=...」里那个「？」是全角 —— 不修的话，老逻辑吃到
    ///   「magnet:」就断了，整条链接认不出来（用户实测样本里第 1 条就是这个形态）。
    private static let fullWidthFix: [Character: Character] = [
        "？": "?", "＝": "=", "＆": "&", "；": ";", "：": ":",
        "／": "/", "．": ".", "％": "%", "＃": "#", "＠": "@", "－": "-", "＿": "_",
    ]

    /// magnet 专用取串：比 `takeURL` 多一步「全角标点当半角吃」。
    /// （只在磁力分支用 —— 普通网址里全角罕见，不扩大改动面。）
    private static func takeMagnet(_ text: String, from start: String.Index) -> String? {
        var out = ""
        for ch in text[start...] {
            if urlChars.contains(ch) {
                out.append(ch)
            } else if let fixed = fullWidthFix[ch] {
                out.append(fixed)
            } else {
                break
            }
        }
        out = trimTrailingPunctuation(out)
        return out.isEmpty ? nil : out
    }

    /// 去掉链接尾巴上粘的标点（从左到右反复剥，直到尾巴不是标点）。
    static func trimTrailingPunctuation(_ s: String) -> String {
        var chars = Array(s)
        while let last = chars.last, trailingJunk.contains(last) { chars.removeLast() }
        return String(chars)
    }

    /// 判断一个没有协议头的片段像不像域名。
    /// ★ 只认"点前面是域名样子的东西"：`b23.tv/abcd` ✓、`www.bilibili.com/x` ✓、
    ///   `第一眼就惊艳的汉服摄影` ✗（有中文）、`1.5` ✗（最后一段没有字母）。
    static func looksLikeBareDomain(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains("://") else { return false }
        guard !s.contains(where: { $0.unicodeScalars.first.map { $0.value > 127 } ?? false }) else {
            return false                                   // 含非 ASCII（中文等）→ 不是
        }
        let head = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        guard head.contains("."), !head.hasPrefix("."), !head.hasSuffix(".") else { return false }
        let parts = head.split(separator: ".")
        guard parts.count >= 2 else { return false }
        guard parts.allSatisfy({ p in
            !p.isEmpty && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }
        // ★ 最后一段（顶级域那一段）**必须含字母** ——
        //   否则 "1.5"、"3.14159" 这种版本号/小数会被当成域名。
        return parts[parts.count - 1].contains(where: { $0.isLetter })
    }

    // MARK: - 认类型

    /// 认出这条**文案或链接**是什么。
    ///
    /// ★ 先抠链接再判 —— 用户点"粘贴"拿到的是整段分享文案，不是干净的网址。
    static func kind(of text: String) -> Kind? {
        guard let link = normalized(text) else { return nil }
        let low = link.lowercased()

        if low.hasPrefix("magnet:") { return .magnet }

        guard let host = URL(string: link)?.host?.lowercased() else { return nil }

        // B站：★ 短链（b23.tv）里没有 BV 号，**必须**先认它
        if host == "b23.tv" || host == "acg.tv" || host == "bili2233.cn" { return .bili }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            return BiliParse.ref(inLink: link) != nil ? .bili : nil
        }

        if host == "douyin.com" || host.hasSuffix(".douyin.com")
            || host == "iesdouyin.com" || host.hasSuffix(".iesdouyin.com") {
            return .web(.douyin)
        }
        if host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com")
            || host == "xhslink.com" || host.hasSuffix(".xhslink.com")
            // ★ v1.0.257：iOS 新版分享用的是 .cn 域名（老识别只认 .com —— 实测真漏洞）
            || host == "xhslink.cn" || host.hasSuffix(".xhslink.cn") {
            return .web(.xiaohongshu)
        }
        if host == "kuaishou.com" || host.hasSuffix(".kuaishou.com")
            || host == "gifshow.com" || host.hasSuffix(".gifshow.com")
            // ★ v1.0.257：老/移动分享域名（短链最终会落到 m.chenzhongtech.com 的分享页）
            || host == "chenzhongtech.com" || host.hasSuffix(".chenzhongtech.com") {
            return .web(.kuaishou)
        }
        return nil
    }

    /// 把"用户给的原文"变成一条可用的链接：
    /// 先抠链接；没有协议头的补上 `https://`（`URL(string:)` 才认得出 host）。
    static func normalized(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let raw = firstLink(in: t) ?? t
        let low = raw.lowercased()
        if low.hasPrefix("magnet:") || low.hasPrefix("http://") || low.hasPrefix("https://") {
            return raw
        }
        guard looksLikeBareDomain(raw) else { return nil }
        return "https://" + raw
    }

    /// 给用户看的一行说明。（界面里不写长篇解释，靠这行字点明接下来会发生什么。）
    static func hint(for kind: Kind) -> String {
        switch kind {
        case .magnet: return "BT 下载（先拿文件列表，再挑要下的）"
        // ★ v1.0.254：不再是"下最高清"——解析后会列出可选清晰度让用户自己挑。
        case .bili:   return "解析后可挑清晰度（音视频分开下、自动合并）"
        // ★ v1.0.257：这三家改成"直解"主路（解析不通才回落"开网页 + 嗅探"，见 LinkGrabber）
        case .web(let p): return "\(p.rawValue)：解析后直接下载（不行会自动改用网页方式）"
        }
    }
}
