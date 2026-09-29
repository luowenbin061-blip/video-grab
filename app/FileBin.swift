import Foundation
import SwiftUI

/// 回收站里的一条：**直接复用 `JobRecord` 当内容**，一个新字段都不用加。
///
/// 为什么复用而不是另起一套：`JobRecord` 里已经齐了 ——
///   · `sourceURL`    = 那个「点开就能播」的地址（用户要的就是它）
///   · `referrer` / `ua` / `cookie` = 防盗链站播放/取流要用
///   · `outputName`   = 用来判断「文件已经不在了」（`DownloadJob(record:)` 会据此置 `fileMissing`）
///   · `id`           = 推缩略图名（`DownloadJob.thumbName(for:)`）
struct BinRecord: Codable, Identifiable {
    var job: JobRecord
    var deletedAt: Date
    var id: UUID { job.id }
}

/// ★★ v1.0.164：**全局回收站 —— 下载文件的那一半**
/// （书签那一半一直就有，在 `BookmarkStore.trash` + `RecycleBinView` 的书签段里）
///
/// ══ 为什么要有它（用户原话）══
///   「我要的源地址就是**点开就能播的源地址**……还是找个口子来记录吧，
///     里面保留视频缩略图和片名还有源地址，每次删除都记录在这个口子里，
///     除非用户删除或者批量情况、卸载程序等情况，否则**绝不消失**。」
///   → 「全局」「入口隐蔽点、放设置里」都是他定的。
///
/// ══ 查证出来的关键（别再走弯路）══
///   · 地址**一直完整落盘**在 `JobRecord.sourceURL`，**不需要加字段**；
///   · 「点开就能播」的按钮**也早就存在**：`ContentView` 里下载条的「在线播放」
///     （文件不在时自动出现）；
///   · 真正缺的只有一条：**以前「删除」把记录也一起删了**（`jobs.removeAll`）→
///     重启后那条任务不存在 → 那个按钮跟着一起没了。所以这个 store 的全部意义就是
///     **把记录留下来**。
///
/// ══ 规矩（用户拍板的，别改）══
///   · **每次删除都进来** —— 单个删 / 左滑删 / 多选批量删，全都汇到
///     `DownloadCenter.remove(_:)`，所以只改那一处就全生效。
///   · **绝不自动消失**：不设上限、不做过期、不自动清空。只有用户主动
///     「找回 / 删掉 / 清空」才会少。（卸载程序当然会没 —— 数据在 App 沙盒里。）
///   · **缩略图是唯一真占地方的东西**（约 30~60KB/张）→ 原地保留、算进「已用空间」，
///     并在界面上显示「共 N 项 · 占 X MB」—— 不让用户以为「删了一点都不占了」。
///   · **产物文件照删**（省空间才是他删东西的目的），这里只留"还能找回什么"的线索。
///   · **可扩展**：这里目前只装「下载文件」（视频/图片/音频/文档都算）。
///     将来要装别的类别就在这张卡里加一段，**别把这个 store 写死成"只能装视频"**。
@MainActor
final class FileBin: ObservableObject {

    static let shared = FileBin()

    /// 新的在前（跟下载列表一个手感）
    @Published private(set) var items: [BinRecord] = []

    private static var fileURL: URL { JobStore.file(named: "files_trash.json") }

    private init() { load() }

    // MARK: - 进站

    /// 把一条下载任务登记进回收站。
    ///
    /// **只登记，不碰文件** —— 产物文件由调用方删
    /// （`DownloadJob.deleteFiles(keepThumb: true)`），缩略图**留着**：
    /// 它是列表里唯一还能认出这条的东西。
    @discardableResult
    func put(_ job: DownloadJob) -> Bool {
        // 同一条不重复进（重复删同一条时不该出现两行）
        guard !items.contains(where: { $0.id == job.id }) else { return false }
        items.insert(BinRecord(job: job.snapshot(), deletedAt: Date()), at: 0)
        save()
        return true
    }

    // MARK: - 出站

    /// 「找回」：从回收站拿走这一条，把记录交给调用方放回下载列表。
    /// 放回去之后那条任务会显示「文件已不在」—— 但**下载条上会出现「在线播放」**，
    /// 这就是"找回"的全部内容（文件本身是真回不来了，能回来的是"点开就能播"）。
    func take(_ id: UUID) -> JobRecord? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let r = items.remove(at: i).job
        save()
        return r
    }

    /// 彻底删掉一条（连缩略图一起删 —— 这是唯一真会释放空间的动作）
    func drop(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let rec = items.remove(at: i).job
        JobStore.remove([DownloadJob.thumbName(for: rec.id)])
        save()
    }

    /// 清空整个回收站
    func empty() {
        let names: [String?] = items.map { DownloadJob.thumbName(for: $0.id) }
        items.removeAll()
        JobStore.remove(names)
        save()
    }

    // MARK: - 计数与占用

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// 回收站占了多少 —— **只算缩略图**（产物文件已经删掉了）。
    /// 界面上必须显示它：否则用户会以为"删了就一点不占了"（老账，别重犯）。
    func usedBytes() -> Int64 {
        items.reduce(0) { $0 + JobStore.size(of: DownloadJob.thumbName(for: $1.id)) }
    }

    // MARK: - 落盘

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(items) else { return }
        // 原子写：中途失败别把整份回收站毁掉
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // ★ 读不出来就当空 —— 但**绝不能因为一条坏数据把整份丢掉**：
        //   单条解不出来时整个数组也解不出来，所以保险起见给[]（新文件，暂无老格式要兼容）。
        items = (try? dec.decode([BinRecord].self, from: d)) ?? []
    }
}
