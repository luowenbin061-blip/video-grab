import Combine
import SwiftUI

/// 「粘贴链接」卡里**磁力那一段**的界面。
///
/// 三个阶段：找资源（还没元数据）→ 列文件 + 勾选 + 下 → 下完自动进下载页。
/// ★ 状态全在 `MagnetEngine.shared` 里（单例）—— 关掉卡片下载不会断，再打开还在。
struct MagnetCard: View {

    @ObservedObject var engine: MagnetEngine
    let center: DownloadCenter

    /// 下完登记了几个（nil = 还没登记）。
    @State private var adopted: Int?
    /// ★ v1.0.248：每秒走一下，用来算"已经等了多久"（见 waited）。
    @State private var now = Date()

    private var files: [MagnetStatus.File] { engine.snap.files }

    private var chosenSize: Int64 {
        MagnetStatus.totalSize(of: engine.selected, in: files)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.running {
                header
                if engine.snap.metaReady {
                    if engine.snap.state != .finished {
                        progressBar
                        fileList
                        footer
                    } else {
                        finishedNote
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

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: max(0.01, engine.snap.progress))
            Text("已下 \(MagnetStatus.humanSize(engine.snap.doneBytes)) / "
                 + "\(MagnetStatus.humanSize(engine.snap.totalBytes)) · "
                 + "\(MagnetStatus.humanRate(engine.snap.rateBytes)) · "
                 + "连接 \(engine.snap.peers) 个")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("共 \(files.count) 个 · 已选 \(engine.selected.count) 个"
                 + "（\(MagnetStatus.humanSize(chosenSize))）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("全选") { engine.selectAll() }
                Button("都不选") { engine.selectNone() }
                Spacer()
                Button(engine.snap.state == .finished ? "已完成" : "暂停") {
                    engine.pause(true)
                }
                .disabled(engine.snap.state == .finished)
            }
            .font(.system(size: 13))
        }
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
                    engine.applySelection()     // 勾一下立刻生效（已下的数据不会丢）
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
}
