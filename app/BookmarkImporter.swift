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
        return parseHTML(text)
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

    private static func parseHTML(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var stack: [String] = []          // 文件夹栈（根层是空串）
        var pendingFolder: String?        // 刚读到的 <H3> 名字，等它下面的 <DL> 入栈

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // ★ 注意用**原始字符串** #"..."#：正则里的 \s 在普通字符串里是非法转义，
            //   编译器会报 "invalid escape sequence in literal"（run #90 就死在这一行）。
            if line.range(of: #"<DT>\s*<H3"#, options: [.regularExpression, .caseInsensitive]) != nil
                || line.range(of: "<H3", options: .caseInsensitive) != nil,
               let name = group(line, #"<H3[^>]*>(.*?)</H3>"#) {
                pendingFolder = decodeEntities(name)
                continue
            }
            if line.range(of: "<DL", options: .caseInsensitive) != nil {
                stack.append(pendingFolder ?? "")
                pendingFolder = nil
                continue
            }
            if line.range(of: "</DL", options: .caseInsensitive) != nil {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            guard let href = group(line, #"<A\s+HREF\s*=\s*"?([^"\s>]+)"?[^>]*>(.*?)</A>"#)
            else { continue }
            let url = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = decodeEntities(group(line, #"<A[^>]*>(.*?)</A>"#) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            // 最近的**有名字的**祖先文件夹 —— 没有就 nil（= 根目录）
            let folder = stack.last(where: { !$0.isEmpty })
            out.append(Entry(title: title, url: url, folder: folder))
        }
        return out
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

    /// 取第一个捕获组（找不到返回 nil）
    private static func group(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

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
