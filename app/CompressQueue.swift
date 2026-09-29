import Foundation
import SwiftUI

/// ★★★ v1.0.160：**压缩队列** —— 把「压画质省空间」从"卡片里的一个临时动作"
/// 升级成"**队列化的一等任务**"。
///
/// ══ 为什么非这么改（用户真机反馈，原话）══
///   「程序内压缩文件，此时误关或者关掉压缩页面就会**丢失压缩任务**，
///     虽然说明中显示关掉此页面也会自动保存到下载页，但也不符合交互逻辑」
///   → 以前任务活在**卡片的状态**里：卡片一关，进度无处可看、无法取消、失败了没人告诉你；
///     被系统杀掉之后还会留下一个**没人清**的半成品文件。
///
/// ══ 现在的规矩（都是用户拍板的，别再改）══
///   · **单例** `shared`：卡片开开关关、甚至退出重进，队列都还在（**落盘**）。
///   · **串行，一次只压一个**（`CompressPlan.nextRunIndex` 保证）—— 硬件编码器只有一个，
///     同时跑三个不会更快，只会更烫、每个都变慢。
///   · **上限 20 个**。
///   · **失败一个就跳过、继续压下一个**，原因留在那一行（不再只有笼统一句"没成功"）。
///   · **开工前查空间**：成品和原片同时在，不够就明确拦下来说差多少。
///   · **重启后保持暂停**（跟下载任务同一个约定）：能看到"还有 N 个没压"，点「继续」才跑。
///   · 保活（画中画小窗）默认开，设置里能关（键 `compressKeepAlive`）。
///   · ★★ **压完先不收**：进 `.pending`「待你决定」，行上给
///     看效果 / 留下（收进下载列表）/ 存相册 / 存文件夹 / 丢弃
///     —— 用户明确不要"未经同意就自动存进下载页"。
///
/// ══ 一条硬约束（写在最前面，别指望能做）══
///   ffmpeg 是**在进程内**跑的阻塞调用（不是子进程），**没法从外面掐断** ——
///   所以"停止"的语义只能是「**当前这条压完就停**，还没开始的都作废」。
///   想真正"立刻停"只有杀 App。界面上必须这么说，别假装能做到。
@MainActor
final class CompressQueue: ObservableObject {

    static let shared = CompressQueue()

    // MARK: - 一条任务的状态

    enum Status: String, Codable {
        case waiting, running, failed, cancelled
        /// ★★ v1.0.162：**压好了、还没决定怎么处理**。
        ///   用户明确不要"未经同意就自动存进下载页" —— 所以压完停在这里，
        ///   由他在那一行上选：看效果 / 留下（收进下载列表）/ 存相册 / 存文件夹 / 丢弃。
        case pending
        /// 决定"留下"了（已经收进下载列表）
        case kept
        /// 决定"丢弃"了（成品文件已删，原片没动）
        case discarded

        /// 还算"没处理完"的（角标、汇总都用它）——
        /// ★ pending 也算：不然用户一转头就忘了有几条在等他，那些文件就成了"占着空间看不见"的东西。
        var isLive: Bool {
            switch self {
            case .waiting, .running, .pending: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .waiting:   return "等待中"
            case .running:   return "压缩中"
            case .pending:   return "已压好，待你决定"
            case .kept:      return "已留下（在下载列表）"
            case .discarded: return "已丢弃"
            case .failed:    return "失败"
            case .cancelled: return "已取消"
            }
        }

        /// 调度用的形状（见 `CompressPlan.nextRunIndex`）
        var slot: CompressPlan.Slot {
            switch self {
            case .waiting: return .waiting
            case .running: return .running
            default:       return .other
            }
        }
    }

    // MARK: - 一条任务

    final class Item: ObservableObject, Identifiable {
        let id: UUID
        let title: String
        let kind: DownloadJob.MediaKind
        /// 源文件在**程序目录**（`JobStore.dir`）里的名字。
        /// ★ 外部（相册 / 文件）选来的源**在入队时就搬进来了** —— 系统临时目录随时会被清掉，
        ///   而队列可能跨重启；搬进来之后它就一直在，压到一半被杀也能重来。
        let sourceName: String
        /// 这条源是**我们搬进来的**吗 → 压完就能删（用户的原件在相册里，不需要我们留一份）
        let ownsSource: Bool
        let srcBytes: Int64
        let duration: Double
        let videoTier: CompressPlan.Tier
        let photoTier: CompressPlan.PhotoTier

        @Published var state: Status
        @Published var progress: Double = 0
        @Published var phase: String
        @Published var note: String?          // 成功那句（"✔ 已压缩：49.6MB → 32.5MB（省了 17.1MB）"）
        @Published var failure: String?       // 失败原因（人话）
        @Published var outputName: String?    // 收进下载列表后的文件名（"看效果"要用）

