import Combine
import Foundation

/// 收藏的一条网址。
/// 用地址当 id —— 同一个地址不该收藏两次。
struct Bookmark: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var addedAt: Date

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
