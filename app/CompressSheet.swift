import SwiftUI

/// 「压画质省空间」那张卡：**选文件 → 选档位 → 压缩 → 存相册**。
///
/// ══ 设计取舍（按用户的口味：页面上东西越少越好，功能藏在一级入口后面）══
///   · **不单独做"确认页"**：档位按钮上直接写「286MB → 约 142MB」——
///     选完点开始就是确认。多一页是负担。
///   · 整张卡只有三块：文件列表、三个档位、开始按钮（压缩时变成进度条）。
///   · 每个档位按钮**整行可点、高度够**（不是小图标按钮）。
///   · **不自动删原片**：压缩不可逆 —— 完成后只提示他"原片还在，确认新片没问题再删"。
///     （"自动进回收站"留到以后：现在还没有文件回收站，只有书签回收站。）
///   · ★ **压缩期间要求停留在这个界面**：iOS 会把切走的 App 挂起，
///     进程内跑着的 ffmpeg 会被一起掐掉（半成品会被清理、原片不受影响）。
///     以后接了画中画保活再放开这个限制。
struct CompressSheet: View {

    @ObservedObject var center: DownloadCenter
    @Binding var isPresented: Bool

    @State private var selectedID: UUID?
    @State private var tier: Compressor.Tier = .standard
    @State private var running = false
    @State private var progress: Double = 0
    @State private var phase = ""
    @State private var note: String?
    @State private var failed: String?
    @State private var doneBytes: Int64 = 0
    @State private var saving = false

    /// 能压的：成品已就绪、文件还在
    private var candidates: [DownloadJob] {
        center.jobs.filter { $0.mp4Ready && JobStore.size(of: $0.outputName) > 0 }
    }

    private var selected: DownloadJob? {
        candidates.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationView {
            List {
                if let note {
                    Section {
                        Text(note).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                if let failed {
                    Section {
                        Text(failed).font(.system(size: 12.5)).foregroundStyle(.red)
                    }
                }

                if running {
                    Section("正在压缩") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text(phase.isEmpty ? "正在压缩…" : phase)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            Text("★ 请停留在这个界面 —— 切到别的 App，系统会把压缩掐断（原片不受影响）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                } else if doneBytes > 0 {
                    Section("压好了") {
                        Button {
                            saveToPhotos()
                        } label: {
                            Label(saving ? "正在存相册…" : "存到相册", systemImage: "square.and.arrow.down")
                        }
                        .disabled(saving)
                        Button("完成") { isPresented = false }
                    }
                } else {
                    // ① 选文件
                    Section("选一个已下载的视频") {
                        if candidates.isEmpty {
                            Text("还没有下载好的视频。先下一条再来压。")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidates) { job in
                            Button {
                                selectedID = job.id
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(job.title)
                                            .font(.system(size: 14))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text("\(Compressor.mb(job.fileSize))MB · \(Int(job.duration)) 秒")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    // ★ 选中标记不只靠颜色：用图标本身（对色觉障碍也清楚）
                                    // ★ 三元里两边必须是**同一种类型**：
                                    //   `.tertiary` 是 ShapeStyle、`Color.accentColor` 是 Color ——
                                    //   混着写编译不过（run #155 就死在这一行）。
                                    Image(systemName: job.id == selectedID
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(job.id == selectedID ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ② 选档位（按钮上直接写体积，省掉一页确认）
                    Section("压到什么程度") {
                        ForEach(Compressor.Tier.allCases) { t in
                            Button {
                                tier = t
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.title).font(.system(size: 15, weight: .medium))
                                        Text(t.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                        if let job = selected {
                                            Text("\(Compressor.mb(job.fileSize))MB → 约 \(Compressor.mb(Compressor.estimateBytes(tier: t, duration: job.duration)))MB")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    Image(systemName: t == tier ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(t == tier ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ③ 开始
                    Section {
                        Button {
                            start()
                        } label: {
                            Text(selected == nil ? "先选一个视频" : "开始压缩")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selected == nil)
                    } footer: {
                        Text("压缩会**重新编码**（有损、要几分钟），和「转成 MP4」那种秒级的换封装不是一回事。原片不会被改动。")
                            .font(.system(size: 11.5))
                    }
                }
            }
            .navigationTitle("压画质省空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { isPresented = false }.disabled(running)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 动作

    private func start() {
        guard let job = selected, let name = job.outputName else { return }
        let input = JobStore.file(named: name)
        running = true
        failed = nil
        note = nil
        progress = 0
        phase = ""
        Task {
            do {
                let r = try await Compressor.run(input: input, tier: tier) { p, msg in
                    Task { @MainActor in
                        progress = p
                        phase = msg
                    }
                }
                await MainActor.run {
                    running = false
                    doneBytes = r.bytes
                    note = r.note + "。原片还在下载列表里 —— 确认新片能播、没问题了再删它。"
                }
            } catch {
                await MainActor.run {
                    running = false
                    failed = "✗ " + (error.localizedDescription)
                }
            }
        }
    }

    private func saveToPhotos() {
        guard let job = selected, let name = job.outputName else { return }
        let base = (name as NSString).deletingPathExtension
        let out = JobStore.file(named: base + "_压缩.mp4")
        saving = true
        Task {
            do {
                try await Saver.toPhotos(out)
                await MainActor.run { saving = false; note = "已存到相册。" }
            } catch {
                await MainActor.run {
                    saving = false
                    failed = "存相册失败：" + error.localizedDescription
                }
            }
        }
    }
}
