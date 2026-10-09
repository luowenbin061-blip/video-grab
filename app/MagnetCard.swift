import Combine
import SwiftUI

/// 「粘贴链接」卡里**磁力那一段**的界面。
///
/// 四个阶段：找资源（没元数据）→ **选文件（等点「开始下载」）** → 下载中 → 下完自动进下载页。
/// 可边播的文件行还有「播放」入口（v1.0.250）。
/// ★ 状态全在 `MagnetEngine.shared` 里（单例）—— 关掉卡片下载不会断，再打开还在。
struct MagnetCard: View {

    @ObservedObject var engine: MagnetEngine
    let center: DownloadCenter

    /// 下完登记了几个（nil = 还没登记）。
    @State private var adopted: Int?
    /// ★ v1.0.248：每秒走一下，用来算"已经等了多久"（见 waited）。
    @State private var now = Date()
    /// ★ v1.0.250：删除确认弹窗。
    @State private var showDeleteConfirm = false
    /// ★ v1.0.250：正在播放的文件（非 nil 时弹播放器）。
    @State private var playItem: PlayTarget?

    /// 播放器要的 URL + 标题（包一层，给 `.sheet(item:)` 用）。
    private struct PlayTarget: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }

    private var files: [MagnetStatus.File] { engine.snap.files }

    private var chosenSize: Int64 {
        MagnetStatus.totalSize(of: engine.selected, in: files)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.running {
                header
                if engine.snap.metaReady {
                    if engine.snap.state == .finished {
                        finishedNote
                    } else {
                        if engine.userStarted {
                            progressBar
                        } else {
                            readyHint
                        }
                        fileList
                        if engine.userStarted {
                            runFooter
                        } else {
                            prepFooter
                        }
                    }
                } else {
                    waiting
                }
            }
            if let e = engine.error {
                Text(e).font(.system(size: 13)).foregroundStyle(.red)
            }
        }
        // 下完 → 自动登记进下载中心（只登记勾选的那几个）
        .onChange(of: engine.snap.state) { st in
            if st == .finished, adopted == nil {
                adopted = engine.adopt(into: center)
            }
        }
        // 每秒走一下（只在等元数据时界面上才用得到，但开着也无害）
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
        // ★ v1.0.250：删除这条任务（带确认 —— 会清掉没保存的部分）
        .alert("删除这条磁力任务？", isPresented: $showDeleteConfirm) {
            Button("删除任务和文件", role: .destructive) {
                engine.removeTask()
                center.refreshUsedSpace()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还没保存到下载页的部分会一并清除。下载页里已有的文件不受影响。")
        }
        // ★ v1.0.250：边下边播
        .sheet(item: $playItem) { t in
            PlayerSheet(url: t.url, title: t.title, pip: nil, key: "torrent-stream")
        }
    }

    /// 这条任务已经等了多久（秒）。
    private var waited: TimeInterval {
        engine.startedAt.map { now.timeIntervalSince($0) } ?? 0
    }

    // MARK: - 各段

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13))
            Text(engine.snap.name.isEmpty ? "磁力任务" : engine.snap.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("正在找资源…已连上 \(engine.snap.peers) 个 · "
                     + "DHT \(engine.snap.dhtNodes) 节点 · "
                     + "tracker \(engine.snap.trackers) 个")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(waitHint)
                .font(.system(size: 12))
                .foregroundStyle(reason == .engineRejected ? .red : .secondary)
        }
    }

    private var reason: MagnetStatus.WaitReason {
        MagnetStatus.waitReason(engine.snap)
    }

    /// ★★ v1.0.248：**把"卡在哪"说出来**。
    ///   以前不管什么原因都只显示"已连上 0 个"+ 一句"可能没人做种" ——
    ///   用户实测时完全分不出是引擎没接进网络还是真没人做种，只能干等。
    private var waitHint: String {
        switch reason {
        case .engineRejected:
            return engine.snap.engineError.isEmpty
                ? "引擎没有接受这条任务。"
                : "引擎没有接受这条任务：\(engine.snap.engineError)"
        case .fetching:
            return "已经连上 peer，正在取文件列表…"
        case .noDht:
            // ★ 头 20 秒不把"没有 DHT 节点"当结论 —— 刚起步本来就还没接上
            if waited < 20 { return "正在接入 BT 网络（头十几秒是正常的），再等等。" }
            return "一个 DHT 节点都没连上 —— 引擎没能接进 BT 网络。"
                + "换一下网络（比如关掉代理、换 Wi-Fi）再试，或者过一会儿重来。"
        case .noPeers:
            if waited < 20 { return "正在接入 BT 网络，再等等。" }
            return "网络是通的（DHT 已连上 \(engine.snap.dhtNodes) 个节点），"
                + "但这个种暂时没有 peer —— 冷门资源可能没人做种。"
        }
    }

    /// ★ v1.0.250：文件列表已就绪，**等用户确认**（改掉了"自动开下"）。
    private var readyHint: some View {
        Text("文件列表已就绪 —— 勾好要下的内容，点下面「开始下载」。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: max(0.01, engine.snap.progress))
            Text("已下 \(MagnetStatus.humanSize(engine.snap.doneBytes)) / "
                 + "\(MagnetStatus.humanSize(engine.snap.totalBytes)) · "
                 + (engine.snap.paused ? "已暂停"
                                       : MagnetStatus.humanRate(engine.snap.rateBytes))
                 + " · 连接 \(engine.snap.peers) 个")
                .font(.system(size: 12))
                .foregroundStyle(engine.snap.paused ? Color.orange : Color.secondary)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files, id: \.index) { f in
                HStack(spacing: 8) {
                    Image(systemName: icon(f.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(MagnetStatus.humanSize(f.size))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // ★ v1.0.250：能边播的文件（mp4 系）给个播放按钮
                    if canStream(f) {
                        Button { play(f) } label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle("", isOn: binding(for: f))
                        .labelsHidden()
                        .scaleEffect(0.85)
                }
                .padding(.vertical, 5)
                if f.index != files.last?.index { Divider() }
            }
        }
        .frame(maxHeight: 240)
        .clipped()
        .id(files.count)          // 文件数变了强制刷新（懒加载列表的老问题）
    }

    /// ★ v1.0.250：待开始阶段的底部 —— 一条大按钮「开始下载」。
    private var prepFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            countLine
            HStack(spacing: 10) {
                Button("全选") { engine.selectAll() }
                Button("都不选") { engine.selectNone() }
                Spacer()
            }
            .font(.system(size: 13))
            Button {
                engine.beginDownload()
                center.keepUsedSpaceFreshWhileBusy()   // 开下 = 占用开始变，刷新循环得起来
            } label: {
                Text("开始下载")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(engine.selected.isEmpty
                                ? Color(.tertiarySystemFill) : Color.accentColor)
                    .foregroundStyle(engine.selected.isEmpty ? Color.secondary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(engine.selected.isEmpty)
        }
    }

    /// ★ v1.0.250：下载中的底部 —— 暂停/继续（toggle，修掉"只能暂停不能恢复"）。
    private var runFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            countLine
            HStack(spacing: 10) {
                Button("全选") { engine.selectAll() }
                Button("都不选") { engine.selectNone() }
                Spacer()
                Button(engine.snap.paused ? "继续" : "暂停") { engine.togglePause() }
            }
            .font(.system(size: 13))
        }
    }

    private var countLine: some View {
        Text("共 \(files.count) 个 · 已选 \(engine.selected.count) 个"
             + "（\(MagnetStatus.humanSize(chosenSize))）")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var finishedNote: some View {
        Text(adopted == nil ? "下载完成，正在加入下载页…"
                           : "下载完成，已加入下载页 \(adopted ?? 0) 个")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }

    // MARK: - 小工具

    private func binding(for f: MagnetStatus.File) -> Binding<Bool> {
        Binding(get: { engine.selected.contains(f.index) },
                set: { on in
                    if on { engine.selected.insert(f.index) } else { engine.selected.remove(f.index) }
                    // ★ v1.0.250：没点「开始下载」时只改勾选 —— 不偷跑数据
                    engine.applySelectionIfStarted()
                })
    }

    private func icon(_ k: MagnetStatus.FileKind) -> String {
        switch k {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .doc:   return "doc"
        }
    }

    // MARK: - 边下边播（v1.0.250）

    /// 这一行的文件能不能边播：mp4 系才行（AVPlayer 天生不认 mkv / avi）。
    private func canStream(_ f: MagnetStatus.File) -> Bool {
        f.kind == .video && MagnetStatus.streamable(path: f.path)
    }

    /// 点「播放」：把这个文件加入下载并开始（顺带给头尾各预取一小段），
    /// 然后打开播放器读本机 HTTP 流 —— 播放器边读，我们边把读到的位置优先下载。
    private func play(_ f: MagnetStatus.File) {
        engine.prepareStream(index: f.index)
        guard LocalHTTPServer.shared.ensureAlive() != nil else { return }
        let ext = (f.path as NSString).pathExtension
        guard let u = LocalHTTPServer.shared
            .url("__torrent/\(engine.streamTag)/\(f.index).\(ext)") else { return }
        playItem = PlayTarget(url: u, title: f.name)
    }
}
