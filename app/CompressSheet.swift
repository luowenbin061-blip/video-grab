import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「压画质省空间」那张卡：**选源文件 / 选档位 / 加入队列 → 队列自己一个个压**。
///
/// ══ ★★ v1.0.160 改了什么（上一版是"压一个、看一眼、决定留不留"）══
///   ① **改成队列**：一次能排最多 20 个，**串行**一个个压（手机只有一个硬件编码器）。
///   ② **任务不再活在卡片里**：队列是单例（`CompressQueue.shared`）并且落盘 ——
///      卡片关掉、甚至退出重进，任务都在。打开卡片时**只要有活在跑就直接显示队列**，
///      绝不回到"选文件"那一页（用户原话："此时误关或者关掉压缩页面就会丢失压缩任务"）。
///   ③ **失败一个跳过继续压下一个**，原因留在那一行。
///   ④ 压完仍然自动收进下载列表（`X_压缩版`）；这里只留一个「看效果」按钮。
///   ⑤ 保活（画中画小窗）默认开、设置里能关；关掉时那句提示会变成"别切走"。
///
/// ══ 设计取舍（按用户的口味：页面上东西越少越好）══
///   · 选文件那页只有三块：源列表（含"从相册/文件选"）、**一行 5 个胶囊**、加入队列。
///   · 胶囊下面那行直接写「49.6MB → 约 35MB · 说明」，选完点加入就是确认，不设确认页。
///   · **不自动删原片**：压缩不可逆 —— 原片一律不动，删不删由他自己决定。
struct CompressSheet: View {

    /// 这个功能能干的两种活（一次只干一种）
    enum Mode: String, CaseIterable, Identifiable {
        case video, image
        var id: String { rawValue }
        var title: String { self == .video ? "视频" : "图片" }
    }

    /// 卡片显示哪一页
    private enum Page { case pick, queue }

    /// 选中的源（两种来源统一成这一个形状）
    private struct Source {
        let url: URL
        let title: String
        let bytes: Int64
        let duration: Double
    }

    @ObservedObject var center: DownloadCenter
    /// ★ 队列是单例：卡片只是它的一个"窗口"，开开关关不影响它
    @ObservedObject private var queue = CompressQueue.shared
    @Binding var isPresented: Bool

    @State private var mode: Mode = .video
    /// 选中的「已下载」条目
    @State private var selectedID: UUID?
    /// 从相册/文件选来的源文件（入队时会被搬进程序目录）
    @State private var picked: [SavedFile] = []
    @State private var pickedIndex: Int?
    /// 外部选来的视频时长（估算体积要用）—— 按路径存，读不到就是 0
    @State private var durations: [String: Double] = [:]

    @State private var tier: CompressPlan.Tier = .balance
    @State private var photoTier: CompressPlan.PhotoTier = .normal

    @State private var showSourceMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    /// nil = 自动（有活在跑就显示队列页）
    @State private var page: Page?
    /// 入队/开压被拒的原因（人话）
    @State private var failed: String?
    @State private var previewItem: SheetURL?

    // MARK: - 源文件

    /// 能压的：类别对得上、成品文件真的在
    private var candidates: [DownloadJob] {
        let want: DownloadJob.MediaKind = (mode == .video ? .video : .image)
        return center.jobs.filter {
            $0.mediaKind == want && $0.outputName != nil
                && JobStore.size(of: $0.outputName) > 0
        }
    }

    private var selected: DownloadJob? { candidates.first { $0.id == selectedID } }

    private var source: Source? {
        if let i = pickedIndex, picked.indices.contains(i) {
            let f = picked[i]
            return Source(url: f.url, title: Self.base(f.originalName),
                          bytes: Self.fileSize(f.url),
                          duration: durations[f.url.path] ?? 0)
        }
        guard let job = selected, let name = job.outputName else { return nil }
        return Source(url: JobStore.file(named: name), title: job.title,
                      bytes: JobStore.size(of: name), duration: job.duration)
    }

