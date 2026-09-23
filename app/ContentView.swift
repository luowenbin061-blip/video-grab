import SwiftUI

/// 所有下载任务的容器。
@MainActor
final class DownloadCenter: ObservableObject {
    @Published var jobs: [DownloadJob] = []

    @discardableResult
    func add(title: String, url: String) -> DownloadJob {
        let job = DownloadJob(title: title, sourceURL: url)
        jobs.insert(job, at: 0)
        job.start()
        return job
    }

    var activeCount: Int { jobs.filter { !$0.finished && $0.failed == nil }.count }
}

struct ContentView: View {

    @StateObject private var model = BrowserModel()
    @StateObject private var downloads = DownloadCenter()

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
                            Text("共 \(model.items.count) 条 · 点一条开始下载")
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
                    if picked?.id == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(item.url)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("来源：\(item.src)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
                    Text("还没有下载任务")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(center.jobs) { job in
                            JobRow(job: job)
                        }
                        .onDelete { idx in
                            for i in idx { center.jobs[i].cancel() }
                            center.jobs.remove(atOffsets: idx)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @State private var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)

            if job.failed == nil && !job.finished {
                ProgressView(value: job.progress)
            }

            HStack {
                Text(job.phase)
                    .font(.system(size: 12))
                    .foregroundStyle(job.failed != nil ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                if job.total > 0 && !job.finished {
                    Text("\(job.done)/\(job.total)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if job.finished {
                if job.mp4Ready {
                    Label("MP4 已生成 · 去「文件」App → 我的 iPhone → 视频抓取",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.green)
                } else {
                    Label("存成了 .ts —— iOS 系统播放器和微信不认这个格式",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                    if let e = job.remuxError {
                        Text("转 MP4 失败的原因：\(e)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("应急：装个 VLC 或 nPlayer，用它打开这个 .ts 就能看。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let u = job.localURL {
                    Button {
                        playing = true
                    } label: {
                        Label("在 App 里播放", systemImage: "play.circle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $playing) { PlayerSheet(url: u) }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 说明

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("这是干什么的") {
                    Text("这个 App 自带一个浏览器。网页视频的真实地址只存在于「加载它的那个会话里」，所以要在自己的浏览器里看、在自己的进程里嗅，才拿得到。嗅到之后下载、拼接，最后直接落到「文件」App 里 —— 不需要任何解锁和付费。")
                        .font(.system(size: 13.5))
                }
                Section("怎么用") {
                    step(1, "在上面地址栏输入视频站地址，进去。")
                    step(2, "点一下播放，让视频真的开始加载（重要：先播几秒）。")
                    step(3, "长按视频画面，或点右下角圆圈 → 弹出嗅探结果。")
                    step(4, "选标着 M3U8 的那一条 → 开始下载。")
                    step(5, "下完去「文件」App → 我的 iPhone → 视频抓取 里拿文件。")
                }
                Section("下载时注意") {
                    Label("尽量别切出去。iOS 会在 App 切到后台后把它挂起，下载会暂停。已下好的分片会保留，回来再点一次会接着下。",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                }
                Section("已知限制") {
                    bullet("下载完会自动转成 MP4 —— 只换封装、不重新编码，几秒完事，画质无损。")
                    bullet("万一转 MP4 失败，会保留 .ts 原文件。那个格式 iOS 系统播放器和微信都不认，要用 VLC、nPlayer 这类打开，或者拷到电脑上看。失败原因会写在下载条目里。")
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
