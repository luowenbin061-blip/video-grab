import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「压画质省空间」那张卡：**选源文件 → 选档位 → 压缩 → 决定留哪个**。
///
/// ══ ★★ v2（2026-09-29）改了什么、为什么 ══
///   ① **五档、按源码率的比例取值**（旧版写死绝对码率，对低码率片源等于"加码"——
///      真机上出现过「49.6MB 的片子预估能压到 122MB」）。见 `CompressPlan.Tier`。
///   ② **一行 5 个小胶囊**，选中后下面一行写「49.6MB → 约 35MB · 说明」——
///      用户要的就是这个形态（"一行 5 个小胶囊 + 下面一行写体积提示"）。
///   ③ **进度带上"还要多久"**（用 ffmpeg 报的 `speed` 算）。
///   ④ **压完先预览再决定**：预览 / 存到相册 / 留在下载列表 / 删掉新文件。
///   ⑤ **图片也支持**（按 JPEG 质量重压）。
///   ⑥ **压缩期间接了画中画保活** —— 不再要求"停留在这个界面"（旧版那个限制已经去掉）。
///   ⑦ 源文件也能从**相册 / 文件**里选（不只下载列表里的）。
///
/// ══ 设计取舍（按用户的口味：页面上东西越少越好，功能藏在一级入口后面）══
///   · **不单独做"确认页"**：胶囊下面那行直接写「多少 MB → 约多少 MB」，
///     选完点开始就是确认。多一页是负担。
///   · **不自动删原片**：压缩不可逆 —— 原片一律不动，删不删由他自己决定。
///   · **压完不替他做决定，但也不留垃圾**：四个按钮摆在明面上；
///     直接关掉卡片（没选）= **默认收进下载列表**（不丢东西、也不会有"看不见的孤儿文件"
///     白占空间）。想省空间就点「删掉新文件」—— 原片不受影响。
struct CompressSheet: View {

    /// 这个功能能干的两种活（一次只干一种）
    enum Mode: String, CaseIterable, Identifiable {
        case video, image
        var id: String { rawValue }
        var title: String { self == .video ? "视频" : "图片" }
    }

    /// 压好的那份成品
    private struct Done {
        let url: URL
        let note: String
        let title: String
        /// ★ 压完**当场就自动收进下载列表**了（成一条新记录）—— 不留"看不见的孤儿文件"，
        ///   也不依赖"他必须在这张卡里做决定"。「删掉新文件」靠这条记录走现成的删除通道。
        let jobID: UUID
    }

    /// 选中的源（两种来源统一成这一个形状）
    private struct Source {
        let url: URL
        let title: String
        let bytes: Int64
        let duration: Double
    }

    @ObservedObject var center: DownloadCenter
    @Binding var isPresented: Bool

    @State private var mode: Mode = .video
    /// 选中的「已下载」条目
    @State private var selectedID: UUID?
    /// 从相册/文件选来的源文件（**不进下载列表** —— 压完才决定留不留）
    @State private var picked: [SavedFile] = []
    @State private var pickedIndex: Int?
    /// 外部选来的视频时长（估算体积要用）—— 按路径存，读不到就是 0
    @State private var durations: [String: Double] = [:]

    @State private var tier: CompressPlan.Tier = .balance
    @State private var photoTier: CompressPlan.PhotoTier = .normal

    @State private var showSourceMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    @State private var running = false
    @State private var progress: Double = 0
    @State private var phase = ""
    @State private var failed: String?
    @State private var note: String?
    @State private var done: Done?
    @State private var saving = false
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

    // MARK: - 预估

    /// 视频预估体积：源码率 × 档位比例 → 目标码率 → (目标码率 + 128k 音频) × 时长
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

