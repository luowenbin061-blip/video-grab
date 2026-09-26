import Foundation

/// 书签文件解析（v1.0.90）。认两种格式：
///
///   1. **Netscape 书签 HTML** —— Chrome / Edge / Firefox / Safari / 夸克 导出**全都是这个**。
///      （实测过用户的夸克导出：`<!DOCTYPE NETSCAPE-Bookmark-file-1>` + `<DT><H3>` 文件夹
///      + `<DT><A HREF="...">` 条目 + `ADD_DATE`。）
///   2. **Chromium 内部 JSON** —— `roots.*.children` 那种递归结构（浏览器数据库备份的样子）。
///
/// ★ 为什么自己逐行扫、不用 XMLParser：各家导出的 HTML **并不严格合法**
///   （标签不闭合、属性大小写混着来、`<p>` 到处乱放），走 XML 解析器会直接失败。
///   逐行扫反而稳，而且这个格式一行就是一条，正好合拍。
enum BookmarkImporter {

    struct Entry {
        let title: String
        let url: String
        /// 文件里的文件夹名；根目录下的条目是 nil
        let folder: String?
    }

    /// 按**内容**认格式（别只看扩展名 —— 有人会把 .html 存成 .txt）
    static func parse(_ data: Data) -> [Entry] {
        let text = decode(data)
        let head = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace || $0 == "\n" }
        if head.first == "{" || head.first == "[" {
            if let ents = parseChromiumJSON(data), !ents.isEmpty { return ents }
        }
        let html = parseHTML(text)
        if !html.isEmpty { return html }
        // ★ v1.0.92 兜底：结构解析一条都没出来时，用最笨的办法再捞一次。
        //   宁可"文件夹丢了但书签进来了"，也不要"一条都没进来"。
        return fallbackScan(text)
    }

    /// 一条都没读到时，把「它到底看到了什么」交出来 —— 让失败自己说明白。
    /// ★ 同 v1.0.88 那条规矩：凡"用户看到没生效"的功能，都要留可查证的东西，
    ///   否则下一次还是只能猜。
    static func diagnose(_ data: Data) -> String {
        let text = decode(data)
        let href = text.components(separatedBy: "HREF").count - 1
        let dt = text.components(separatedBy: "<DT>").count - 1
        return "文件 \(data.count / 1024) KB、\(text.count) 个字符；"
             + "里面有 \(href) 处 HREF、\(dt) 处 <DT>。"
             + "把这句话发我就能定位。"
    }

    /// 文本解码：中文书签导出常见 UTF-8；老 Chrome/记事本另存过的可能是 GB18030；
    /// 最后用 Latin-1 兜底（永不失败，至少不会整份读不出来）。
    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Netscape HTML

    /// ★ v1.0.92 重写：**一次扫全篇，不再按行**。
    ///
    /// 为什么必须改：原来假设"一行一个标签"（先按 \n 切行，每行只走一个分支）。
    /// 只要导出工具把整份压成一行、或者一行里既有文件夹又有书签，就会漏掉 ——
    /// 用户那份夸克导出就栽在这类脆弱假设上（实测格式完全标准）。
    ///
    /// 现在用一个正则把四种记号**按出现顺序**一次抓出来，再走一遍栈：
    ///   ① 文件夹 `<DT><H3 ...>名字</H3>`
    ///   ② 书签   `<DT><A HREF="地址" ...>标题</A>`
    ///   ③ 进目录  `<DL ...>`      ④ 出目录 `</DL>`
    private static let tokenRE: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<DT>\s*<H3[^>]*>(.*?)</H3>|<DT>\s*<A\s+HREF\s*=\s*"?([^"\s>]+)"?[^>]*>(.*?)</A>|<DL\b|</DL>"#,
        options: [.caseInsensitive])

    /// 最笨的兜底：不管结构，把所有 HREF + 它后面的标题捞出来（文件夹算没有）
    private static let looseRE: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"HREF\s*=\s*"?([^"\s>]+)"?[^>]*>(.*?)</A>"#,
        options: [.caseInsensitive])

    private static func parseHTML(_ text: String) -> [Entry] {
        guard let re = tokenRE else { return [] }      // 正则都编不出来 → 交给兜底
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [Entry] = []
        var stack: [String] = []           // 文件夹栈（根层是空串）
        var pending: String?               // 刚读到的 <H3> 名字，等它下面的 <DL> 入栈

        for m in matches {
            // ① 文件夹
            if m.range(at: 1).location != NSNotFound {
                pending = decodeEntities(ns.substring(with: m.range(at: 1)))
                continue
            }
            // ② 书签
            if m.range(at: 2).location != NSNotFound {
                let url = decodeEntities(ns.substring(with: m.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                let title = m.range(at: 3).location != NSNotFound
                    ? decodeEntities(ns.substring(with: m.range(at: 3)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                // 最近的**有名字的**祖先文件夹 —— 没有就 nil（= 根目录）
                out.append(Entry(title: title, url: url,
                                 folder: stack.last(where: { !$0.isEmpty })))
                continue
            }
            // ③④ 目录进 / 出
            let whole = ns.substring(with: m.range)
            if whole.hasPrefix("</") {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(pending ?? "")
                pending = nil
            }
        }
        return out
    }

    /// 兜底：只认 HREF，不要结构
    private static func fallbackScan(_ text: String) -> [Entry] {
        guard let re = looseRE else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m -> Entry? in
                guard m.range(at: 1).location != NSNotFound else { return nil }
                let url = decodeEntities(ns.substring(with: m.range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                let title = m.range(at: 2).location != NSNotFound
                    ? decodeEntities(ns.substring(with: m.range(at: 2)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return Entry(title: title, url: url, folder: nil)
            }
    }

    // MARK: - Chromium JSON

    private static func parseChromiumJSON(_ data: Data) -> [Entry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var out: [Entry] = []
        if let roots = obj["roots"] as? [String: Any] {
            for (_, v) in roots {
                if let node = v as? [String: Any] { walk(node, folder: nil, into: &out) }
            }
        } else {
            walk(obj, folder: nil, into: &out)      // 顶层直接就是节点
        }
        return out
    }

    private static func walk(_ node: [String: Any], folder: String?, into out: inout [Entry]) {
        let type = (node["type"] as? String) ?? ""
        let name = (node["name"] as? String) ?? ""
        if type == "url" || (type.isEmpty && node["url"] != nil) {
            let url = ((node["url"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                out.append(Entry(title: name, url: url, folder: folder))
            }
            return
        }
        // 文件夹（或 bookmark_bar / other / synced 这几个根）
        let here = name.isEmpty ? folder : name
        if let kids = node["children"] as? [[String: Any]] {
            for k in kids { walk(k, folder: here, into: &out) }
        }
    }

    // MARK: - 小工具

    /// HTML 实体解码（书签里最常见的几个 + 数字实体）
    private static func decodeEntities(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&hellip;": "…"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        // 数字实体 &#123; / &#x1F600;
        if t.contains("&#") {
            if let re = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
                let ns = t as NSString
                let ms = re.matches(in: t, range: NSRange(location: 0, length: ns.length))
                for m in ms.reversed() {
                    let raw = ns.substring(with: m.range(at: 1))
                    let scalarValue = raw.hasPrefix("x") || raw.hasPrefix("X")
                        ? UInt32(raw.dropFirst(), radix: 16)
                        : UInt32(raw)
                    guard let v = scalarValue, let u = Unicode.Scalar(v) else { continue }
                    t = (t as NSString).replacingCharacters(in: m.range, with: String(Character(u)))
                }
            }
        }
        return t
    }
}