    /// 现在显示队列页吗 —— **有等待/在压的活就自动进队列页**（用户要的）
    private var onQueuePage: Bool {
        if let page { return page == .queue }
        return queue.liveCount > 0
    }

    // MARK: - 预估

    private var videoEstimate: Int64? {
        guard let s = source, s.duration > 0 else { return nil }
        let bps = CompressPlan.targetVideoBps(
            tier: tier,
            sourceBps: CompressPlan.sourceBps(bytes: s.bytes, duration: s.duration))
        guard bps > 0 else { return nil }
        return CompressPlan.estimateBytes(videoBps: bps, duration: s.duration)
    }

    private var photoEstimate: Int64? {
        guard let s = source, s.bytes > 0 else { return nil }
        return CompressPlan.estimatePhotoBytes(tier: photoTier, bytes: s.bytes)
    }

    /// 胶囊下面那行：「49.6MB → 约 35MB · 说明」
    private var tierHint: String {
        let blurb = (mode == .video) ? tier.blurb : photoTier.blurb
        let est = (mode == .video) ? videoEstimate : photoEstimate
        guard let s = source, let est, est > 0 else { return blurb }
        let rough = (mode == .video) ? "" : "（粗估）"
        return "\(CompressPlan.mb(s.bytes))MB → 约 \(CompressPlan.mb(est))MB\(rough) · \(blurb)"
    }

    // MARK: - 界面

