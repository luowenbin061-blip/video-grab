import SwiftUI

/// 「合并视频」这张卡 —— 从工具箱进。
///
/// 用途：下了好几集，一集一个文件，看着散、播着断；合成一条连着看。
///
/// ★ 为什么默认按**时间从早到晚**排：集数通常按顺序下，程序并不知道"哪条是第几集"，
///   所以顺序按下载时间，并把**选中的编号摆在行上**，让他一眼看清先后对不对。
///
/// ★★ 任务**不在这里跑** —— 交给 `MergeQueue`（单例）。
///   本卡片只干两件事：**收集选择** + **把队列的进度显示出来**。
///   这样关掉窗口任务照样跑、进度不丢（用户 2026-09-30 实测报过这个问题）。
@MainActor
struct MergeSheet: View {
    let center: DownloadCenter
    @Binding var isPresented: Bool

    /// ★ 状态活在单例里 —— 卡片销毁了它还在
    @ObservedObject private var queue = MergeQueue.shared

    @State private var picked: Set<UUID> = []
    @State private var checking = false
    /// 规格有差异 / 编码不同时，把差异文本拿在手里 → 弹一次确认
    @State private var confirmText: String?
    @State private var showConfirm = false
    @State private var fatalMix = false
    @State private var errorText: String?

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
    private var busy: Bool { queue.isRunning || checking }

    var body: some View {
        NavigationView {
            List {
                // ── 正在跑：无论卡片是刚打开还是"关掉又进来"，都能看到它在跑 ──
                if queue.isRunning {
                    Section("正在合并（关掉这个窗口它也会继续）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: queue.progress)
                            Text(queue.phase).font(.footnote).foregroundStyle(.secondary)
                            if let e = queue.etaText {
                                Text("大概还要 \(e)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let f = queue.failure, !queue.isRunning {
                    Section {
                        Text(f).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let out = queue.lastOutput, queue.state == .done {
                    Section {
                        Text("✔ 已合并：\(out)\n已经放进下载列表了。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if candidates.isEmpty {
                    Section {
                        Text("还没有可以合并的视频。先在下载页下几集，再回来合。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        // ★ 卡片网格（用户要的"图标格式"）：大缩略图 + 片名 + 时长/大小
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                                  spacing: 10) {
                            ForEach(candidates) { job in
                                SourceCard(title: job.title,
                                           detail: detail(job),
                                           thumbURL: job.cardThumbURL,
                                           icon: "film",
                                           on: picked.contains(job.id)) {
                                    if picked.contains(job.id) { picked.remove(job.id) }
                                    else { picked.insert(job.id) }
                                }
                                // 合成序号压在卡片左上角（原列表版是行左边的数字）
                                .overlay(alignment: .topLeading) {
                                    if let idx = pickedJobs.firstIndex(where: { $0.id == job.id }) {
                                        Text("\(idx + 1)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.white)
                                            .frame(width: 18, height: 18)
                                            .background(Circle().fill(Color.accentColor))
                                            .padding(5)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)   // ★ List 的行里要显式撑宽，
                                                      //   否则 LazyVGrid 算不出列数、被压成一行
                        .listRowSeparator(.hidden)    // ★ 网格里不要行分隔线
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } header: {
                        Text("选要合并的（按下载时间从早到晚）")
                    } footer: {
                        Text("行左边的数字就是合成后的先后顺序。想改顺序就取消重选。")
                    }

                    if !pickedJobs.isEmpty {
                        Section("这条会变成什么样") {
                            Text(summaryText).font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(checking ? "正在检查这几条…" : "正在合并…")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Button(pickedJobs.count < 2 ? "至少选两条" : "开始合并") {
                                Task { await prepare() }
                            }
                            .disabled(pickedJobs.count < 2)
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("合并视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ★ 合并中也能关 —— 任务在后台跑，重新进来还能看到进度
                    Button("关闭") {
                        isPresented = false
                        queue.tidyIfFinished()
                    }
                }
            }
            .alert(fatalMix ? "这几条的编码不一样" : "这几条的规格不完全一样",
                   isPresented: $showConfirm) {
                Button("重新编码后合并（慢，但画质损失最小）") {
                    confirmText = nil
                    startRun(force: true)
                }
                Button("取消", role: .cancel) { confirmText = nil }
            } message: {
                Text(confirmText ?? "")
            }
        }
    }

    /// 一行：编号 + 标题 + 时长/大小
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
        .disabled(busy)
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
        return "已选 \(n) 条 · 合计约 \(max(1, mins)) 分钟 · 约 \(size)\n"
            + "合成一条；画面尺寸取最大那一档（只放大、不缩小，画质损失最小）。"
    }

    // MARK: - 干活

    private func sources() -> [Merger.Source] {
        pickedJobs.compactMap { job -> Merger.Source? in
            guard let n = job.outputName else { return nil }
            return Merger.Source(url: JobStore.file(named: n), title: job.title)
        }
    }

    /// 点「开始合并」：**先自己体检一次**（决定要不要弹窗问），再把任务交给队列
    private func prepare() async {
        let srcs = sources()
        guard srcs.count >= 2 else { return }
        checking = true
        defer { checking = false }
        errorText = nil
        do {
            let check = try await Merger.inspect(srcs)
            if let bad = check.fatal {
                fatalMix = true
                confirmText = bad
                showConfirm = true
            } else if !check.warnings.isEmpty {
                fatalMix = false
                confirmText = check.report
                showConfirm = true
            } else {
                startRun(force: false)          // 全一致 → 直接跑（那条路是"零损失、秒级"）
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 真正开跑 —— 状态由 `MergeQueue` 管，这里只负责"输出名 + 完成后登记进下载列表"
    private func startRun(force: Bool) {
        let srcs = sources()
        guard srcs.count >= 2 else { return }
        _ = force

        let head = srcs.first?.title ?? "合并"
        let name = "\(DownloadJob.safeFileName(head))_合并_\(DownloadJob.stamp(Date())).mp4"
        // ★ 缩略图**先取出来**（值类型）—— 闭包不依赖 View 的状态
        let thumb = pickedJobs.first?.thumbName
        let count = srcs.count
        let firstTitle = head
        let center = self.center

        queue.onFinished = { outputName, title in
            register(name: outputName, title: title, count: count,
                     thumbSource: thumb, center: center)
        }
        queue.start(sources: srcs, outputName: name, output: JobStore.file(named: name))
        _ = firstTitle
    }

    /// 把成品登记成下载列表里的一条 —— 复用导入那条路（`local://` 开头、产物字段共用），
    /// 所以列表卡片 / 播放 / 存相册 / 存文件夹全都不用改。
    private func register(name: String, title: String, count: Int,
                          thumbSource: String?, center: DownloadCenter) {
        let job = DownloadJob(title: "\(title)（合并 \(count) 条）",
                              sourceURL: "local://merge",
                              kind: .video)
        job.outputName = name
        job.mp4Ready = true
        job.fileSize = JobStore.size(of: name)
        job.phase = "合并完成"
        job.finished = true
        job.notes.append("· 由 \(count) 条视频合并而成")
        if let t = thumbSource, JobStore.exists(named: t) {
            let mine = DownloadJob.thumbName(for: job.id)
            try? FileManager.default.copyItem(at: JobStore.file(named: t),
                                              to: JobStore.file(named: mine))
            job.thumbName = mine
        }
        center.jobs.insert(job, at: 0)
        center.save()
    }
}