        init(id: UUID = UUID(), title: String, kind: DownloadJob.MediaKind,
             sourceName: String, ownsSource: Bool, srcBytes: Int64, duration: Double,
             videoTier: CompressPlan.Tier, photoTier: CompressPlan.PhotoTier) {
            self.id = id
            self.title = title
            self.kind = kind
            self.sourceName = sourceName
            self.ownsSource = ownsSource
            self.srcBytes = srcBytes
            self.duration = duration
            self.videoTier = videoTier
            self.photoTier = photoTier
            self.state = .waiting
            self.phase = Status.waiting.label
        }

        /// 档位在界面上的说法
        var tierLabel: String {
            kind == .image ? photoTier.title : videoTier.title
        }

        /// 预估成品体积（拉满进度 / 算总空间时用）
        var estimatedBytes: Int64 {
            if kind == .image {
                return CompressPlan.estimatePhotoBytes(tier: photoTier, bytes: srcBytes)
            }
            let bps = CompressPlan.targetVideoBps(
                tier: videoTier,
                sourceBps: CompressPlan.sourceBps(bytes: srcBytes, duration: duration))
            guard bps > 0 else { return 0 }
            return CompressPlan.estimateBytes(videoBps: bps, duration: duration)
        }

        /// 队列那一行上写的那串体积。
        /// ★ 读不到时长（估算=0）时**不要**写成"→ 约 0.0MB"那种假数字 —— 只报源体积。
        var sizeLine: String {
            let src = "\(CompressPlan.mb(srcBytes))MB"
            let est = estimatedBytes
            return est > 0
                ? "\(tierLabel) · \(src) → 约 \(CompressPlan.mb(est))MB"
                : "\(tierLabel) · \(src)"
        }

        /// 落盘形态
        var record: Record {
            Record(id: id, title: title, kindKey: kind.key, sourceName: sourceName,
                   ownsSource: ownsSource, srcBytes: srcBytes, duration: duration,
                   videoTier: videoTier.rawValue, photoTier: photoTier.rawValue,
                   state: state.rawValue, note: note, failure: failure, outputName: outputName)
        }
    }

    /// 落盘形态（跟 `JobRecord` 一个路子：只存元数据，文件在磁盘上）
    struct Record: Codable {
        var id: UUID
        var title: String
        var kindKey: String
        var sourceName: String
        var ownsSource: Bool
        var srcBytes: Int64
        var duration: Double
        var videoTier: String
        var photoTier: String
        var state: String
        var note: String?
        var failure: String?
        var outputName: String?
    }

    /// 入队请求（界面把选中的源 + 档位交进来）
    struct Request {
        let url: URL
        let title: String
        let kind: DownloadJob.MediaKind
        let bytes: Int64
        let duration: Double
        let videoTier: CompressPlan.Tier
        let photoTier: CompressPlan.PhotoTier
    }

    // MARK: - 外面的接线（启动时接一次）

    /// 画中画小窗（保活用）。**weak**：小窗的命归 `DownloadCenter`。
    weak var pip: PiPProgress?
    /// 压完把成品收进下载列表的出口（`adoptCompressed`）。
    weak var center: DownloadCenter?
    /// 「别人还要不要这个小窗」—— 下载还在跑 / 还开着共享时，收工**不许**把小窗收掉。
    var othersNeedPiP: (() -> Bool)?

    /// 保活开关键（设置页同一个键）。**默认开**：
    /// 读默认开的键必须 `object(forKey:) as? Bool ?? true`（`bool(forKey:)` 对没写过的键返回 false）。
    static let keepAliveKey = "compressKeepAlive"
    static var keepAliveEnabled: Bool {
        (UserDefaults.standard.object(forKey: keepAliveKey) as? Bool) ?? true
    }

    // MARK: - 状态

    @Published private(set) var items: [Item] = []
    /// 给画中画小窗看的画面（不在压的时候是 nil）
    @Published private(set) var snapshot: PiPProgress.Snapshot?

    private var runner: Task<Void, Never>?
    /// 这个小窗是**我们**连带起的吗（用户自己开的那个，收工不许替他收掉）
    private var pipByUs = false

    private static var fileURL: URL { JobStore.file(named: "compress_queue.json") }

    private init() {
        load()
        // ★ 上次被杀时**正在压**的那条：ffmpeg 没法续，但它可以**从头再来**
        //   （源文件还在）。所以退回"等待中"，让用户点「继续」时重新压一遍 —— 东西不丢。
        for it in items where it.state == .running {
            it.state = .waiting
            it.phase = "等待中（上次压到一半被中断，会重来）"
            it.progress = 0
        }
    }

    // MARK: - 对外的读数