    var body: some View {
        NavigationView {
            List {
                if let failed {
                    Section {
                        Text(failed)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if onQueuePage {
                    queuePage
                } else {
                    pickPage
                }
            }
            .navigationTitle("压画质省空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // ★ 压着也能关：有小窗保活，压不会断；队列会自己一路压完
                    Button("关闭") { isPresented = false }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
        .confirmationDialog("要压的文件从哪来？", isPresented: $showSourceMenu,
                            titleVisibility: .visible) {
            // 收哪一类由上面的模式决定（视频模式只收视频），所以按钮上不写"（图片/视频）"
            Button("从相册选") { showPhotoPicker = true }
            Button("从「文件」选") { showFilePicker = true }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerBox(onPicked: { files in takePicked(files) },
                           kind: mode == .image ? .image : .movie)
        }
        .sheet(isPresented: $showFilePicker) {
            FilePickerBox(onPicked: { files in takePicked(files) },
                          types: mode == .image ? [.image] : [.movie])
        }
        // ★ 用 .sheet(item:) 而不是 isPresented + 可选内容 —— 那种写法会弹出一整屏白页
        .fullScreenCover(item: $previewItem) { s in
            if Self.imageExts.contains(s.url.pathExtension.lowercased()) {
                ImageViewerSheet(url: s.url, title: "")
            } else {
                PlayerSheet(url: s.url, title: "", pip: nil, key: "")
            }
        }
        .onChange(of: mode) { _ in
            // 换了模式 → 之前选的源一律作废（类型对不上，留着只会让人误解）
            selectedID = nil
            picked = []
            pickedIndex = nil
            failed = nil
        }
    }

    // MARK: - 队列页

    @ViewBuilder private var queuePage: some View {
        if let cur = queue.current {
            Section("正在压缩") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: cur.progress)
                    Text(cur.phase.isEmpty ? "正在压缩…" : cur.phase)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text(keepAliveHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        } else if queue.waitingCount > 0 {
            Section {
                Text("有 \(queue.waitingCount) 个在排队，还没开始。")
                    .font(.system(size: 13))
                Button {
                    startQueue()
                } label: {
                    Text("继续压缩")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("排队中")
            } footer: {
                Text("一次只压一个（手机只有一个硬件编码器，同时压几个不会更快，只会更烫）。")
                    .font(.system(size: 11.5))
            }
        } else {
            Section("压完了") {
                Text("这一批都处理完了。成品已经收进下载列表（名字带「_压缩版」），在那儿能播、能存相册、能存文件夹。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("队列 · \(queue.items.count)/\(CompressPlan.maxQueue)") {
            ForEach(queue.items) { item in
                QueueRow(item: item,
                         onPreview: { previewItem = SheetURL(url: $0) },
                         onCancel: { queue.cancel(item) })
            }
        }

        Section {
            Button {
                page = .pick
            } label: {
                Label("再加几个文件", systemImage: "plus.circle")
            }
            if queue.current != nil, queue.waitingCount > 0 {
                Button(role: .destructive) {
                    queue.stopAfterCurrent()        // 当前这条压完就停
                } label: {
                    Label("停止（当前这条压完就停）", systemImage: "stop.circle")
                }
            }
            if queue.hasFinishedRows {
                Button {
                    queue.clearFinished()
                } label: {
                    Label("清掉已经结束的行", systemImage: "trash")
                }
            }
        } footer: {
            // 注意：Text(单个字面量) 才渲染 markdown；这里就是单个字面量，星号会被渲染
            Text("ffmpeg 是在 App 内跑的，**没法从外面掐断** —— 所以「停止」只能是「当前这条压完就停」。正在压的那条结束后，成品照样会收进下载列表。\n「清掉已经结束的行」只删列表行，不动文件。")
                .font(.system(size: 11.5))
        }
    }

    /// 保活状态那句话（开 / 关两种说法，都要说清后果）
    private var keepAliveHint: String {
        CompressQueue.keepAliveEnabled
            ? "可以切到别的 App —— 小窗里会显示进度（别把小窗划掉）。关掉这张卡也不会中断。"
            : "★ 你关掉了「压缩时保活」：压的时候别切走、也别锁屏 —— 切走会被系统挂起，这一条会从头再来。"
    }

    // MARK: - 选文件页

    @ViewBuilder private var pickPage: some View {
        if !queue.items.isEmpty {
            Section {
                Button {
                    page = .queue
                } label: {
                    Label("看队列（\(queue.items.count) 条，\(queue.liveCount) 条还没压完）",
                          systemImage: "list.bullet")
                }
            }
        }

        Section {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }

        Section(header: Text(mode == .video ? "选一个视频" : "选一张图片")) {
            if candidates.isEmpty && picked.isEmpty {
                Text(mode == .video
                     ? "下载列表里还没有能压的视频 —— 也可以直接从相册/文件选。"
                     : "下载列表里还没有能压的图片 —— 也可以直接从相册/文件选。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { job in
                row(icon: mode == .video ? "film" : "photo",
                    title: job.title,
                    detail: "\(CompressPlan.mb(job.fileSize))MB · 已下载",
                    on: (pickedIndex == nil && job.id == selectedID)) {
                    pickedIndex = nil
                    selectedID = job.id
                }
            }
            ForEach(Array(picked.enumerated()), id: \.offset) { item in
                row(icon: "square.and.arrow.down",
                    title: Self.base(item.element.originalName),
                    detail: "\(CompressPlan.mb(Self.fileSize(item.element.url)))MB · 从相册/文件选的",
                    on: (pickedIndex == item.offset)) {
                    selectedID = nil
                    pickedIndex = item.offset
                }
            }
            Button {
                showSourceMenu = true
            } label: {
                Label("从相册 / 文件选…", systemImage: "plus.circle")
            }
        }

        Section("压到什么程度") {
            // ★★ 一行 5 个小胶囊（用户点名的形态）
            HStack(spacing: 6) {
                if mode == .video {
                    ForEach(CompressPlan.Tier.allCases) { t in pill(t.title, t == tier) { tier = t } }
                } else {
                    ForEach(CompressPlan.PhotoTier.allCases) { t in
                        pill(t.title, t == photoTier) { photoTier = t }
                    }
                }
            }
            .padding(.vertical, 2)
            Text(tierHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Button {
                addToQueue()
            } label: {
                Text(source == nil ? "先选一个文件" : "加入队列")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .disabled(source == nil)
        } footer: {
            // ★ 注意：`Text(三元)` 是**拼接出来的 String**，不渲染 markdown —— 这里不能写 **
            Text(mode == .video
                 ? "加入后自动开始压（一次一个），最多能排 \(CompressPlan.maxQueue) 个。可以接着选下一个，也可以直接关掉这张卡 —— 队列会自己压完，成品自动收进下载列表。压缩要重新编码（有损、几分钟），原片不会被改动。"
                 : "加入后自动开始压（一次一个），最多能排 \(CompressPlan.maxQueue) 个。图片统一存成 JPG、按质量重压（透明通道会丢掉），不缩分辨率。原片不会被改动。")
                .font(.system(size: 11.5))
        }
    }

    // MARK: - 小组件

    /// 一个小胶囊（**整块可点**，不是小图标）
    private func pill(_ title: String, _ on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// 源文件的一行（选中标记不只靠颜色：用图标本身，对色觉障碍也清楚）
    private func row(icon: String, title: String, detail: String,
                     on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                // ★ 三元两边必须是**同一种类型**（`.tertiary` 是 ShapeStyle、
                //   `Color.accentColor` 是 Color，混着写编译不过 —— run #155 死在这行）
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    /// 相册/文件选来的东西：先放在卡片里（**入队时才搬进程序目录**），顺手把时长读出来
    private func takePicked(_ files: [SavedFile]) {
        guard !files.isEmpty else { return }
        picked = files
        selectedID = nil
        pickedIndex = 0
        let isVideo = (mode == .video)
        guard isVideo else { return }
        Task {
            for f in files {
                let d = (try? await AVURLAsset(url: f.url).load(.duration).seconds) ?? 0
                if d > 0 { await MainActor.run { durations[f.url.path] = d } }
            }
        }
    }

    /// 加入队列 → 翻到队列页 → 立刻开压（串行，不用等）
    private func addToQueue() {
        guard let s = source else { return }
        failed = nil
        let req = CompressQueue.Request(
            url: s.url,
            title: s.title.isEmpty ? (mode == .video ? "视频" : "图片") : s.title,
            kind: (mode == .image ? .image : .video),
            bytes: s.bytes, duration: s.duration,
            videoTier: tier, photoTier: photoTier)
        if let why = queue.enqueue(req) {
            failed = "✗ " + why
            return
        }
        selectedID = nil
        picked = []
        pickedIndex = nil
        page = .queue                      // 用户要的：有活了就直接看进度
        startQueue()
    }

    private func startQueue() {
        failed = nil
        if let why = queue.start() { failed = "✗ " + why }
    }

    // MARK: - 小工具

    private static func base(_ name: String) -> String {
        let n = (name as NSString).deletingPathExtension
        return n.isEmpty ? name : n
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber else { return 0 }
        return n.int64Value
    }

    private static let imageExts: Set<String> =
        ["jpg", "jpeg", "png", "gif", "heic", "heif", "avif", "bmp", "tiff", "webp"]
}

/// 队列里的一行。**单独一个 View** 是为了让它只订阅自己那一条的进度
/// （一条 500ms 刷一次，别把整张卡都带着重画）。
private struct QueueRow: View {
    @ObservedObject var item: CompressQueue.Item
    var onPreview: (URL) -> Void
    var onCancel: () -> Void

    private var icon: String {
        switch item.state {
        case .waiting:   return "clock"
        case .running:   return "arrow.triangle.2.circlepath"
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .done:    return .green
        case .failed:  return .red
        case .running: return .accentColor
        default:       return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Text(item.sizeLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if item.state == .waiting {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消这一条")
                } else if item.state == .done, let out = item.outputName {
                    Button("看效果") { onPreview(JobStore.file(named: out)) }
                        .font(.system(size: 12.5))
                } else {
                    Text(item.state.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tint)
                }
            }

            if item.state == .running {
                ProgressView(value: item.progress)
                Text(item.phase.isEmpty ? "正在压缩…" : item.phase)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let n = item.note {
                Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let f = item.failure {
                Text("✗ " + f)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