                if running {
                    runningSection
                } else if let d = done {
                    doneSection(d)
                } else {
                    sourceSection
                    tierSection
                    startSection
                }
            }
            .navigationTitle("压画质省空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // ★ 压着的时候也**允许**关掉：有小窗保活，压缩不会断，
                    //   压完还会自动进下载列表（见 start()）。所以不必把他锁在这一页。
                    Button("关闭") { isPresented = false }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
        .confirmationDialog("要压的文件从哪来？", isPresented: $showSourceMenu,
                            titleVisibility: .visible) {
            // ★ 按钮上不写"（图片/视频）"—— 收哪一类是**上面的模式**决定的（视频模式只收视频），
            //   写上反而对不上。跟着下一次构建一起推。
            Button("从相册选") { showPhotoPicker = true }
            Button("从「文件」选") { showFilePicker = true }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            // ★ 图片模式才收图片；视频模式还是只收视频（跟原来一样）
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
                // 预览不接画中画（压缩已经结束，不需要靠小窗保活）
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

    // MARK: - 三个区块

    private var runningSection: some View {
        Section("正在压缩") {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                Text(phase.isEmpty ? "正在压缩…" : phase)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                // ★ 旧版这里写的是"必须停留在这个界面"。v2 接了画中画保活 →
                //   切走也能继续（画中画的小窗活着，进程就不会被挂起）。
                Text("现在有小窗保活：切到别的 App 也能接着压 —— 别把小窗划掉就行。关掉这张卡也不会中断，压完会自动进下载列表。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private func doneSection(_ d: Done) -> some View {
        Group {
            Section("压好了") {
                Text(d.note)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("已经当成一条新记录收进下载列表了（「\(d.title)_压缩版」）。原片一动没动。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button {
                    previewItem = SheetURL(url: d.url)
                } label: {
                    Label("先看看效果", systemImage: "play.rectangle")
                }
                Button {
                    saveToPhotos(d)
                } label: {
                    Label(saving ? "正在存相册…" : "存到相册", systemImage: "square.and.arrow.down")
                }
                .disabled(saving)
                Button(role: .destructive) {
                    discard(d)
                } label: {
                    Label("不要这条（删掉新文件）", systemImage: "trash")
                }
                Button("完成") { isPresented = false }
            } footer: {
                Text("「删掉新文件」同时会把下载列表里那条记录一起撤掉 —— 原片和相册里那份都不受影响。")
                    .font(.system(size: 11.5))
            }
        }
    }

    private var sourceSection: some View {
        Group {
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
        }
    }

    private var tierSection: some View {
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
            // ★ 下面那行：体积提示 + 一句人话
            Text(tierHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startSection: some View {
        Section {
            Button {
                start()
            } label: {
                Text(source == nil ? "先选一个文件" : "开始压缩")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .disabled(source == nil)
        } footer: {
            // ★ 注意：`Text(三元)` 是**拼接出来的 String**，不渲染 markdown ——
            //   所以这两句里不能写 `**`（会原样露出星号）。要加粗只能用单个字面量。
            Text(mode == .video
                 ? "压缩要重新编码（有损、几分钟），和「转成 MP4」那种秒级的换封装不是一回事。原片不会被改动。"
                 : "图片统一存成 JPG、按质量重压（透明通道会丢掉），不缩分辨率 —— 只靠质量省空间。原片不会被改动。")
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

    /// 相册/文件选来的东西：存进卡片（**不进下载列表**），顺手把视频时长读出来
    private func takePicked(_ files: [SavedFile]) {
        guard !files.isEmpty else { return }
        picked = files
        selectedID = nil
        pickedIndex = 0
        // 时长要现读（估算体积要用）—— 只对视频有意义，图片跳过
        let isVideo = (mode == .video)
        guard isVideo else { return }
        Task {
            for f in files {
                let d = (try? await AVURLAsset(url: f.url).load(.duration).seconds) ?? 0
                if d > 0 { await MainActor.run { durations[f.url.path] = d } }
            }
        }
    }

    private func start() {
        guard let s = source else { return }
        running = true
        failed = nil
        note = nil
        progress = 0
        phase = ""
        // ★ 起画中画**必须在后台前、且在前台**的时候（跟"共享给电脑"同一个道理）
        center.beginCompressKeepAlive(title: s.title.isEmpty ? "压缩" : s.title)

        let isImage = (mode == .image)
        let t = tier
        let pt = photoTier
        let onP: (Double, String) -> Void = { p, msg in
            Task { @MainActor in
                progress = p
                phase = msg
                center.updateCompressKeepAlive(detail: msg, progress: p)
            }
        }
        Task {
            do {
                let r: (url: URL, bytes: Int64, note: String)
                if isImage {
                    r = try await Compressor.runPhoto(input: s.url, tier: pt, onProgress: onP)
                } else {
                    r = try await Compressor.run(input: s.url, tier: t, onProgress: onP)
                }
                await MainActor.run {
                    running = false
                    center.endCompressKeepAlive()
                    // ★★ 压完**立刻**收进下载列表（当成一条新记录）：
                    //   ① 不会有"看不见但占空间"的孤儿文件；
                    //   ② 就算他刚才把卡片关了、或在别的 App 里，结果也稳稳落在下载页；
                    //   ③ 「删掉新文件」直接走现成的删除通道。
                    let title = s.title.isEmpty ? "视频" : s.title
                    let job = center.adoptCompressed(
                        r.url, title: title + "_压缩版",
                        kind: isImage ? .image : .video)
                    done = Done(url: r.url, note: r.note, title: title, jobID: job.id)
                }
            } catch {
                await MainActor.run {
                    running = false
                    center.endCompressKeepAlive()
                    failed = "✗ " + error.localizedDescription
                }
            }
        }
    }

    private func saveToPhotos(_ d: Done) {
        saving = true
        Task {
            do {
                try await Saver.toPhotos(d.url)
                await MainActor.run {
                    saving = false
                    note = "已存到相册。想省空间可以再点「删掉新文件」—— 原片和相册里那份都不受影响。"
                }
            } catch {
                await MainActor.run {
                    saving = false
                    failed = "存相册失败：" + error.localizedDescription
                }
            }
        }
    }

    /// 不要了：记录和文件一起撤掉（走现成的删除通道），然后回到选文件
    private func discard(_ d: Done) {
        if let job = center.jobs.first(where: { $0.id == d.jobID }) {
            center.remove(job)                                  // 连文件一起删
        }
        // 保险：万一那条记录已经不在了（他在别处删过），这里也把文件清掉
        try? FileManager.default.removeItem(at: d.url)
        done = nil
        progress = 0
        phase = ""
        note = "已删掉新文件。原片没动 —— 想再压一次随时可以。"
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
