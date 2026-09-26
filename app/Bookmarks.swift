import Combine
import Foundation

/// 收藏的一条网址。
/// 用地址当 id —— 同一个地址不该收藏两次。
struct Bookmark: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var addedAt: Date

    /// 书签文件里的文件夹名（v1.0.90 新加）。**手动收藏的条目是 nil** ——
    /// 靠这个值在收藏页把「导入的书签」单独归一组。
    ///
    /// ★ 为什么加字段不会让老收藏读不出来：它是**可选**类型，
    ///   合成 Codable 对可选字段用的是 decodeIfPresent（缺键就当 nil），
    ///   不是 decode（缺键直接抛错）。这条规矩见 v1.0.85 的存档容错。
    var folder: String? = nil

    var label: String { title.isEmpty ? url : title }
    var host: String { URL(string: url)?.host ?? "" }
    var timeText: String { Bookmark.fmt.string(from: addedAt) }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
}

/// 历史的一条：**同一个地址只占一条**，记次数 + 最近一次时间。
/// （不做的话，一个视频站来回点几次，列表就全是同一页刷屏了。）
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Date

    var label: String { title.isEmpty ? url : title }
    var host: String { URL(string: url)?.host ?? "" }

    var timeText: String {
        let cal = Calendar.current
        let hm = HistoryEntry.hm.string(from: lastVisit)
        if cal.isDateInToday(lastVisit) { return "今天 \(hm)" }
        if cal.isDateInYesterday(lastVisit) { return "昨天 \(hm)" }
        return HistoryEntry.mdhm.string(from: lastVisit)
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let mdhm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
}

/// 收藏 + 历史。
///
/// 存在 Application Support/VideoGrab/bookmarks.json（跟下载记录同一个目录）。
///
/// ★ 绝不能放进局域网共享目录 —— 那个目录同一个 Wi-Fi 下拿到地址就能浏览，
///   放进去等于把「你看过什么、收藏了什么」公开。这是这个项目定死的规矩。
final class BookmarkStore: ObservableObject {

    @Published private(set) var marks: [Bookmark] = []
    @Published private(set) var history: [HistoryEntry] = []

    /// 历史最多留这么多条，超了丢最旧的 —— 别让它无限涨
    private let historyLimit = 500

    private struct Payload: Codable {
        var marks: [Bookmark]
        var history: [HistoryEntry]
    }

    private static var fileURL: URL {
        JobStore.dir.appendingPathComponent("bookmarks.json")
    }

    init() { load() }

    // MARK: - 收藏

    func isMarked(_ url: String) -> Bool { marks.contains { $0.url == url } }

    /// 收藏 / 取消收藏走同一个入口（看当前状态决定），返回操作后是否已收藏
    @discardableResult
    func toggleMark(url: String, title: String) -> Bool {
        guard Self.usable(url) else { return false }
        if let i = marks.firstIndex(where: { $0.url == url }) {
            marks.remove(at: i)
        } else {
            marks.insert(Bookmark(url: url, title: title, addedAt: Date()), at: 0)
        }
        save()
        return isMarked(url)
    }

    func removeMark(url: String) {
        marks.removeAll { $0.url == url }
        save()
    }

    func clearMarks() {
        marks.removeAll()
        save()
    }

    // MARK: - 导入（v1.0.90）

    /// 批量导入书签。**按网址去重**，返回（新增, 更新分组, 跳过）。
    ///
    /// 导入的条目带上文件里的**完整文件夹路径**（`folder`），收藏页按它分组 ——
    /// 这样显示出来就跟你导出的结构一致。
    ///
    /// ★ v1.0.93：对**已经存在**的地址，如果这次带到了文件夹信息、且跟旧的不一样，
    ///   就**就地更新它的分组**（计入"更新"）而不是干跳过。
    ///   为什么必须这样：v1.0.92 存的是"最近一层文件夹名"，已经导进去的 145 条都是旧分组；
    ///   没有这条，用户就非得先清空再重导一次才能看到正确分组。
    ///   现在「重新导一次同一个文件」就是修复动作。
    @discardableResult
    func importMarks(_ entries: [BookmarkImporter.Entry]) -> (added: Int, updated: Int, skipped: Int) {
        var added = 0
        var updated = 0
        var skipped = 0
        var indexByURL: [String: Int] = [:]
        for (i, m) in marks.enumerated() { indexByURL[m.url] = i }

        var seen = Set<String>()
        var fresh: [Bookmark] = []
        for e in entries {
            guard Self.usable(e.url) else { skipped += 1; continue }
            if seen.contains(e.url) { skipped += 1; continue }   // 同一个文件里重复出现
            seen.insert(e.url)

            if let i = indexByURL[e.url] {
                if let f = e.folder, marks[i].folder != f {
                    marks[i].folder = f          // 补上 / 修正分组
                    updated += 1
                } else {
                    skipped += 1
                }
                continue
            }
            fresh.append(Bookmark(url: e.url, title: e.title,
                                  addedAt: Date(), folder: e.folder))
            added += 1
        }
        // 刚导完，用户最想看的就是它们 → 放最前面
        marks.insert(contentsOf: fresh, at: 0)
        save()
        return (added, updated, skipped)
    }

    // MARK: - 历史

    /// 打开一个页面就记一笔：同地址合并、并移到最前
    func record(url: String, title: String) {
        guard Self.usable(url) else { return }
        if let i = history.firstIndex(where: { $0.url == url }) {
            var h = history[i]
            h.visits += 1
            h.lastVisit = Date()
            if !title.isEmpty { h.title = title }
            history.remove(at: i)
            history.insert(h, at: 0)
        } else {
            history.insert(HistoryEntry(url: url, title: title, visits: 1, lastVisit: Date()),
                           at: 0)
        }
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        save()
    }

    func removeHistory(url: String) {
        history.removeAll { $0.url == url }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    /// about:blank / 空串 / data: 都不是「访问过的页面」，不进收藏也不进历史
    private static func usable(_ url: String) -> Bool {
        !url.isEmpty && url != "about:blank" && !url.hasPrefix("data:")
    }

    // MARK: - 落盘

    private func load() {
        guard let d = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let p = try? dec.decode(Payload.self, from: d) else { return }
        marks = p.marks
        history = p.history
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(Payload(marks: marks, history: history)) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }
}
