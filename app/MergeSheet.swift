import SwiftUI

/// 「合并视频」这张卡 —— 从工具箱进。
///
/// 用途：一部短剧下了好几集，一集一个文件，看着散、播着断；合成一条连着看。
///
/// ★ 为什么默认按**时间从早到晚**排：集数通常是按顺序下的，
///   而程序并不知道"哪条是第几集"（标题里也可能没有集号）——
///   所以顺序**默认按下载时间**，并且**把选中的编号摆在行上**，让他一眼看清合出来的先后对不对。
///   （不给他拖拽排序：真要调，取消重选更直接。）
///
/// ★ 分段：一部 42 集的剧合成一条会变成 2~3GB 的大文件（他要"合成一条"，
///   但手机装不下是常态），所以给一个开关让他按每 N 集切段。
@MainActor
struct MergeSheet: View {
    let center: DownloadCenter
    @Binding var isPresented: Bool

    @State private var picked: Set<UUID> = []
    @State private var splitOn = false
    @State private var perPart = 10
    @State private var running = false
    @State private var progress: Double = 0
    @State private var noteText = ""
    @State private var errorText: String?
    /// 规格只差在分辨率/声道时，把差异文本拿在手里 → 弹一次问他要不要照合
    @State private var confirmText: String?
    @State private var showConfirm = false
    /// 差异是「编码不同」（那种「仍然直接拼」没意义，只会花屏），还是「只差分辨率/声道」
    @State private var fatalMix = false

