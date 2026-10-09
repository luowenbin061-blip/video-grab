import Foundation

/// 磁力（BT）引擎的 Swift 包装：拿住 C 句柄、定时轮询、把状态变成 `@Published`。
///
/// ★ 为什么是**单例**：BT 下载动辄十几分钟，用户不可能一直开着那张卡。
///   跟工程里的 `CompressQueue.shared` / `MergeQueue.shared` 一个路子 ——
///   卡片只是"看一眼"的窗口，活要活在别处。
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

    /// 加一条磁力链接。返回 false = 起不来（界面据此报错）。
    @discardableResult
    func start(magnet: String) -> Bool {
        stop()
        error = nil
        adopted = false
        appliedDefault = false
        snap = MagnetStatus.Snapshot()
        selected = []

        let fm = FileManager.default
        try? fm.createDirectory(at: saveRoot, withIntermediateDirectories: true)

        guard let h = lt_engine_new(saveRoot.path) else {
            error = "BT 引擎起不来（库没链上？）"
            return false
        }
        let id = lt_engine_add_magnet(h, magnet)
        guard id >= 0 else {
            lt_engine_free(h)
            error = "这条磁力链接解析不了"
            return false
        }
        handle = h
        tid = id
        startedAt = Date()
        startPump()
        return true
    }

    func stop() {
        pump?.cancel()
        pump = nil
        if let h = handle {
            lt_engine_free(h)
        }
        handle = nil
        tid = -1
        startedAt = nil
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

        // 元数据刚到 → 按默认规则勾一次（只下视频，种子里那些广告图/说明文件不碰）
        if s.metaReady && !appliedDefault {
            appliedDefault = true
            selected = MagnetStatus.defaultSelection(in: s.files)
            applySelection()
        }
    }

    // MARK: - 挑文件

    /// 把当前勾选应用到引擎（改优先级）。**已经下过的数据不会丢**。
    func applySelection() {
        guard let h = handle, tid >= 0 else { return }
        let idx = selected.sorted()
        if idx.isEmpty {
            lt_engine_select_files(h, tid, nil, 0)          // 空 = 全都下
        } else {
            var arr = idx.map { Int32($0) }
            lt_engine_select_files(h, tid, &arr, Int32(arr.count))
        }
    }

    func selectAll() {
        selected = Set(snap.files.map(\.index))
        applySelection()
    }

    func selectNone() {
        selected = []
        applySelection()
    }

    func pause(_ p: Bool) {
        guard let h = handle, tid >= 0 else { return }
        lt_engine_pause(h, tid, p ? 1 : 0)
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
}
