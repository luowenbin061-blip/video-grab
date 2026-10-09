import Foundation

/// ★ v1.0.250：磁力「边下边播」的**流快照** ——
///   主线程（MagnetEngine）负责写，HTTP 后台线程（LocalHTTPServer 读文件那段）负责读，
///   所以它得待在两边都够得着的中立位置（文件级类型 + 一把自己的小锁）。
final class TorrentStreamBox {
    let lock = NSLock()
    var engine: LTEngine?
    var tid: Int32 = -1
    var files: [MagnetStatus.File] = []
    var root: String = ""
}

/// 全局唯一实例（文件级不可变引用，不受任何 actor 隔离 —— 后台线程能直接拿）。
let torrentStreamBox = TorrentStreamBox()

/// 磁力（BT）引擎的 Swift 包装：拿住 C 句柄、定时轮询、把状态变成 `@Published`。
///
/// ★ 为什么是**单例**：BT 下载动辄十几分钟，用户不可能一直开着那张卡。
///   跟工程里的 `CompressQueue.shared` / `MergeQueue.shared` 一个路子 ——
///   卡片只是"看一眼"的窗口，活要活在别处。
///
/// ★★ v1.0.249 起引擎**常驻**：`handle` 建过一次就不再销毁 ——
///   DHT 路由表是"越养越熟"的东西（再加上桥接层会把路由表存盘、下次热启动）。
///   以前每次开新链接都把整个会话推倒重建，头一两分钟永远接不进网络，
///   是用户实测"测了好多链接大多失败"的一大来源。现在换链接只换**任务**。
///
/// ★ 轮询而不是回调：桥接层是 C 接口，没有回调通道；每 0.5 秒 poll 一次
///   拿一段 JSON 是最省事也最不容易出错的做法（JSON 出一个大缓冲区，不涉及跨线程所有权）。
@MainActor
final class MagnetEngine: ObservableObject {

    static let shared = MagnetEngine()

    /// 引擎刚 poll 回来的状态。
    @Published private(set) var snap = MagnetStatus.Snapshot()
    /// 出错（起不来 / 引擎没回话）。
    @Published private(set) var error: String?
    /// 用户勾选的文件下标。
    @Published var selected: Set<Int> = []
    /// libtorrent 版本号 —— 界面上不显示，但"库到底链上没有"靠它一眼确认。
    @Published private(set) var version: String = ""
    /// ★ v1.0.248：这次任务什么时候开始的 —— 界面用它算"已经等了多久"。
    ///   为的是区分"刚起步（头十几秒 DHT 还没连上很正常）"和
    ///   "等半天一个节点都没有（那是真有问题）"。
    @Published private(set) var startedAt: Date?

    private var handle: LTEngine?
    private var tid: Int32 = -1
    private var pump: Task<Void, Never>?
    /// 元数据第一次到手时自动套用一次默认勾选（只套一次）。
    private var appliedDefault = false
    /// 下完只登记一次。
    private var adopted = false
    /// ★ v1.0.250：用户点过「开始下载」没有 —— 没点之前只把文件列表列出来，**不自动下载**。
    ///   （@Published：界面要从"待开始"切到"下载中"）
    @Published private(set) var userStarted = false

    /// 文件落到哪 —— 单独一个子目录，免得跟"下载页"的东西混在一起。
    /// （下完会由 `adopt` 把它们正式登记进下载中心，那时才挪进主目录。）
    var saveRoot: URL {
        JobStore.dir.appendingPathComponent("torrent", isDirectory: true)
    }

    private init() {
        version = String(cString: lt_bridge_version())
    }

    var running: Bool { handle != nil && tid >= 0 }

    /// 元数据还没到手（文件列表还看不到）。
    var waitingForMeta: Bool { running && !snap.metaReady }

    // MARK: - 起停

    /// 加一条磁力链接（换任务：引擎保留）。返回 false = 起不来（界面据此报错）。
    @discardableResult
    func start(magnet: String) -> Bool {
        // ★★ v1.0.249：**不再销毁整个引擎**。
        //   旧行为：stop() → lt_engine_free() → 每次开新链接都把整个会话
        //   （含 DHT 路由表）连根拔掉重建 → 头一两分钟永远处于"还没接进 BT 网络"的状态。
        //   用户实测"测了好多链接大多失败"，很大一部分就栽在这儿。
        //   现在：只把**上一个任务**移除；引擎（DHT / 连接）一直养着 ——
        //   测的链接越多，网络越热。
        // ★ v1.0.250：先清掉上一条任务留在 torrent 目录里的半成品（换任务 = 放弃它），
        //   免得"孤儿文件"越堆越多、还没入口能删。
        cleanupCurrentFiles()
        stopCurrent()
        error = nil
        adopted = false
        appliedDefault = false
        userStarted = false
        snap = MagnetStatus.Snapshot()
        selected = []

        let fm = FileManager.default
        try? fm.createDirectory(at: saveRoot, withIntermediateDirectories: true)

        guard let h = ensureEngine() else {
            error = "BT 引擎起不来（库没链上？）"
            return false
        }
        let id = lt_engine_add_magnet(h, magnet)
        guard id >= 0 else {
            error = "这条磁力链接解析不了"
            return false
        }
        tid = id
        startedAt = Date()
        startPump()
        return true
    }

