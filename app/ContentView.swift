import SwiftUI

/// 所有下载任务的容器。**记录会落盘**，重启程序后还在。
@MainActor
final class DownloadCenter: ObservableObject {
    @Published var jobs: [DownloadJob] = []

    init() {
        // 启动时把上次的记录读回来（文件还在的就还能播、还能存相册）
        jobs = JobStore.load().map { rec in
            let job = DownloadJob(record: rec)
            job.onUpdate = { [weak self] in self?.save() }
            return job
        }
    }

    @discardableResult
    func add(title: String, url: String) -> DownloadJob {
        let job = DownloadJob(title: title, sourceURL: url)
        job.onUpdate = { [weak self] in self?.save() }
        jobs.insert(job, at: 0)
        save()
        job.start()
        return job
    }

    /// 删除任务时把文件也删掉（用户明确要删，就别留垃圾）
    func remove(at offsets: IndexSet) {
        for i in offsets { jobs[i].cancel() }
        let going = offsets.map { jobs[$0] }
        jobs.remove(atOffsets: offsets)
        for j in going { j.deleteFiles() }
        save()
    }

    func remove(_ job: DownloadJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        job.deleteFiles()
        save()
    }

    func save() {
        JobStore.save(jobs.map { $0.snapshot() })
    }

    var activeCount: Int { jobs.filter { $0.isActive }.count }
    var usedSpace: Int64 { JobStore.totalSize() }
}

struct ContentView: View {

    @StateObject private var model = BrowserModel()
    @StateObject private var downloads = DownloadCenter()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPanel = false
    @State private var showDownloads = false
    @State private var showHelp = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()

            ZStack(alignment: .bottomTrailing) {
                BrowserView(model: model)
                    .ignoresSafeArea(edges: .bottom)

                if model.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }

                Button {
                    showPanel = true
                    model.forceScan()
                } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        if !model.items.isEmpty {
                            Text("\(model.items.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 16, y: -16)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .shadow(radius: 6, y: 3)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 20)
            }

            Divider()
            toolbar
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showPanel) {
            SniffPanel(model: model, downloads: downloads, isPresented: $showPanel)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadList(center: downloads, isPresented: $showDownloads)
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .onChange(of: model.longPressFired) { _ in
            // 长按视频 → 直接弹面板
            showPanel = true
        }
        .onChange(of: scenePhase) { ph in
            // 进后台/被打断前把记录落盘 —— 不然被系统杀掉就丢
            if ph != .active { downloads.save() }
        }
        .onAppear { input = model.address }
    }

    // MARK: - 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)

            TextField("输入网址，或打开一个视频页", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .font(.system(size: 14))
                .onSubmit { model.load(input) }
                .submitLabel(.go)

            if !input.isEmpty {
                Button {
                    input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
            }

            Button("前往") { model.load(input) }
                .font(.system(size: 14, weight: .medium))
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - 底部工具栏

    private var toolbar: some View {
        HStack {
            HStack(spacing: 0) {
                toolButton("chevron.left", "后退", enabled: model.canGoBack) { model.goBack() }
                toolButton("chevron.right", "前进", enabled: model.canGoForward) { model.goForward() }
                toolButton("arrow.clockwise", "刷新", enabled: true) { model.reload() }
            }

            Spacer()

            Button {
                showDownloads = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 19))
                    if downloads.activeCount > 0 {
                        Circle().fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 5, y: -4)
                    }
                }
            }

            Spacer()

            HStack(spacing: 0) {
                toolButton("questionmark.circle", "说明", enabled: true) { showHelp = true }
                toolButton("list.bullet.rectangle", "嗅探结果", enabled: true) { showPanel = true }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func toolButton(_ icon: String, _ label: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .frame(width: 44, height: 32)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let t = model.toast {
            Text(t)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.82), in: Capsule())
                .padding(.top, 70)
                .transition(.opacity)
        }
    }
}

// MARK: - 嗅探结果面板

