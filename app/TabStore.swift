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

    // ★ 容错解码（v1.0.85）：**每个字段都用 decodeIfPresent + 默认值**。
    //   为什么必须这样：Swift 合成的 Codable 对「非可选字段」用的是 decode ——
    //   存档里少一个键就整个解码失败 → 上层拿到 nil → **标签一次性全丢，而且一声不响**。
    //   也就是说：以后只要给这个结构加一个新字段，所有老用户的标签就会没。
    //   现在「缺失 / 类型不对 / 是 null」三种情况都退回默认值，加字段再也不会炸。
    private enum CodingKeys: String, CodingKey {
        case id, name, isPrivate, tabIDs, currentTabID
    }

    /// ★ 必须有：一旦写了自定义 init(from:) 编译器就**不再生成 memberwise 初始化器**，
    ///   而 BrowserModel 里是用 `TabGroup(name:)` / `TabGroup(name:tabIDs:)` 建的。
    ///   （这就是"改 Codable"最容易崩的地方 —— 本地结构检查看不出来，只有真编译器认。）
    init(id: UUID = UUID(), name: String, isPrivate: Bool = false,
         tabIDs: [UUID] = [], currentTabID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.tabIDs = tabIDs
        self.currentTabID = currentTabID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(UUID.self, .id, UUID())
        name = c.soft(String.self, .name, "")
        isPrivate = c.soft(Bool.self, .isPrivate, false)
        tabIDs = c.soft([UUID].self, .tabIDs, [])
        currentTabID = c.softOptional(UUID.self, .currentTabID)
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, title, address, groupID, lastActiveAt
    }

    init(id: UUID, title: String, address: String, groupID: UUID, lastActiveAt: Date) {
        self.id = id; self.title = title; self.address = address
        self.groupID = groupID; self.lastActiveAt = lastActiveAt
    }

    /// 同上（v1.0.85）：缺字段不许把整份存档带崩
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(UUID.self, .id, UUID())
        title = c.soft(String.self, .title, "")
        address = c.soft(String.self, .address, "")
        groupID = c.soft(UUID.self, .groupID, UUID())
        // 缺时间戳就当作「很久没用过」—— 这样它会被优先休眠，而不是被误当成刚用过
        lastActiveAt = c.soft(Date.self, .lastActiveAt, .distantPast)
    }
}

/// 宽容解码的小工具（v1.0.85）。
/// 目的只有一个：**存档多一个/少一个字段，都不该让用户的标签消失。**
private extension KeyedDecodingContainer {

    /// 取值：字段缺失 / 类型不对 / 是 null —— 三种情况都退回默认值，绝不抛。
    ///
    /// ★ 为什么写成 do/catch 而不是 `try?`：Swift 5 起 `try?` 会把可选值**压平**
    ///   （`T??` → `T?`），再叠 `?? nil` 那种写法容易踩到"左边不是可选"的编译错。
    ///   do/catch 语义直白，没有这个坑。
    func soft<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        do { return try decodeIfPresent(type, forKey: key) ?? fallback }
        catch { return fallback }
    }

    /// 可空字段的宽容版（缺失 / 类型不对都当没有）
    func softOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do { return try decodeIfPresent(type, forKey: key) }
        catch { return nil }
    }
}

/// 落盘的完整结构（一次写一个文件）。
struct TabStorePayload: Codable {
    var groups: [TabGroup]
    var records: [TabRecord]
    var currentGroupID: UUID?

    private enum CodingKeys: String, CodingKey {
        case groups, records, currentGroupID
    }

    init(groups: [TabGroup], records: [TabRecord], currentGroupID: UUID?) {
        self.groups = groups; self.records = records; self.currentGroupID = currentGroupID
    }

    /// 同上（v1.0.85）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.soft([TabGroup].self, .groups, [])
        records = c.soft([TabRecord].self, .records, [])
        currentGroupID = c.softOptional(UUID.self, .currentGroupID)
    }
}

/// 标签档案的落盘。
/// 位置：Application Support/VideoGrab/Tabs/（跟下载记录、收藏同一个根目录）。
/// 缩略图**存成单独的文件**，不塞进 JSON —— base64 会白白膨胀三分之一。
enum TabStore {

    /// 最近一次读写失败的原因。**nil = 一切正常。**
    /// ★ 为什么必须有它：以前 load() 是 `try?` —— 读失败就返回 nil，上层当成「没有存档」，
    ///   用户看到的只是「标签莫名其妙全没了」，而且不知道为什么。
    ///   本项目的铁律：失败必须留痕、必须能显示出来，不许被静默吞掉。
    private(set) static var lastError: String?

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
        lastError = nil
        // ★ 先分清「本来就没有存档」和「有存档但读不出来」——
        //   前者是正常（第一次用 / 你手动清过），后者**必须告诉用户**。
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let d = try Data(contentsOf: file)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(TabStorePayload.self, from: d)
        } catch {
            lastError = "存档读取失败（\(error.localizedDescription)）"
            return nil
        }
    }

    /// 返回是否写成功。**写失败不再静默**（以前是两处 `try?` 全吞掉）。
    @discardableResult
    static func save(_ p: TabStorePayload) -> Bool {
        lastError = nil
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            let d = try enc.encode(p)
            try d.write(to: file, options: .atomic)
            return true
        } catch {
            lastError = "存档写入失败（\(error.localizedDescription)）"
            return false
        }
    }

    /// 把存档整个清掉（设置里的「清空标签存档」用；也用于测试）
    static func wipe() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: thumbsDir)
    }

    // MARK: - 缩略图（一个标签一个文件）

    /// 缩略图存成 **JPEG**（v1.0.86 起）。
    /// ★ 为什么换：网页截图是**连续色调**的位图，PNG（无损）在这种内容上效率极差 ——
    ///   实测 15 张 7.5 MB，换 JPEG 只要约 1 MB。缩略图只看个大概，0.8 的画质足够。
    private static func thumbFile(_ id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// 老版本（PNG）的缩略图文件。
    /// ★ 必须有这一层：不做迁移的话，一升级老用户的缩略图就**全没了** ——
    ///   而这纯属我们自己换格式造成的，不该让用户买单。读到老文件就顺手转成 JPEG。
    private static func legacyThumbFile(_ id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).png")
    }

    static func saveThumb(_ img: UIImage, id: UUID) {
        guard let d = img.jpegData(compressionQuality: 0.8) else { return }
        try? d.write(to: thumbFile(id), options: .atomic)
    }

    static func loadThumb(id: UUID) -> UIImage? {
        // 先找新版 JPEG
        if let d = try? Data(contentsOf: thumbFile(id)), let img = UIImage(data: d) {
            return img
        }
        // 再找老版 PNG —— 找到就**顺手迁移**（存成 JPEG、删掉旧的），只付一次代价
        guard let d = try? Data(contentsOf: legacyThumbFile(id)),
              let img = UIImage(data: d) else { return nil }
        saveThumb(img, id: id)
        try? FileManager.default.removeItem(at: legacyThumbFile(id))
        return img
    }

    static func removeThumb(id: UUID) {
        try? FileManager.default.removeItem(at: thumbFile(id))
        try? FileManager.default.removeItem(at: legacyThumbFile(id))   // 老的也一起清
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
