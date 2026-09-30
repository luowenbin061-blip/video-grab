import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「压画质省空间」那张卡：**选源文件（可多选）→ 选档位 → 加入队列 → 队列自己一个个压**。
///
/// ══ ★★ v1.0.162 改了什么（用户实测后提的四条）══
///   ① **选源页**：每行加 **16:9 缩略图** + **勾选框（可多选）** + 「全选」；
///      底部按钮变成「加入队列（已选 N 个）」—— 以前只能一条条加，而且认不出是哪个视频。
///   ② **从相册/文件选完直接批量入队开压**（不再回到列表让他一条条点）。
///   ③ **队列页**：拆掉顶部那个大进度条（进度只显示在各自那一行）；
///      剩余时间改成"不满 1 分钟精确到秒"（见 `CompressPlan.etaText`）；
///      **压完不再自动进下载列表**，改成"待你决定"：看效果 / 留下 / 存相册 / 存文件夹 / 丢弃，
///      并给「全部留下 / 全部丢弃」。
///   ④ 档位**记住上次选择**（`CompressPlan.videoTierKey` / `photoTierKey`）。
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

    @ObservedObject var center: DownloadCenter
    /// ★ 队列是单例：卡片只是它的一个"窗口"，开开关关不影响它
    @ObservedObject private var queue = CompressQueue.shared
    @Binding var isPresented: Bool

    @State private var mode: Mode = .video
    /// ★ v1.0.162：**多选**（按 id 记，不按下标 —— 列表一变下标就错位）
    @State private var pickedJobs = Set<UUID>()
    /// ★ v1.0.162：档位**记住上次选择**（和"批量加入"的弹窗共用同一个键）
    @AppStorage(CompressPlan.videoTierKey) private var videoTierRaw = CompressPlan.Tier.balance.rawValue
    @AppStorage(CompressPlan.photoTierKey) private var photoTierRaw = CompressPlan.PhotoTier.normal.rawValue

    @State private var showSourceMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    /// nil = 自动（有没处理完的就显示队列页）
    @State private var page: Page?
    /// 入队/开压被拒的原因（人话）
    @State private var failed: String?
    /// 一句话反馈（"已存到相册"这类）
    @State private var note: String?
    @State private var previewItem: SheetURL?
    /// 「存文件夹」（导出）要弹系统面板
    @State private var exportItem: SheetURL?
    /// 准备中（从相册选完要现读时长才能入队）—— 让用户知道没卡住
    @State private var preparing = false

    // MARK: - 档位

    private var tier: CompressPlan.Tier {
        CompressPlan.Tier(rawValue: videoTierRaw) ?? .balance
    }
    private var photoTier: CompressPlan.PhotoTier {
        CompressPlan.PhotoTier(rawValue: photoTierRaw) ?? .normal
    }

    // MARK: - 源文件

    /// 能压的：类别对得上、成品文件真的在
    private var candidates: [DownloadJob] {
        let want: DownloadJob.MediaKind = (mode == .video ? .video : .image)
        return center.jobs.filter {
            $0.mediaKind == want && $0.outputName != nil
                && JobStore.size(of: $0.outputName) > 0
        }
    }

    private var pickedCandidates: [DownloadJob] {
        candidates.filter { pickedJobs.contains($0.id) }
    }

    private var allPicked: Bool {
        !candidates.isEmpty && candidates.allSatisfy { pickedJobs.contains($0.id) }
    }

    /// 现在显示队列页吗 —— **只要还有没处理完的（等待/在压/待决定）就直接进队列页**（用户要的）
    private var onQueuePage: Bool {
        if let page { return page == .queue }
        return queue.liveCount > 0
    }

    /// 正在压的是第几个（队列页顶部那句）
    private var runningOrdinal: Int {
        (queue.items.firstIndex { $0.state == .running } ?? 0) + 1
    }

    // MARK: - 预估（给胶囊下面那行用）

    /// 用"选中里最大的那条"当例子 —— 批量的时候只有给个参照物才有意义
    private var sampleBytes: Int64 { pickedCandidates.map(\.fileSize).max() ?? 0 }
    private var sampleDuration: Double {
        pickedCandidates.max { $0.fileSize < $1.fileSize }?.duration ?? 0
    }

    private var videoEstimate: Int64? {
        guard sampleBytes > 0, sampleDuration > 0 else { return nil }
        let bps = CompressPlan.targetVideoBps(
            tier: tier,
            sourceBps: CompressPlan.sourceBps(bytes: sampleBytes, duration: sampleDuration))
        guard bps > 0 else { return nil }
        return CompressPlan.estimateBytes(videoBps: bps, duration: sampleDuration)
    }

    private var photoEstimate: Int64? {
        guard sampleBytes > 0 else { return nil }
        return CompressPlan.estimatePhotoBytes(tier: photoTier, bytes: sampleBytes)
    }

    /// 胶囊下面那行：「49.6MB → 约 35MB · 说明」
    private var tierHint: String {
        let blurb = (mode == .video) ? tier.blurb : photoTier.blurb
        let est = (mode == .video) ? videoEstimate : photoEstimate
        guard sampleBytes > 0, let est, est > 0 else { return blurb }
        let rough = (mode == .video) ? "" : "（粗估）"
        let more = pickedCandidates.count > 1 ? "（按最大的那个估）" : ""
        return "\(CompressPlan.mb(sampleBytes))MB → 约 \(CompressPlan.mb(est))MB\(rough) · \(blurb)\(more)"
    }

    // MARK: - 界面

    var body: some View {
        NavigationView {
            List {
                if let note {
                    Section { Text(note).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }
                if let failed {
                    Section {
                        Text(failed)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if preparing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在准备（读源文件信息）…").font(.system(size: 12.5))
                        }
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
                    // ★ 压着也能关：有小窗保活，压不会断；队列自己会一路压完
                    Button("关闭") { isPresented = false }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
        .confirmationDialog("要压的文件从哪来？", isPresented: $showSourceMenu,
                            titleVisibility: .visible) {
            // ★ 收完**直接入队开压**（用户要的）—— 所以这两句要说清"选完就开始"
            Button("从相册选（选完直接开压）") { showPhotoPicker = true }
            Button("从「文件」选（选完直接开压）") { showFilePicker = true }
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
        .sheet(item: $exportItem) { s in
            DocumentExporter(url: s.url, onFinish: { ok in
                note = ok ? "已保存到你选的位置。" : nil
            })
        }
        .onChange(of: mode) { _ in
            // 换了模式 → 之前勾的一律作废（类型对不上，留着只会让人误解）
            pickedJobs.removeAll()
            failed = nil
        }
    }

    // MARK: - 队列页

    @ViewBuilder private var queuePage: some View {
        if let cur = queue.current {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    // ★ 这里**故意不放进度条**（用户要求：进度只显示在每个任务自己那一行）
                    Text("正在压「\(cur.title)」")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(cur.phase.isEmpty ? "正在压缩…" : cur.phase)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text(keepAliveHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("正在压缩 · 第 \(runningOrdinal)/\(queue.items.count) 个")
            }
            if queue.waitingCount > 0 {
                Section {
                    Button(role: .destructive) {
                        queue.stopAfterCurrent()        // 当前这条压完就停
                    } label: {
                        Label("停止（当前这条压完就停）", systemImage: "stop.circle")
                    }
                } footer: {
                    Text("ffmpeg 在 App 内跑，外面掐不断 —— 所以「停止」只能是「当前这条压完就停」。")
                        .font(.system(size: 11.5))
                }
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
        }

        // ★★ v1.0.162：待处理（压好了等你决定）—— 不再自动进下载列表
        if queue.pendingCount > 0 {
            Section {
                Text("有 \(queue.pendingCount) 条已压好，等你决定 —— 一共 \(CompressPlan.mb(queue.pendingBytes))MB。")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { queue.keepAll() } label: {
                        Text("全部留下").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { queue.discardAll() } label: {
                        Text("全部丢弃").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("待处理")
            } footer: {
                // 单个字面量 → markdown 会被渲染
                Text("「留下」＝收进下载列表（以后能播、能存、能删）；「丢弃」＝删掉这份压缩成品。**原片一律不动。**")
                    .font(.system(size: 11.5))
            }
        }

        Section("队列 · \(queue.items.count)/\(CompressPlan.maxQueue)") {
            ForEach(queue.items) { item in
                QueueRow(item: item,
                         onPreview: { previewItem = SheetURL(url: $0) },
                         onCancel: { queue.cancel(item) },
                         onKeep: { queue.keep(item) },
                         onSave: { saveToPhotos(item) },
                         onExport: { exportItem = SheetURL(url: JobStore.file(named: $0)) },
                         onDiscard: { queue.discard(item) })
            }
        }

        Section {
            Button {
                page = .pick
            } label: {
                Label("再加几个文件", systemImage: "plus.circle")
            }
            if queue.hasFinishedRows {
                Button {
                    queue.clearFinished()
                } label: {
                    Label("清掉已经结束的行", systemImage: "trash")
                }
            }
        } footer: {
            Text("「清掉已经结束的行」只删列表行，不动文件 —— 留下的那份在下载列表里，丢弃的那份已经删了。")
                .font(.system(size: 11.5))
        }
    }

    /// 保活状态那句话（开 / 关两种说法，都要说清后果）
    private var keepAliveHint: String {
        CompressQueue.keepAliveEnabled
            ? "可以切到别的 App —— 小窗里会显示进度（别把小窗划掉）。关掉这张卡也不会中断。"
            : "★ 你关掉了「压缩时用小窗保活」：压的时候别切走、也别锁屏 —— 切走会被系统挂起，这一条会从头再来。"
    }

    // MARK: - 选文件页

    @ViewBuilder private var pickPage: some View {
        if !queue.items.isEmpty {
            Section {
                Button {
                    page = .queue
                } label: {
                    Label("看队列（\(queue.items.count) 条，\(queue.liveCount) 条还没处理完）",
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

        Section {
            if candidates.isEmpty {
                Text(mode == .video
                     ? "下载列表里还没有能压的视频 —— 也可以直接从相册/文件选（选完就开始压）。"
                     : "下载列表里还没有能压的图片 —— 也可以直接从相册/文件选（选完就开始压）。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            // ★ 卡片网格（用户要的"图标格式"）—— 跟「合并视频」那页同一套卡片
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(candidates) { job in
                    SourceCard(title: job.title,
                               detail: "\(CompressPlan.mb(job.fileSize))MB · 已下载",
                               thumbURL: job.cardThumbURL,
                               icon: mode == .video ? "film" : "photo",
                               on: pickedJobs.contains(job.id)) {
                        togglePick(job)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            if candidates.count > 1 {
                Button {
                    if allPicked { pickedJobs.removeAll() }
                    else { pickedJobs = Set(candidates.map(\.id)) }
                } label: {
                    Label(allPicked ? "取消全选" : "全选（\(candidates.count) 个）",
                          systemImage: allPicked ? "circle.slash" : "checkmark.circle")
                }
            }
            Button {
                showSourceMenu = true
            } label: {
                Label("从相册 / 文件选（选完直接开压）", systemImage: "plus.circle")
            }
        } header: {
            Text(pickedJobs.isEmpty
                 ? (mode == .video ? "选视频（可多选）" : "选图片（可多选）")
                 : "已选 \(pickedJobs.count)/\(candidates.count) 个")
        }

        Section("压到什么程度") {
            // ★★ 一行 5 个小胶囊（用户点名的形态）
            if mode == .video {
                VideoTierPills(raw: $videoTierRaw)
            } else {
                PhotoTierPills(raw: $photoTierRaw)
            }
            Text(tierHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Button {
                addSelectedToQueue()
            } label: {
                Text(pickedJobs.isEmpty ? "先选一个文件" : "加入队列（\(pickedJobs.count) 个）")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .disabled(pickedJobs.isEmpty)
        } footer: {
            // ★ 注意：`Text(三元)` 是**拼接出来的 String**，不渲染 markdown —— 这里不能写 **
            Text(mode == .video
                 ? "加入后自动开始压（一次一个），最多能排 \(CompressPlan.maxQueue) 个。压完的会停在队列里等你决定（留下 / 存相册 / 存文件夹 / 丢弃）—— 不会自己塞进下载列表。"
                 : "加入后自动开始压（一次一个），最多能排 \(CompressPlan.maxQueue) 个。图片统一存成 JPG、按质量重压（透明通道会丢掉），不缩分辨率。原片不会被改动。")
                .font(.system(size: 11.5))
        }
    }

    // MARK: - 动作

    private func togglePick(_ job: DownloadJob) {
        if pickedJobs.contains(job.id) { pickedJobs.remove(job.id) }
        else { pickedJobs.insert(job.id) }
    }

    /// 卡内多选 → 一起入队 → 翻到队列页 → 立刻开压
    private func addSelectedToQueue() {
        let jobs = pickedCandidates
        guard !jobs.isEmpty else { return }
        failed = nil
        var added = 0
        for job in jobs {
            guard let name = job.outputName else { continue }
            let req = CompressQueue.Request(url: JobStore.file(named: name),
                                            title: job.title,
                                            kind: job.mediaKind,
                                            bytes: job.fileSize,
                                            duration: job.duration,
                                            videoTier: tier, photoTier: photoTier)
            if let why = queue.enqueue(req) {
                failed = (added > 0 ? "已加入 \(added) 个。" : "") + "✗ " + why
                break
            }
            added += 1
        }
        if added > 0 {
            pickedJobs.removeAll()
            page = .queue
            startQueue()
        }
    }

    /// 相册/文件选完 → **直接批量入队开压**（用户要的：不要再多点一次）
    /// 视频要现读时长（估算体积、开工前查空间都要用），所以先给个"准备中"的提示。
    private func takePicked(_ files: [SavedFile]) {
        guard !files.isEmpty else { return }
        failed = nil
        preparing = true
        let isImage = (mode == .image)
        let vt = tier, pt = photoTier
        Task {
            var reqs: [CompressQueue.Request] = []
            for f in files {
                var d = 0.0
                if !isImage {
                    d = (try? await AVURLAsset(url: f.url).load(.duration).seconds) ?? 0
                }
                reqs.append(CompressQueue.Request(url: f.url,
                                                  title: Self.base(f.originalName),
                                                  kind: isImage ? .image : .video,
                                                  bytes: Self.fileSize(f.url), duration: d,
                                                  videoTier: vt, photoTier: pt))
            }
            await MainActor.run {
                preparing = false
                var added = 0
                for r in reqs {
                    if let why = queue.enqueue(r) {
                        failed = (added > 0 ? "已加入 \(added) 个。" : "") + "✗ " + why
                        break
                    }
                    added += 1
                }
                guard added > 0 else { return }
                page = .queue
                startQueue()
            }
        }
    }

    private func startQueue() {
        failed = nil
        if let why = queue.start() { failed = "✗ " + why }
    }

    private func saveToPhotos(_ item: CompressQueue.Item) {
        guard let out = item.outputName else { return }
        note = nil
        Task {
            do {
                try await Saver.toPhotos(JobStore.file(named: out))
                await MainActor.run { note = "已存到相册（这一条还在队列里，留着还是丢弃由你定）。" }
            } catch {
                await MainActor.run { failed = "存相册失败：" + error.localizedDescription }
            }
        }
    }

    /// 下载任务自己抽的那一帧（转 MP4 时抽的）；图片就直接拿那张图
    private static func sourceThumbURL(_ job: DownloadJob) -> URL? {
        if let t = job.thumbName { return JobStore.file(named: t) }
        if job.mediaKind == .image { return job.exportURL() }
        return nil
    }

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

// MARK: - 档位胶囊（压缩卡 / "批量加入"的弹窗共用）

/// 一行小胶囊里的一颗（整块可点，不是小图标）
struct TierPill: View {
    let title: String
    let on: Bool
    let tap: () -> Void

    var body: some View {
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
}

/// 视频五档（写回 @AppStorage —— **记住上次选择**，下载页那个弹窗也用同一份）
struct VideoTierPills: View {
    @Binding var raw: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CompressPlan.Tier.allCases) { t in
                TierPill(title: t.title, on: (t.rawValue == raw)) { raw = t.rawValue }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 图片四档
struct PhotoTierPills: View {
    @Binding var raw: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CompressPlan.PhotoTier.allCases) { t in
                TierPill(title: t.title, on: (t.rawValue == raw)) { raw = t.rawValue }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 选源列表里的一行（缩略图 + 名字 + 体积 + 勾选）

/// ★ v1.0.162：用户说"只有一个长长的列表，用着很不舒服" —— 每行补一张预览图，
/// 一眼能认出是哪个视频；勾选框在右边。
private struct SourceRow: View {
    let title: String
    let detail: String
    /// 有缩略图就给（下载任务转 MP4 时抽的那一帧；图片就是那张图本身）
    let thumbURL: URL?
    let icon: String
    let on: Bool
    let tap: () -> Void

    @State private var img: UIImage?
    @State private var loadedKey: String?

    private var key: String { thumbURL?.path ?? "-" }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                cover
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
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: key) {
            // 换行/换图才重读（降采样读，别把整张图解进内存）
            guard loadedKey != key else { return }
            loadedKey = key
            guard let u = thumbURL else { img = nil; return }
            img = await ThumbLoader.loadLocal(u, maxPx: 160)
        }
    }

    /// 16:9 小封面。抽不到图就显示占位图标（跟下载页一个规矩）
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 队列里的一行

/// **单独一个 View** 是为了让它只订阅自己那一条的进度
/// （一条 500ms 刷一次，别把整张卡都带着重画）。
private struct QueueRow: View {
    @ObservedObject var item: CompressQueue.Item
    var onPreview: (URL) -> Void
    var onCancel: () -> Void
    var onKeep: () -> Void
    var onSave: () -> Void
    var onExport: (String) -> Void
    var onDiscard: () -> Void

    private var icon: String {
        switch item.state {
        case .waiting:   return "clock"
        case .running:   return "arrow.triangle.2.circlepath"
        case .pending:   return "checkmark.circle.fill"
        case .kept:      return "tray.and.arrow.down.fill"
        case .discarded: return "trash"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .pending, .kept: return .green
        case .failed:         return .red
        case .running:        return .accentColor
        default:              return .secondary
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
                } else if item.state == .pending {
                    // 「丢弃」放这一行 —— 剩下四个动作排下面一行（一行五个按钮在手机上太挤）
                    Button(role: .destructive) {
                        onDiscard()
                    } label: {
                        Text("丢弃").font(.system(size: 12.5))
                    }
                    .buttonStyle(.plain)
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

            // ★ 待处理的四个动作（看效果 / 留下 / 存相册 / 存文件夹）
            if item.state == .pending, let out = item.outputName {
                HStack(spacing: 6) {
                    Button("看效果") { onPreview(JobStore.file(named: out)) }
                        .frame(maxWidth: .infinity)
                    Button("留下") { onKeep() }
                        .frame(maxWidth: .infinity)
                    Button("存相册") { onSave() }
                        .frame(maxWidth: .infinity)
                    Button("存文件夹") { onExport(out) }
                        .frame(maxWidth: .infinity)
                }
                .font(.system(size: 12.5))
                .buttonStyle(.bordered)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 「批量加入压缩队列」前的档位选择（下载页那个入口用）

/// 为什么这里要弹一次：**下载页没有档位控件** —— 不弹就等于我们替他选了一个档，
/// 那是"未经同意"。弹一次让他明着选，而且记住这次的选择（下次带出来）。
struct CompressTierSheet: View {
    /// 这次要加多少个（视频 / 图片分开说清）
    let videoCount: Int
    let photoCount: Int
    /// 用来算"约多少 MB"的例子（各类里**最大的**那个源）
    let videoBytes: Int64
    let videoDuration: Double
    let photoBytes: Int64
    let onDone: () -> Void

    @AppStorage(CompressPlan.videoTierKey) private var videoRaw = CompressPlan.Tier.balance.rawValue
    @AppStorage(CompressPlan.photoTierKey) private var photoRaw = CompressPlan.PhotoTier.normal.rawValue
    @Environment(\.dismiss) private var dismiss

    private var tier: CompressPlan.Tier { CompressPlan.Tier(rawValue: videoRaw) ?? .balance }
    private var photoTier: CompressPlan.PhotoTier {
        CompressPlan.PhotoTier(rawValue: photoRaw) ?? .normal
    }

    var body: some View {
        NavigationView {
            List {
                if videoCount > 0 {
                    Section {
                        VideoTierPills(raw: $videoRaw)
                        Text(videoHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("视频 · \(videoCount) 个")
                    } footer: {
                        Text("按最大的那个估。一次只压一个，压完停在队列里等你决定。")
                            .font(.system(size: 11.5))
                    }
                }
                if photoCount > 0 {
                    Section {
                        PhotoTierPills(raw: $photoRaw)
                        Text(photoHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("图片 · \(photoCount) 张")
                    } footer: {
                        Text("图片统一存成 JPG、按质量重压（透明通道会丢掉），不缩分辨率。")
                            .font(.system(size: 11.5))
                    }
                }
                Section {
                    Button {
                        onDone()
                    } label: {
                        Text("加入队列（\(videoCount + photoCount) 个）")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("档位会记住 —— 下次批量加入带出来的就是这次选的。")
                        .font(.system(size: 11.5))
                }
            }
            .navigationTitle("压到什么程度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
    }

    private var videoHint: String {
        guard videoBytes > 0, videoDuration > 0 else { return tier.blurb }
        let bps = CompressPlan.targetVideoBps(
            tier: tier,
            sourceBps: CompressPlan.sourceBps(bytes: videoBytes, duration: videoDuration))
        guard bps > 0 else { return tier.blurb }
        let est = CompressPlan.estimateBytes(videoBps: bps, duration: videoDuration)
        return "\(CompressPlan.mb(videoBytes))MB → 约 \(CompressPlan.mb(est))MB · \(tier.blurb)"
    }

    private var photoHint: String {
        guard photoBytes > 0 else { return photoTier.blurb }
        let est = CompressPlan.estimatePhotoBytes(tier: photoTier, bytes: photoBytes)
        return "\(CompressPlan.mb(photoBytes))MB → 约 \(CompressPlan.mb(est))MB（粗估） · \(photoTier.blurb)"
    }
}