    var liveCount: Int { items.filter { $0.state.isLive }.count }
    var waitingCount: Int { items.filter { $0.state == .waiting }.count }
    var isRunning: Bool { items.contains { $0.state == .running } }
    var current: Item? { items.first { $0.state == .running } }
    /// 工具箱那一格的小角标：还在排队/在压的条数（0 = 不显示）
    var badgeCount: Int { items.filter { $0.state.isLive }.count }
    var hasFinishedRows: Bool { items.contains { !$0.state.isLive } }

    /// 队列里还需压的那些，预估一共要多少空间
    var waitingOutputBytes: Int64 {
        items.filter { $0.state == .waiting }.reduce(0) { $0 + max(0, $1.estimatedBytes) }
    }

    // MARK: - 入队

    /// 返回 nil = 入队成功；否则是**拒绝原因**（人话，直接显示给用户）
    @discardableResult
    func enqueue(_ r: Request) -> String? {
        guard liveCount < CompressPlan.maxQueue else {
            return "队列满了（最多同时排 \(CompressPlan.maxQueue) 个）。等压完几个再加。"
        }
        guard FileManager.default.fileExists(atPath: r.url.path) else {
            return "这个文件读不到了（可能已经被删了）。"
        }

        // ★ 外部选来的源：**搬进程序目录**再用（临时目录随时会被系统清掉）
        var name = r.url.lastPathComponent
        var owns = false
        let inOurDir = r.url.deletingLastPathComponent().standardizedFileURL ==
                       JobStore.dir.standardizedFileURL
        if !inOurDir {
            let unique = "源_" + Self.stamp() + "_" + name
            let dest = JobStore.file(named: unique)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: r.url, to: dest)
                name = unique
                owns = true
            } catch {
                // 挪不动就退回"复制一份"（宁可多占一次，也别让队列指着临时文件）
                do {
                    try FileManager.default.copyItem(at: r.url, to: dest)
                    name = unique
                    owns = true
                } catch {
                    return "这个文件搬不进来：\(error.localizedDescription)"
                }
            }
        }

        items.append(Item(title: r.title, kind: r.kind, sourceName: name, ownsSource: owns,
                          srcBytes: r.bytes, duration: r.duration,
                          videoTier: r.videoTier, photoTier: r.photoTier))
        save()
        return nil
    }

    /// 取消一条**还没开始**的
    func cancel(_ item: Item) {
        guard item.state == .waiting else { return }
        item.state = .cancelled
        item.phase = Status.cancelled.label
        retire(item)
        save()
    }

    /// 停止：「**当前这条压完就停**，还没开始的都作废」。
    /// ★ 为什么不能立刻停：ffmpeg 是在进程内跑的阻塞调用，外面掐不断（见文件头）。
    func stopAfterCurrent() {
        for it in items where it.state == .waiting {
            it.state = .cancelled
            it.phase = "已取消（点了停止）"
            retire(it)
        }
        save()
    }

    /// 待处理的条数 / 一共占多少（用**实际文件大小**，不是预估）
    var pendingCount: Int { items.filter { $0.state == .pending }.count }
    var pendingBytes: Int64 {
        items.filter { $0.state == .pending }.reduce(0) { $0 + JobStore.size(of: $1.outputName) }
    }

    /// 「留下」= 收进下载列表（跟"导入视频"同一个归宿）。
    /// ★ 走 `adoptCompressed`（**只认领不搬不改名**）：名字一动，行上的"看效果"就扑空。
    func keep(_ item: Item) {
        guard item.state == .pending, let out = item.outputName else { return }
        center?.adoptCompressed(JobStore.file(named: out),
                                title: item.title + "_压缩版", kind: item.kind)
        item.state = .kept
        item.phase = Status.kept.label
        save()
    }

    /// 「丢弃」= 删掉成品。**原片一律不动。**
    func discard(_ item: Item) {
        guard item.state == .pending, let out = item.outputName else { return }
        try? FileManager.default.removeItem(at: JobStore.file(named: out))
        item.state = .discarded
        item.phase = Status.discarded.label
        item.note = nil
        save()
    }

    /// 一键处理（20 条一条条点太烦 —— 用户要"逐条决定"，但别逼他点 40 下）
    func keepAll() { for it in items where it.state == .pending { keep(it) } }
    func discardAll() { for it in items where it.state == .pending { discard(it) } }

    /// 清掉"已经结束"的那些行（成品已经收进下载列表，删行不动文件）
    func clearFinished() {
        items.removeAll { !$0.state.isLive }
        save()
    }

    // MARK: - 跑

    /// 开始 / 继续。返回 nil = 开跑了；否则是**拒绝原因**（人话）。
    @discardableResult
    func start() -> String? {
        guard runner == nil, !isRunning else { return nil }        // 已经在跑，不用管
        guard waitingCount > 0 else { return nil }

        // ★ 开工前查空间：成品和原片同时在，别压到一半没地方写
        let need = CompressPlan.spaceNeeded(outputBytes: waitingOutputBytes)
        let free = JobStore.deviceFreeSpace
        guard need <= free else {
            return "空间不够：这一批大约还要 \(CompressPlan.mb(need))MB，现在只剩 "
                 + "\(CompressPlan.mb(free))MB。先删几条（或删掉些下载）再开始。"
        }

        beginKeepAlive()
        runner = Task { [weak self] in await self?.runLoop() }
        return nil
    }

    private func runLoop() async {
        while let idx = CompressPlan.nextRunIndex(slots: items.map { $0.state.slot }) {
            let item = items[idx]
            item.state = .running
            item.phase = "正在压缩…"
            item.progress = 0
            setSnapshot(item, detail: "正在压缩…", progress: 0)
            save()

            do {
                let r = try await compress(item)
                item.outputName = r.url.lastPathComponent
                item.note = r.note
                item.state = .pending
                item.progress = 1
                item.phase = Status.pending.label
                // ★★ v1.0.162（用户第 3 条）：**不再自动收进下载列表** ——
                //   "未经同意默认存进下载页"是他明确不满的地方。
                //   现在停在"待你决定"，由 `keep()` / `discard()` 明确处理
                //   （keep 才走 `adoptCompressed`：只认领不搬不改名）。
            } catch {
                // ★ 失败**只影响这一条**：原因留下，继续压下一个
                item.failure = error.localizedDescription
                item.state = .failed
                item.phase = Status.failed.label
            }
            retire(item)
            save()
        }
        finishKeepAlive()
        runner = nil
        save()
    }

    private func compress(_ item: Item) async throws -> (url: URL, bytes: Int64, note: String) {
        let input = JobStore.file(named: item.sourceName)
        let onP: (Double, String) -> Void = { [weak self] p, msg in
            Task { @MainActor in
                item.progress = p
                item.phase = msg
                self?.setSnapshot(item, detail: msg, progress: p)
            }
        }
        if item.kind == .image {
            return try await Compressor.runPhoto(input: input, tier: item.photoTier, onProgress: onP)
        }
        return try await Compressor.run(input: input, tier: item.videoTier, onProgress: onP)
    }

    /// 一条任务走到头了：把我们搬进来的源文件清掉（用户的原件在相册里，不用我们留）
    private func retire(_ item: Item) {
        guard item.ownsSource else { return }
        try? FileManager.default.removeItem(at: JobStore.file(named: item.sourceName))
    }

    // MARK: - 保活（画中画小窗）

    private func beginKeepAlive() {
        guard Self.keepAliveEnabled, let pip, !pip.isRunning else { return }
        // ★ 必须在**前台**调（进了后台再起画中画必失败，跟"共享给电脑"同一个道理）
        pip.start()
        pipByUs = true
    }

    private func setSnapshot(_ item: Item, detail: String, progress: Double) {
        guard pipByUs else { return }        // 没开保活就别折腾小窗
        snapshot = PiPProgress.Snapshot(title: item.title, detail: detail,
                                        progress: progress, activeCount: 1)
    }

    private func finishKeepAlive() {
        snapshot = nil
        guard pipByUs, let pip else { return }
        pipByUs = false
        // 下载还在跑 / 还开着共享 → 那个小窗还有用，不能收
        if othersNeedPiP?() == true { return }
        pip.stop()
    }

    // MARK: - 落盘

    private func save() {
        let recs = items.map(\.record)
        guard let d = try? JSONEncoder().encode(recs) else { return }
        // 原子写：别让中途失败毁掉整份队列
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: Self.fileURL),
              let recs = try? JSONDecoder().decode([Record].self, from: d) else { return }
        items = recs.compactMap { r in
            guard let k = DownloadJob.MediaKind(key: r.kindKey),
                  let vt = CompressPlan.Tier(rawValue: r.videoTier),
                  let pt = CompressPlan.PhotoTier(rawValue: r.photoTier) else { return nil }
            // ★ 兼容 v1.0.161 落盘的 "done"：那一版"压完就自动收进下载列表"了，
            //   所以现在按"已留下"读回来最贴切（别丢行 —— 丢了就等于无声无息）。
            let st = Status(rawValue: r.state == "done" ? Status.kept.rawValue : r.state)
            guard let st else { return nil }
            let it = Item(id: r.id, title: r.title, kind: k, sourceName: r.sourceName,
                          ownsSource: r.ownsSource, srcBytes: r.srcBytes, duration: r.duration,
                          videoTier: vt, photoTier: pt)
            it.state = st
            it.phase = (st == .running) ? Status.waiting.label : st.label
            it.note = r.note
            it.failure = r.failure
            it.outputName = r.outputName
            return it
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
