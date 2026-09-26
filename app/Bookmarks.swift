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
    /// 手动新建的分组名（v1.0.94）。
    /// ★ 为什么需要单独存：我们现在的"分组"不是实体，是**从书签身上的 folder 推导出来的** ——
    ///   所以一个"还没有任何书签的空分组"根本无处安放。新建分组就得有地方记它。
    @Published private(set) var customGroups: [String] = []

    /// 历史最多留这么多条，超了丢最旧的 —— 别让它无限涨
    private let historyLimit = 500

    private struct Payload: Codable {
        var marks: [Bookmark]
        var history: [HistoryEntry]
        /// ★ 可选：老版本写的记录里没有这个键 → 合成 Codable 用 decodeIfPresent，
        ///   不会因为缺键让整份收藏读不出来。
        var customGroups: [String]?
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
        customGroups.removeAll()
        save()
    }

    // MARK: - 分组管理（v1.0.94）
    //
    // ★ 现状说明（重要）：我们的"分组"不是实体，只是每条书签身上的一个**名字**。
    //   所以这里所有操作都是"按名字批量改"。好处是改动小；代价是**改不了中间层**
    //   （「书签栏」和「书签栏 / AI」是两个独立的名字，没有父子关系）。

    /// 当前所有分组名：已有的（从书签推导）+ 手动建的（可能是空的）。排好序。
    var allGroups: [String] {
        var s = Set(marks.compactMap { $0.folder })
        s.formUnion(customGroups)
        s.remove("")
        return s.sorted()
    }

    /// 某个分组里有几条书签（删分组确认框要用）
    func count(inGroup name: String) -> Int {
        marks.filter { $0.folder == name }.count
    }

    /// 新建一个空分组。重名 / 空名 → 返回 false
    @discardableResult
    func createGroup(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !allGroups.contains(n) else { return false }
        customGroups.append(n)
        customGroups = Array(Set(customGroups)).sorted()
        save()
        return true
    }

    /// 重命名分组：该组下所有书签跟着改名；手动建的空组也一起改。
    /// 改名后跟另一个已有分组重名 → **合并到那个组**（Safari 也是这个行为）。
    @discardableResult
    func renameGroup(_ from: String, to: String) -> Bool {
        let n = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != from else { return false }
        for i in marks.indices where marks[i].folder == from { marks[i].folder = n }
        if let k = customGroups.firstIndex(of: from) { customGroups[k] = n }
        customGroups = Array(Set(customGroups)).sorted()
        save()
        return true
    }

    /// 删除分组。
    /// - alsoDelete = true：连里面的书签一起删（Safari 删文件夹就是这个行为）
    /// - alsoDelete = false：只解散分组，里面的书签回到「我的收藏」（不丢东西）
    /// 用户要求"每次问我一下"，所以调用方要先弹确认框再进来。
    func deleteGroup(_ name: String, alsoDelete: Bool) {
        if alsoDelete {
            marks.removeAll { $0.folder == name }
        } else {
            for i in marks.indices where marks[i].folder == name { marks[i].folder = nil }
        }
        customGroups.removeAll { $0 == name }
        save()
    }

    /// 把一条书签移到别的分组（`to` 传 nil = 回到「我的收藏」）
    func moveMark(url: String, to folder: String?) {
        guard let i = marks.firstIndex(where: { $0.url == url }) else { return }
        marks[i].folder = folder
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
        customGroups = p.customGroups ?? []      // 老记录没这个键 → 空数组
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let p = Payload(marks: marks, history: history, customGroups: customGroups)
        guard let d = try? enc.encode(p) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }
}