    /// 能合进来的：视频、且成品**真的在磁盘上**
    private var candidates: [DownloadJob] {
        center.jobs
            .filter { $0.mediaKind == .video && JobStore.exists(named: $0.outputName) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 已选中的，按时间正序（= 合成顺序）
    private var pickedJobs: [DownloadJob] {
        candidates.filter { picked.contains($0.id) }
    }

    private var pickedBytes: Int64 { pickedJobs.reduce(0) { $0 + max(0, $1.fileSize) } }
    private var pickedSeconds: Double { pickedJobs.reduce(0) { $0 + max(0, $1.duration) } }

    /// 分几段
    private var parts: [[DownloadJob]] {
        let all = pickedJobs
        guard splitOn, perPart > 0, all.count > perPart else { return all.isEmpty ? [] : [all] }
        return stride(from: 0, to: all.count, by: perPart).map {
            Array(all[$0..<min($0 + perPart, all.count)])
        }
    }

    var body: some View {
        NavigationView {
            List {
                if candidates.isEmpty {
                    Section {
                        Text("还没有可以合并的视频。先在下载页下几集，再回来合。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(candidates) { job in
                            row(job)
                        }
                    } header: {
                        Text("选要合并的（按下载时间从早到晚）")
                    } footer: {
                        Text("行左边的数字就是合成后的先后顺序。想改顺序就取消重选。")
                    }

                    Section("怎么合") {
                        Toggle("分段合成", isOn: $splitOn)
                            .disabled(running)
                        if splitOn {
                            Picker("每段集数", selection: $perPart) {
                                Text("5 集").tag(5)
                                Text("10 集").tag(10)
                                Text("20 集").tag(20)
                            }
                            .disabled(running)
                        }
                        if !pickedJobs.isEmpty {
                            Text(summaryText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if running {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(value: progress)
                                Text(noteText).font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Button(pickedJobs.count < 2 ? "至少选两条" : "开始合并") {
                                Task { await run(force: false) }
                            }
                            .disabled(pickedJobs.count < 2)
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("合并视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(running ? "合并中…" : "关闭") { isPresented = false }
                        .disabled(running)
                }
            }
            .alert(fatalMix ? "这几条的编码不一样" : "这几条的规格不完全一样",
                   isPresented: $showConfirm) {
                if !fatalMix {
                    Button("仍然直接拼（快；规格不同时画面可能卡住）") {
                        confirmText = nil
                        Task { await run(force: true) }
                    }
                }
                Button("重新编码后合并（慢，但画质损失最小）") {
                    confirmText = nil
                    Task { await run(force: false, reencode: true) }
                }
                Button("取消", role: .cancel) { confirmText = nil }
            } message: {
                // ★ 他问过"到底该选哪个" —— 与其让他记，不如让弹窗自己说。
                Text((confirmText ?? "")
                     + "\n\n建议选「重新编码后合并」：它只放大不缩小、能跳过的段不重压，"
                     + "画质损失最小。直接拼只适合「你确定没问题、只想快看一眼」的场合。")
            }
        }
    }

    /// 一行：编号 + 缩略图 + 标题 + 时长/大小
    private func row(_ job: DownloadJob) -> some View {
        let idx = pickedJobs.firstIndex(where: { $0.id == job.id })
        return Button {
            if picked.contains(job.id) { picked.remove(job.id) } else { picked.insert(job.id) }
        } label: {
            HStack(spacing: 10) {
                Text(idx.map { "\($0 + 1)" } ?? "·")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(idx == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.subheadline).lineLimit(1)
                    Text(detail(job)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: picked.contains(job.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(job.id) ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(running)
    }

    private func detail(_ job: DownloadJob) -> String {
        var s: [String] = []
        if job.duration > 0 {
            let t = Int(job.duration.rounded())
            s.append(String(format: "%d:%02d", t / 60, t % 60))
        }
        if job.fileSize > 0 {
            s.append(ByteCountFormatter.string(fromByteCount: job.fileSize, countStyle: .file))
        }
        return s.isEmpty ? "—" : s.joined(separator: " · ")
    }

    private var summaryText: String {
        let n = pickedJobs.count
        let mins = Int((pickedSeconds / 60).rounded())
        let size = ByteCountFormatter.string(fromByteCount: pickedBytes, countStyle: .file)
        var line = "已选 \(n) 条 · 合计约 \(max(1, mins)) 分钟 · 约 \(size)"
        if splitOn, parts.count > 1 {
            line += "\n按每 \(perPart) 集切成 \(parts.count) 段"
        }
        return line
    }

    // MARK: - 干活

    private func run(force: Bool, reencode: Bool = false) async {
        let grouped = parts
        guard !grouped.isEmpty else { return }
        running = true
        errorText = nil
        defer { running = false }

        let fm = FileManager.default
        let stamp = DownloadJob.stamp(Date())
        var made = 0

        for (i, group) in grouped.enumerated() {
            let sources: [Merger.Source] = group.compactMap { job in
                guard let n = job.outputName else { return nil }
                return Merger.Source(url: JobStore.file(named: n), title: job.title)
            }
            guard sources.count >= 2 else { continue }

            // 文件名：整条就用首条的标题；分段再带上是第几段
            let head = group.first?.title ?? "合并"
            let base = DownloadJob.safeFileName(head)
            let name = grouped.count > 1
                ? "\(base)_第\(i + 1)段_\(stamp).mp4"
                : "\(base)_合并_\(stamp).mp4"
            let out = JobStore.file(named: name)
            try? fm.removeItem(at: out)

            let total = grouped.count
            let title = group.first?.title ?? "合并"
            do {
                let tick: (Double, String) -> Void = { p, msg in
                    Task { @MainActor in
                        // 把"这一段"的进度摊到整体上，不然分段时进度条会反复回零
                        progress = (Double(i) + p) / Double(total)
                        noteText = total > 1 ? "第 \(i + 1)/\(total) 段 · \(msg)" : msg
                    }
                }
                if reencode {
                    // 规格真的对不上 → 逐集重编码成统一规格，再拼
                    try await Merger.mergeByReencoding(sources, output: out, onProgress: tick)
                } else {
                    try await Merger.merge(sources, output: out, force: force, onProgress: tick)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // ★ 规格只差在分辨率/声道 → **不直接失败**，先弹一次把差异摆给他看，
                //   他点「仍然合并」才硬拼。（编码不同是 fatal，走到的是 else 那条。）
                if let f = error as? Merger.Fail {
                    switch f {
                    case .codecMix(let d):
                        // 编码不同：直接拼必然花屏 → 只给"重编码"这条路
                        fatalMix = true; confirmText = d; showConfirm = true
                    case .mismatched(let d):
                        fatalMix = false; confirmText = d; showConfirm = true
                    default:
                        errorText = msg
                    }
                } else {
                    errorText = msg
                }
                return
            }

            register(name: name, title: title, group: group, seconds: group.reduce(0) { $0 + $1.duration },
                     bytes: JobStore.size(of: name), firstJob: group.first)
            made += 1
        }

        if made > 0 {
            center.save()
            noteText = "合并完成"
            isPresented = false
        } else {
            errorText = "没有合成任何东西（每条至少要 2 条）"
        }
    }

    /// 把成品登记成下载列表里的一条 —— 复用导入那条路（`local://` 开头、产物字段共用），
    /// 所以列表卡片 / 播放 / 存相册 / 存文件夹全都不用改。
    private func register(name: String, title: String, group: [DownloadJob],
                          seconds: Double, bytes: Int64, firstJob: DownloadJob?) {
        let job = DownloadJob(title: "\(title)（合并 \(group.count) 条）",
                              sourceURL: "local://merge",
                              kind: .video)
        job.outputName = name
        job.mp4Ready = true
        job.fileSize = bytes
        job.duration = seconds
        job.phase = "合并完成"
        job.finished = true
        job.notes.append("· 由 \(group.count) 条已下载的视频合并而成")
        // 缩略图借首条那张（复制一份，按新 id 命名）——
        // 不复制的话这条记录在列表里就是个空白格
        if let t = firstJob?.thumbName, JobStore.exists(named: t) {
            let mine = DownloadJob.thumbName(for: job.id)
            try? FileManager.default.copyItem(at: JobStore.file(named: t),
                                             to: JobStore.file(named: mine))
            job.thumbName = mine
        }
        center.jobs.insert(job, at: 0)
    }
}
