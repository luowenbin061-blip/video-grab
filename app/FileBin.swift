import Foundation
import SwiftUI

/// ★★★ v1.0.163：**文件回收站** —— 删掉的原片/成品先放这儿，确认不要了再清空。
///
/// ══ 为什么做（用户原话）══
///   「压缩后的原文件我很可能就删了，所以才问你能不能恢复到压缩前的状态……
///     原文件删了也没关系」
///   → 他要的是**后悔药**。而"回到压缩前"唯一物理手段就是**原片还在**
///     （压缩有损不可逆，任何算法都还原不了 —— 这点必须跟他说清，别让他以为能"修回来"）。
///   以前"删任务"直接 `deleteFiles()` 永久删，一按就没了；
///   而**书签早在 v1.0.97 就有回收站了，视频反而没有** —— 这一版补齐。
///
/// ══ 规则（写清楚，别改回去）══
///   · **有产物**（能播的成品）才进回收站；只下了一半的分片**直接删**（那是可再生的）。
///   · **压缩成品的「丢弃」不进回收站** —— 它可再生（原片还在、随时能重压）；
///     这里只保护**不可再生**的东西：下载好的原片。
///   · **清空之前它一直占着空间**：`JobStore.totalSize()` 把 `trash/` 也算进去，
///     所以"下载占用"那个数字是诚实的 —— 用户清空后才会掉下来。
///   · **不设过期、不自动清理**：他要的就是后悔药；
///     擅自定时删掉正是他最反感的那类"替我做决定"。
///   · 恢复时**连任务记录一起还原**（`JobRecord` 快照存在里面），
///     所以列表里的标题、时长、续看位置、存相册状态都跟删之前一样。
@MainActor
final class FileBin: ObservableObject {

    static let shared = FileBin()

    /// 一条被收进来的东西。**存整份任务快照**，恢复时照着它把任务重建出来。
    struct Item: Codable, Identifiable {
        /// = 原来那条任务的 id（恢复后 id 不变 → 续看进度、缩略图键都对得上）
        var id: UUID
        /// 回收站里的文件名（重名时可能带了 `-2` 后缀）
        var fileName: String
        /// 缩略图也一并留着（小文件；恢复后列表里接着有图）
        var thumbName: String?
        var title: String
        var size: Int64
        var at: Date
        /// 整份任务记录的快照
        var job: JobRecord
    }

    @Published private(set) var items: [Item] = []

    /// 恢复时把任务重建回下载列表 —— 启动时由 `DownloadCenter` 接上
    weak var center: DownloadCenter?

    /// 回收站现在占多少（按收进来时记的大小，不去扫盘 —— 免得每次重绘都读文件系统）
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    private static var fileURL: URL { JobStore.file(named: "files_trash.json") }

    private init() { load() }

    // MARK: - 收 / 恢复 / 删

    /// 收进回收站。返回移进去的字节数（0 = 没有可留的产物，已经直接清掉了）。
    @discardableResult
    func put(_ job: DownloadJob) -> Int64 {
        guard let out = job.outputName, JobStore.exists(named: out),
              let kept = JobStore.moveToTrash(named: out) else {
            job.deleteFiles()                 // 半成品/分片：没有留的价值，直接清
            return 0
        }
        let size = JobStore.size(of: kept)
        var thumb: String?
        if let t = job.thumbName, let moved = JobStore.moveToTrash(named: t) { thumb = moved }
        // 中间产物（.ts / 清单 / 分片）不留 —— 成品已经搬进回收站了
        job.deleteFiles()

        items.insert(Item(id: job.id, fileName: kept, thumbName: thumb,
                          title: job.title, size: size, at: Date(), job: job.snapshot()),
                     at: 0)
        save()
        return size
    }

    /// 恢复：文件搬回程序目录 + 任务重建回下载列表。
    /// 返回 `nil` = 成功；否则是**不成功的原因**（人话，直接显示）。
    func restore(_ item: Item) -> String? {
        guard JobStore.restoreFromTrash(fileName: item.fileName) else {
            return "回收站里找不到这个文件了（可能被系统清过），恢复不了"
        }
        if let t = item.thumbName { _ = JobStore.restoreFromTrash(fileName: t) }
        items.removeAll { $0.id == item.id }
        save()
        center?.restoreFromBin(item.job)
        return nil
    }

    /// 真删掉一条（这一步之后恢复不了）
    func remove(_ item: Item) {
        JobStore.removeFromTrash(fileName: item.fileName)
        if let t = item.thumbName { JobStore.removeFromTrash(fileName: t) }
        items.removeAll { $0.id == item.id }
        save()
    }

    /// **清空** —— 这才是真正把空间省下来的那一步
    func empty() {
        for it in items {
            JobStore.removeFromTrash(fileName: it.fileName)
            if let t = it.thumbName { JobStore.removeFromTrash(fileName: t) }
        }
        items.removeAll()
        save()
    }

    // MARK: - 落盘

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: Self.fileURL),
              let recs = try? JSONDecoder().decode([Item].self, from: d) else { return }
        items = recs
    }
}

// MARK: - 回收站那张卡

/// 从下载页进来的一张卡：列着删掉的东西，能恢复、能一条条删、能清空。
struct FileBinView: View {

    @ObservedObject var downloads: DownloadCenter
    @Binding var isPresented: Bool
    @ObservedObject private var bin = FileBin.shared

    @State private var confirmEmpty = false
    @State private var note: String?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                if let note {
                    Section { Text(note).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }

                Section {
                    // 单个字面量 → markdown 会被渲染
                    Text("删掉的原片先放在这儿 —— **清空之前它们还占着空间**。确认压缩版没问题了，再来清空，那一刻才真省下来。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if bin.items.isEmpty {
                    Section {
                        Text("回收站是空的。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("回收站 · \(bin.items.count) 项 · \(DownloadJob.sizeText(bin.totalBytes))") {
                        ForEach(bin.items) { it in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(it.title)
                                    .font(.system(size: 14))
                                    .lineLimit(2)
                                Text("\(DownloadJob.sizeText(it.size)) · 删于 \(Self.stamp.string(from: it.at))")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button {
                                        if let why = bin.restore(it) {
                                            note = "✗ " + why
                                        } else {
                                            note = "已恢复：\(it.title)（回到下载列表了）"
                                            downloads.refreshUsedSpace()
                                        }
                                    } label: {
                                        Text("恢复").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        bin.remove(it)          // 真删，不弹确认（他要的就是"别啰嗦"）
                                        downloads.refreshUsedSpace()
                                        note = "已彻底删掉一份（这一步之后恢复不了）"
                                    } label: {
                                        Text("彻底删掉").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .font(.system(size: 12.5))
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmEmpty = true
                        } label: {
                            Text("清空回收站（\(DownloadJob.sizeText(bin.totalBytes))，清掉就真没了）")
                        }
                    } footer: {
                        Text("清空是唯一真正省下空间的动作 —— 清掉之后，那些原片就再也回不来了（压缩过的画面没法还原成原画质）。")
                            .font(.system(size: 11.5))
                    }
                }
            }
            .navigationTitle("文件回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .listStyle(.insetGrouped)
            .confirmationDialog("清空回收站？", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("清空 \(bin.items.count) 项（真删）", role: .destructive) {
                    bin.empty()
                    downloads.refreshUsedSpace()
                    note = "回收站已清空。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清掉之后就恢复不了了 —— 那些原片没了，压缩过的画面也变不回去。")
            }
        }
        .navigationViewStyle(.stack)
    }
}
