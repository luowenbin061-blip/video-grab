import Foundation

/// 一个下载任务的前端状态。
///
/// 产物落点：App 自己的 Documents 目录。因为 Info.plist 里开了
/// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace，
/// 所以文件会直接出现在系统「文件」App → 我的 iPhone → 视频抓取 里，
/// 不需要任何额外权限、也不需要「导出」这一步。
@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    let id = UUID()
    let title: String
    let sourceURL: String

    @Published var phase = "排队中"
    @Published var done = 0
    @Published var total = 0
    @Published var finished = false
    @Published var failed: String?
    @Published var outputName: String?

    private var task: Task<Void, Never>?

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }

    init(title: String, sourceURL: String) {
        self.title = title
        self.sourceURL = sourceURL
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !finished { phase = "已取消（已下的分片保留，可再点继续）" }
    }

    private func run() async {
        guard let src = URL(string: sourceURL) else {
            failed = "地址不合法"; phase = "失败"; return
        }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent(Self.safeFileName(title) + ".ts")
        let temp = fm.temporaryDirectory
            .appendingPathComponent("vg_\(id.uuidString)")

        var opt = HLSDownloader.Options(
            concurrency: 4,
            timeout: 20,
            retry: 2,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            referer: nil,          // 目标源不校验 Referer；需要时再补
            tempDir: temp,
            outputURL: out)

        // 有些源会校验 Referer，带上页面地址更保险
        if let host = src.host {
            opt.referer = "https://\(host)/"
        }

        var dl = HLSDownloader(options: opt)
        dl.onProgress = { [weak self] d, t, msg in
            Task { @MainActor in
                guard let self else { return }
                self.done = d
                self.total = t
                self.phase = msg
            }
        }

        phase = "开始…"
        do {
            let url = try await dl.run(sourceURL: src)
            if Task.isCancelled { return }
            outputName = url.lastPathComponent
            finished = true
            phase = "已保存：\(url.lastPathComponent)"
        } catch {
            if Task.isCancelled { return }
            failed = error.localizedDescription
            phase = "失败"
        }
    }

    private static func safeFileName(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { n = "video" }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        n = n.components(separatedBy: bad).joined(separator: "_")
        if n.count > 60 { n = String(n.prefix(60)) }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .prefix(19)
        return "\(n)_\(stamp)"
    }
}