struct SniffPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadCenter
    @Binding var isPresented: Bool
    @State private var picked: SniffItem?

    var body: some View {
        NavigationView {
            Group {
                if model.items.isEmpty {
                    emptyState
                } else {
                    List {
                        if let h = model.hint {
                            Section {
                                Label(h, systemImage: "info.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.mseSeen {
                            Section {
                                Label("这个页面用了 MSE（分片式加载），地址可能只以 blob: 形式出现",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Section {
                            ForEach(model.items) { item in
                                row(item)
                            }
                        } header: {
                            HStack {
                                Text("共 \(model.items.count) 条 · 点一条开始下载")
                                Spacer()
                                if !model.updatedText.isEmpty {
                                    Text("更新于 \(model.updatedText)")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("嗅探结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.forceScan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                        Button { model.clearItems() } label: { Label("清空", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .safeAreaInset(edge: .bottom) {
            if let p = picked {
                startBar(p)
            } else {
                Text("点某一条 → 这里会出现「开始下载」")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("还没嗅到地址")
                    .font(.headline)
                ForEach(Array(panelTips.enumerated()), id: \.offset) { i, tip in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(tip)
                            .font(.system(size: 13.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private let panelTips = [
        "在页面里点一下播放，让视频真的开始加载（至少播几秒）。",
        "回到这里下拉刷新，或点右下角圆圈。",
        "长按视频画面也能直接叫出这个面板。",
        "要下的是标着 M3U8 的那一条。标 TS 的是分片，别选那个。",
        "如果只有 BLOB，说明地址藏在脚本里 —— 先让视频播一会儿再刷一次。"
    ]

    private func row(_ item: SniffItem) -> some View {
        Button {
            picked = item
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorFor(item.kind), in: RoundedRectangle(cornerRadius: 4))
                    Text(item.fileName)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if item.isRecent {
                        Text("新")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                    }
                    if picked?.id == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(item.url)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // ★ 嗅探时间：让用户分清哪个是刚出来的、哪个是之前留下的
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5))
                    Text(item.timeText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Text("· \(item.relativeText)")
                        .font(.system(size: 11))
                    if item.hits > 1 {
                        Text("· 出现 \(item.hits) 次")
                            .font(.system(size: 11))
                    }
                }
                // 三元里两边都必须是同一个具体类型：Color.accentColor 会把
                // 另一侧也定成 Color，而 .tertiary 是 ShapeStyle，对不上。
                .foregroundStyle(item.isRecent ? Color.accentColor : Color.secondary)

                Text("来源：\(item.src)\(item.host.isEmpty ? "" : " · \(item.host)")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func startBar(_ item: SniffItem) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(item.isDownloadable ? "可以下载" : "这一条不能直接下")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.isDownloadable ? .primary : .secondary)
                Spacer()
                Text("嗅探于 \(item.timeText)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("复制地址") { model.copy(item.url) }
                    .font(.system(size: 13))
            }
            HStack(spacing: 10) {
                Button {
                    downloads.add(title: model.pageTitle.isEmpty ? item.fileName : model.pageTitle,
                                  url: item.url)
                    isPresented = false
                } label: {
                    Label("开始下载", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!item.isDownloadable)
            }
        }
        .padding(14)
        .background(.thinMaterial)
    }

    private func colorFor(_ kind: String) -> Color {
        switch kind {
        case "hls": return .orange
        case "file": return .green
        case "dash": return .purple
        case "blob": return .blue
        case "segment": return .gray
        default: return .secondary
        }
    }
}

// MARK: - 下载列表

struct DownloadList: View {
    @ObservedObject var center: DownloadCenter
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            Group {
                if center.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("还没有下载任务")
                            .foregroundStyle(.secondary)
                        Text("下载好的视频留在程序里，\n需要时再点「存相册」或「存文件夹」。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        Section {
                            ForEach(center.jobs) { job in
                                JobRow(job: job)
                            }
                            .onDelete { idx in center.remove(at: idx) }
                        } footer: {
                            HStack {
                                Text("共 \(center.jobs.count) 个任务")
                                Spacer()
                                Text("占用 \(DownloadJob.sizeText(center.usedSpace))")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { center.save(); isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 让 URL 可以直接当 sheet 的触发源（.sheet(item:)）。
/// 上一版用「isPresented 布尔 + 可选 URL」两个独立状态，弹出瞬间内容判 nil
/// → 空视图 → 白屏。用 item 模式后这两个状态合成一个，不可能再错位。
struct SheetURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @State private var playSheet: SheetURL?
    @State private var exportSheet: SheetURL?
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(job.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(JobRecord.formatter.string(from: job.createdAt))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if job.isActive {
                ProgressView(value: job.progress)
            }

            HStack {
                Text(job.phase)
                    .font(.system(size: 12))
                    .foregroundStyle(job.failed != nil ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                if job.total > 0 && job.isActive {
                    Text("\(job.done)/\(job.total)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            // 文件信息
            if job.finished && !job.fileMissing {
                HStack(spacing: 10) {
                    if job.duration > 0 { meta("clock", DownloadJob.durationText(job.duration)) }
                    if job.fileSize > 0 { meta("internaldrive", DownloadJob.sizeText(job.fileSize)) }
                    if let r = job.resolution, !r.isEmpty { meta("film", r) }
                }
            }

            if job.fileMissing {
                Label("文件已经不在了（可能被系统清理或删掉）", systemImage: "xmark.octagon")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else if job.finished && !job.mp4Ready {
                Label("MP4 没转出来 · 原因在「过程记录」里", systemImage: "info.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }

            if let n = job.notice {
                Text(n)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
            }

            // 操作按钮
            if job.finished && !job.fileMissing {
                HStack(spacing: 8) {
                    if job.localPlaybackURL() != nil {
                        Button {
                            // ★ 每次现取地址 —— 本机服务端口每次启动都可能变，
                            //   用存下来的旧地址就是白屏的根源之一
                            if let u = job.localPlaybackURL() {
                                showLog = false
                                playSheet = SheetURL(url: u)
                            } else {
                                job.show("这个文件现在播不了")
                            }
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        // 本地没东西可播（比如文件被删了），退回原始在线地址，
                        // 仍然走我们自己的播放器 —— 而不是丢给 Safari
                        Button {
                            if let u = URL(string: job.sourceURL) {
                                playSheet = SheetURL(url: u)
                            } else {
                                job.show("地址不合法")
                            }
                        } label: {
                            Label("在线播放", systemImage: "play")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        Task { await job.saveToPhotos() }
                    } label: {
                        Label(job.savedToPhotos ? "已存相册" : "存相册",
                              systemImage: job.savedToPhotos ? "checkmark.circle.fill" : "photo.on.rectangle")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!job.canSaveToPhotos)

                    Button {
                        if let u = job.exportURL() {
                            exportSheet = SheetURL(url: u)
                        } else {
                            job.show("文件不在了")
                        }
                    } label: {
                        Label("存文件夹", systemImage: "folder")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }

                if !job.canSaveToPhotos && job.exportURL() != nil {
                    Text("相册不认 .ts，要等 MP4 转出来才能存相册；「存文件夹」可以保存原文件。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !job.notes.isEmpty {
                Button {
                    showLog.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showLog ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(showLog ? "收起过程记录" : "过程记录")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showLog {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(job.notes.enumerated()), id: \.offset) { _, n in
                        Text(n)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(n.hasPrefix("✗") ? .red :
                                             (n.hasPrefix("✓") ? .green : .secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 3)
        // ══ 白屏的最终修法 ══
        // 上一版是 .sheet(isPresented:) + 内容里判另一个可选状态：
        //   .sheet(isPresented: $playing) { if let u = playTarget { ... } }
        // SwiftUI 在触发 sheet 的瞬间就会求值内容闭包，那时 playTarget 可能
        // 还没写进去 → 内容为空 → **纯白一整屏**（正是用户看到的样子）。
        // 改成 .sheet(item:)：URL 本身就是触发源，有值才有 sheet，
        // "弹出了但内容是空的"这种情况从结构上不可能发生。
        .sheet(item: $playSheet) { s in
            PlayerSheet(url: s.url, title: job.title)
        }
        .sheet(item: $exportSheet) { s in
            DocumentExporter(url: s.url, onFinish: { ok in
                job.show(ok ? "已保存到你选的位置" : "已取消")
            })
        }
    }

    private func meta(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(text).font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - 说明

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("这是干什么的") {
                    Text("这个 App 自带一个浏览器。网页视频的真实地址只存在于「加载它的那个会话里」，所以要在自己的浏览器里看、在自己的进程里嗅，才拿得到。嗅到之后下载、自动转成 MP4 —— 视频**留在程序内**，需要时你自己决定存到相册还是某个文件夹。不需要任何解锁和付费。")
                        .font(.system(size: 13.5))
                }
                Section("怎么用") {
                    step(1, "在上面地址栏输入视频站地址，进去。")
                    step(2, "点一下播放，让视频真的开始加载（重要：先播几秒）。")
                    step(3, "长按视频画面，或点右下角圆圈 → 弹出嗅探结果。")
                    step(4, "按嗅探时间选最新那条标着 M3U8 的 → 开始下载。")
                    step(5, "下完自动转成 MP4。要保存就点「存相册」或「存文件夹」。")
                }
                Section("嗅探结果怎么看") {
                    bullet("每条都标了嗅探时间（几点几分几秒 + “刚刚 / 3 分钟前”），刚出来的会带红色「新」标记并排在最前面 —— 这样才能确定点的是刚抓到的那条。")
                    bullet("同一个地址被反复看到时，会显示「出现 N 次」，说明它更可能是真正在用的那个。")
                    bullet("下拉或点右上角 ⋯ → 重新扫描，可以强制再扫一遍。")
                }
                Section("视频存在哪") {
                    bullet("下载和转好的文件都留在 App 自己的私有目录里，不会自动出现在系统「文件」App 中。")
                    bullet("「存相册」= 存进系统相册（需要相册写入权限，第一次会问）。")
                    bullet("「存文件夹」= 弹出系统的存储面板，你自己选放在哪个文件夹，系统会复制一份过去，程序内的原件不受影响。")
                    bullet("在下载列表里左滑删除，会把这个任务和它的文件一起删掉。")
                }
                Section("下载时注意") {
                    Label("尽量别切出去。iOS 会在 App 切到后台后把它挂起，下载会暂停。已下好的分片会保留，回来再点一次会接着下。",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                }
                Section("已知限制") {
                    bullet("转 MP4 是「只换容器、不重新编码」，所以很快、画质无损。只有少数格式不规范的流才需要走备用方案。")
                    bullet("转不成时会保留 .ts 原文件。那个格式 iOS 系统播放器和相册都不认，可以用「存文件夹」导出后用 VLC / nPlayer 打开。")
                    bullet("每一步成没成都会记在下载条目的「过程记录」里，出问题点开看一眼定位得很快。")
                    bullet("DRM 加密的付费影片拿不到，这个任何工具都做不到。")
                    bullet("有些站的地址是脚本算出来的、或走了第三方解析，可能嗅不到 —— 换个线路或等视频多播一会儿再试。")
                    bullet("个别站会检测「是不是 App 内置浏览器」，那种站打不开也正常。")
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func step(_ i: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(i)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(t).font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(.system(size: 15, weight: .bold))
            Text(t).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
