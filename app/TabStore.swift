import Foundation
import UIKit

/// 一个「标签页组」。
///
/// ★ 为什么要这个：标签能存 30 个之后，全堆在一个网格里也会乱。
///   Safari 的做法是分组（"追剧"、"查资料"各一组），我们照做。
/// ★ 它只是一层「过滤器 + 名字」：标签本身还是存在 BrowserModel 一个扁平数组里，
///   组只记「自己包含哪些标签 id、顺序如何、上次在看哪个」。
///   这样切组不需要搬迁数据，代价最小。
struct TabGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// 无痕组（批次 3 用）—— 字段先留着，行为以后再接
    var isPrivate: Bool = false
    /// 组内标签的 id。**顺序就是网格里显示的顺序**。
    var tabIDs: [UUID] = []
    /// 这个组上次在看哪个标签（切组时回到它）
    var currentTabID: UUID?

    /// 界面上显示的名字（空名字给个默认）
    var displayName: String { name.isEmpty ? "标签页" : name }
}

/// 一个标签档案的持久化形态。
///
/// ★ 只存「下次打开还要用的」这几样。**故意不存**：
///   · 嗅探结果（items/groups）—— 页面重新加载会重新嗅探；存了反而让你看到过期数据
///   · 能不能前进后退 —— 重开是空历史，存了是错的
///   · 加载中 / 错误页状态 —— 重开那一刻没有"正在加载"这回事
struct TabRecord: Codable {
    var id: UUID
    var title: String
    var address: String
    var groupID: UUID
    var lastActiveAt: Date
}

/// 落盘的完整结构（一次写一个文件）。
struct TabStorePayload: Codable {
    var groups: [TabGroup]
    var records: [TabRecord]
    var currentGroupID: UUID?
}

/// 标签档案的落盘。
/// 位置：Application Support/VideoGrab/Tabs/（跟下载记录、收藏同一个根目录）。
/// 缩略图**存成单独的文件**，不塞进 JSON —— base64 会白白膨胀三分之一。
enum TabStore {

    static var dir: URL {
        let d = JobStore.dir.appendingPathComponent("Tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var thumbsDir: URL {
        let d = dir.appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var file: URL { dir.appendingPathComponent("tabs.json") }

    // MARK: - 整体读写

    static func load() -> TabStorePayload? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // 旧版本写的存档字段对不上也不该整个读不出来 → 失败就当没有
        return try? dec.decode(TabStorePayload.self, from: d)
    }

    static func save(_ p: TabStorePayload) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(p) else { return }
        try? d.write(to: file, options: .atomic)
    }

    /// 把存档整个清掉（设置里的「清空标签存档」用；也用于测试）
    static func wipe() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: thumbsDir)
    }

    // MARK: - 缩略图（一个标签一个文件）

    private static func thumbFile(_ id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).png")
    }

    static func saveThumb(_ img: UIImage, id: UUID) {
        guard let d = img.pngData() else { return }
        try? d.write(to: thumbFile(id), options: .atomic)
    }

    static func loadThumb(id: UUID) -> UIImage? {
        guard let d = try? Data(contentsOf: thumbFile(id)) else { return nil }
        return UIImage(data: d)
    }

    static func removeThumb(id: UUID) {
        try? FileManager.default.removeItem(at: thumbFile(id))
    }

    /// 存档里已经不存在的标签，它们的缩略图文件也该删掉（否则越攒越多）。
    static func pruneThumbs(keep ids: Set<UUID>) {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: thumbsDir,
                                                     includingPropertiesForKeys: nil) else { return }
        for u in list {
            let name = u.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else {
                try? fm.removeItem(at: u)     // 认不出的文件名，一并清掉
                continue
            }
            if !ids.contains(id) { try? fm.removeItem(at: u) }
        }
    }
}
