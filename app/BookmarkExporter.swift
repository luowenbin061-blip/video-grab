import Foundation

/// 导出书签（v1.0.102）。
///
/// ★ 为什么用「Netscape 书签 HTML」这一个格式：Chrome / Edge / Firefox / Safari / 夸克 ——
///   **导入导出全都是它**（我们导入时认的也是它）。不用为每家写一套，也不怕以后换浏览器。
///
/// 层级怎么还原：我们的分组是"完整路径"字符串（例如 `书签栏 / AI`），
/// 按 ` / ` 拆开逐层建文件夹 —— 导出来就跟用户在浏览器里看到的一样。
///
/// ★ 取舍（界面上也说了）：HTML 装不下"顺序"和"回收站" ——
///   导出去再由任何浏览器导回来，分组能还原，**拖过的顺序会丢**。
enum BookmarkExporter {

    /// 生成标准 Netscape 书签 HTML 文本
    static func html(marks: [Bookmark]) -> String {
        let root = build(marks)
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        out += render(root, depth: 1)
        out += "</DL><p>\n"
        return out
    }

    /// 写到临时目录，返回文件 URL（给系统的"存到文件"用）
    static func write(marks: [Bookmark]) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let name = "VideoGrab-书签-\(f.string(from: Date())).html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try html(marks: marks).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 内部

    /// 一棵目录树：文件夹名 → 子节点。
    /// ★ 每个节点用 `seq` 记**混排的首次出现顺序**（条目与子文件夹按它们原来的先后）——
    ///   一开始我写成"先列完条目、再列文件夹"，往返一测顺序就变了（本地自查抓到的）。
    private final class Node {
        enum Entry {
            case mark(Bookmark)
            case dir(String)
        }
        var seq: [Entry] = []
        var kids: [String: Node] = [:]
    }

    private static func build(_ marks: [Bookmark]) -> Node {
        let root = Node()
        for m in marks {
            var node = root
            // 分组名是完整路径（`书签栏 / AI`）；没分组的直接放最外层
            let path = (m.folder ?? "")
                .components(separatedBy: " / ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for seg in path {
                if let next = node.kids[seg] {
                    node = next
                } else {
                    let n = Node()
                    node.kids[seg] = n
                    node.seq.append(.dir(seg))      // 文件夹也按首次出现的时机排
                    node = n
                }
            }
            node.seq.append(.mark(m))
        }
        return root
    }

    private static func render(_ node: Node, depth: Int) -> String {
        let pad = String(repeating: "    ", count: depth)
        var out = ""
        for e in node.seq {
            switch e {
            case .mark(let m):
                let sec = Int(m.addedAt.timeIntervalSince1970)
                out += "\(pad)<DT><A HREF=\"\(esc(m.url))\" ADD_DATE=\"\(sec)\">\(esc(m.label))</A>\n"
            case .dir(let name):
                out += "\(pad)<DT><H3>\(esc(name))</H3>\n\(pad)<DL><p>\n"
                out += render(node.kids[name]!, depth: depth + 1)
                out += "\(pad)</DL><p>\n"
            }
        }
        return out
    }

    /// HTML 转义 —— 标题里出现 & < > " 会让浏览器读错（各家导出的文件都做了这一步）
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