    /// 引擎只起一次、之后一直活着（DHT 不重置）。
    private func ensureEngine() -> LTEngine? {
        if let h = handle { return h }
        guard let h = lt_engine_new(saveRoot.path) else { return nil }
        handle = h
        return h
    }

    /// 停止**当前任务**（引擎不动 —— DHT 继续养着，下次开新链接不再从零爬）。
    func stopCurrent() {
        pump?.cancel()
        pump = nil
        if let h = handle, tid >= 0 {
            lt_engine_remove(h, tid)
        }
        tid = -1
        startedAt = nil
        // ★ v1.0.250：流快照一并失效 —— 旧播放器的 HTTP 请求自然 404（tid 对不上）。
        torrentStreamBox.lock.lock()
        torrentStreamBox.engine = nil
        torrentStreamBox.tid = -1
        torrentStreamBox.files = []
        torrentStreamBox.lock.unlock()
    }

    private func startPump() {
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.tick()
                if !self.running { return }
            }
        }
    }

    private func tick() {
        guard let h = handle, tid >= 0 else { return }
        var buf = [CChar](repeating: 0, count: 1 << 19)      // 512 KB：文件多的种子也装得下
        let n = lt_engine_poll(h, tid, &buf, Int32(buf.count))
        guard n > 0 else {
            if n == -2 { error = "任务不见了（引擎那边已经把它移除）" }
            return
        }
        guard let s = MagnetStatus.parse(String(cString: buf)) else {
            error = "引擎回的格式不对（可能是文件太多、列表被截断了）"
            return
        }
        error = nil
        snap = s

        // ★ v1.0.250：把最新快照放进流盒（后台线程给播放器「边等边读」用）。
        torrentStreamBox.lock.lock()
        torrentStreamBox.engine = h
        torrentStreamBox.tid = tid
        torrentStreamBox.files = s.metaReady ? s.files : []
        torrentStreamBox.root = saveRoot.path
        torrentStreamBox.lock.unlock()

        // 元数据刚到 → 按默认规则勾一次（只下视频，种子里那些广告图/说明文件不碰）
        // ★ v1.0.250：**先别自动开下** —— 列表列出来，等用户点「开始下载」。
        //   （以前这里直接 applySelection = 立刻开下，用户反馈「只是看看也会自动下」。）
        if s.metaReady && !appliedDefault {
            appliedDefault = true
            selected = MagnetStatus.defaultSelection(in: s.files)
            if userStarted {
                applySelection()
            } else {
                lt_engine_select_none(h, tid)   // 全挡下：连接 / DHT 照常跑着，只是不拉数据
            }
        }
    }

    // MARK: - 挑文件

    /// 把当前勾选应用到引擎（改优先级）。**已经下过的数据不会丢**。
    func applySelection() {
        guard let h = handle, tid >= 0 else { return }
        let idx = selected.sorted()
        if idx.isEmpty {
            // ★ v1.0.250：空勾选 = **全都不下**（旧语义"空 = 全都下"是个坑：
            //   点「都不选」反而全部开下）。「开始下载」那边会挡住空选的情况。
            lt_engine_select_none(h, tid)
        } else {
            var arr = idx.map { Int32($0) }
            lt_engine_select_files(h, tid, &arr, Int32(arr.count))
        }
    }

    /// ★ v1.0.250：勾选变化时调 —— **只有"已经开始下载"才真的下发优先级**；
    ///   还没开始时只改本地勾选（不然"点一下勾选框"就等于偷偷开始下载了）。
    func applySelectionIfStarted() {
        guard userStarted else { return }
        applySelection()
    }

    func selectAll() {
        selected = Set(snap.files.map(\.index))
        applySelectionIfStarted()
    }

    func selectNone() {
        selected = []
        applySelectionIfStarted()
    }

    func pause(_ p: Bool) {
        guard let h = handle, tid >= 0 else { return }
        lt_engine_pause(h, tid, p ? 1 : 0)
    }

    // MARK: - v1.0.250：开始 / 暂停 / 删除 / 边播

    /// 用户点了「开始下载」—— 从现在起数据开始拉、勾选变化实时生效。
    func beginDownload() {
        guard snap.metaReady, !selected.isEmpty else { return }
        userStarted = true
        applySelection()
    }

    /// 暂停 / 继续（toggle）。★ 以前按钮只会暂停、恢复不了 —— 这次修掉。
    func togglePause() {
        guard let h = handle, tid >= 0 else { return }
        lt_engine_pause(h, tid, snap.paused ? 0 : 1)
    }

    /// 这条任务还"在干"吗（在跑、且没完成）—— 换新任务前的确认弹窗用它判断。
    var hasActiveTask: Bool {
        running && snap.state != .finished
    }

    /// 播放器要拼流地址用的任务号（换任务后会变 → 旧播放链接自然失效）。
    var streamTag: Int32 { tid }

    /// 点某个文件的「播放」时调：把该文件加进下载、给文件**头尾各预取一小段**
    /// （mp4 的 moov 通常在头或尾，把这两块先拉下来，播放器一开就能读）。
    func prepareStream(index: Int) {
        guard snap.metaReady else { return }
        selected.insert(index)
        userStarted = true
        applySelection()
        guard let h = handle, tid >= 0 else { return }
        let size = snap.files.first { $0.index == index }?.size ?? 0
        let chunk: Int64 = 2 * 1024 * 1024
        _ = lt_engine_stream_prefer(h, tid, Int32(index), 0, chunk)
        if size > chunk * 2 {
            _ = lt_engine_stream_prefer(h, tid, Int32(index), size - chunk, chunk)
        }
    }

    /// ★ 删除这条任务（连同它下到一半的文件）。
    ///   下载页里"已保存"的成品不受影响（它们早被挪走了）。
    func removeTask() {
        cleanupCurrentFiles()
        stopCurrent()
        selected = []
        snap = MagnetStatus.Snapshot()
        error = nil
        userStarted = false
        appliedDefault = false
        adopted = false
    }

    /// 清掉当前任务在 torrent 目录里的文件（删除任务 / 换新任务时用）。
    /// ★ 已 adopt 进下载页的成品早就被**挪走**了，这里不会误伤。
    private func cleanupCurrentFiles() {
        let files = snap.files
        let fm = FileManager.default
        let rootPath = saveRoot.standardizedFileURL.path
        for f in files {
            let u = saveRoot.appendingPathComponent(f.path).standardizedFileURL
            guard u.path.hasPrefix(rootPath + "/") else { continue }   // 防越界
            try? fm.removeItem(at: u)
        }
    }

    // MARK: - 下完 → 登记进下载中心

    /// 把下好的成品登记进下载中心（它会自己把文件挪进程序目录、做缩略图/体检）。
    /// 只登记**勾选的那几个**。返回登记了几个。
    @discardableResult
    func adopt(into center: DownloadCenter) -> Int {
        guard snap.state == .finished, !adopted else { return 0 }
        adopted = true
        let want = selected.isEmpty ? Set(snap.files.map(\.index)) : selected
        var count = 0
        for f in snap.files where want.contains(f.index) {
            let url = saveRoot.appendingPathComponent(f.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let kind: DownloadJob.MediaKind
            switch f.kind {
            case .video: kind = .video
            case .audio: kind = .audio
            case .image: kind = .image
            case .doc:   kind = .doc
            }
            _ = center.adoptCompressed(url, title: f.name, kind: kind)
            count += 1
        }
        return count
    }

    // MARK: - v1.0.250：边下边播（给 LocalHTTPServer 的后台线程调）

    /// 校验「(tid, fileIndex) 还是不是当前任务的文件」并给出磁盘路径 / 大小。
    /// ★ `nonisolated static`：HTTP 后台线程直接调 —— 只碰全局流盒（自己加锁），
    ///   不碰主线程状态。
    nonisolated static func torrentStreamContext(tid: Int32, fileIndex: Int)
        -> (url: URL, path: String, size: Int64)? {
        let box = torrentStreamBox
        box.lock.lock()
        defer { box.lock.unlock() }
        guard box.tid >= 0, box.tid == tid else { return nil }
        guard let f = box.files.first(where: { $0.index == fileIndex }) else { return nil }
        let url = URL(fileURLWithPath: box.root).appendingPathComponent(f.path)
        return (url, f.path, f.size)
    }

    /// 把这段字节标成「急着要」。返回 false = 任务不在 / 参数不对。
    nonisolated static func torrentPrefer(tid: Int32, fileIndex: Int, off: Int64, len: Int64) -> Bool {
        let box = torrentStreamBox
        box.lock.lock()
        let h = box.engine
        let t = box.tid
        box.lock.unlock()
        guard let h, t == tid else { return false }
        return lt_engine_stream_prefer(h, t, Int32(fileIndex), off, len) > 0
    }

    /// 从 off 起「连续已经能读」的字节数（≤ want）。负值 = 任务不在 / 参数不对。
    nonisolated static func torrentPrefix(tid: Int32, fileIndex: Int, off: Int64, want: Int64) -> Int64 {
        let box = torrentStreamBox
        box.lock.lock()
        let h = box.engine
        let t = box.tid
        box.lock.unlock()
        guard let h, t == tid else { return -1 }
        return lt_engine_stream_prefix(h, t, Int32(fileIndex), off, want)
    }
}
