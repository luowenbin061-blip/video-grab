import SwiftUI
import UIKit

private enum BinFmt {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 便于阅读的域名（光看域名就知道是哪来的片子，比整条地址短得多）
    static func host(_ url: String) -> String {
        guard let h = URL(string: url)?.host, !h.isEmpty else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// ★★ v1.0.164：**全局回收站** —— 一张卡、两段。
///
/// 用户原话：「那就全局设置一个回收站吧，就是防止一些找回操作的，入口隐蔽点，放在设置里吧。」
/// → 入口在 **设置 → 浏览数据 → 回收站**，主界面上一个按钮都不加。
///
/// ══ 两段 ══
///   · **书签**：v1.0.97 就有的那套（删分组 / 删单条 / 清空收藏都先扔进来），
///     **逻辑一个字没改** —— 原先它是独立的 `TrashView`，现在并成同一张卡的一段。
///     并进来是为了「全局」：设置里只留**一个**回收站入口，否则两个入口更乱。
///   · **下载文件**：★ 本次新增（`FileBin`）。删掉的下载任务（视频 / 图片 / 音频 / 文档都算）
///     连同**缩略图 + 片名 + 源地址**记在这里，不设上限、不设过期（用户要"绝不消失"）。
///
/// ══ 「找回」是什么（别指望更多）══
///   产物文件是真删了（省空间正是用户删它的目的），所以找回的不是文件，是
///   **那个"点开就能播"的地址**：找回后那条会出现在下载列表里、显示「文件已不在」，
///   而下载条上会冒出「在线播放」（那段代码本来就现成）。
///   站点下架 / 删了 / 改画质 → 播不了 —— 用户已明确表态认了。
struct RecycleBinView: View {

    @ObservedObject var store: BookmarkStore
    @ObservedObject var downloads: DownloadCenter
    @Binding var isPresented: Bool

    /// 下载文件那一段（单例 —— 跟 Toolbox 订阅 CompressQueue 一个写法）
    @ObservedObject private var bin = FileBin.shared

    @State private var confirmEmpty = false
    @State private var note: String?
    @State private var playItem: PlayReq?

    /// 播放请求：**必须带 Referer / UA / Cookie** —— 防盗链的站少一个就不给放，
    /// 而界面上只会显示"加载不出来"，看不出真正原因。
    private struct PlayReq: Identifiable {
        let id: String
        let url: URL
        let headers: [String: String]?
    }

    private var allEmpty: Bool { store.trash.isEmpty && bin.isEmpty }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                if allEmpty {
                    emptyState
                } else {
                    List {
                        bookmarkSection
                        fileSection
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("全部恢复") {
                        let n = store.trash.count
                        store.restoreAll()
                        note = n > 0 ? "已恢复 \(n) 条书签（本来就在收藏里的不会重复加）"
                                     : "书签那段本来就是空的"
                    }
                    .disabled(store.trash.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空", role: .destructive) { confirmEmpty = true }
                        .disabled(allEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .alert("清空回收站？", isPresented: $confirmEmpty) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { emptyAll() }
            } message: {
                Text("书签和这些记录就真的没了，找不回来。"
                     + "（这一下才真省空间 —— 之前删视频省的那部分，早就腾出来了。）")
            }
            .fullScreenCover(item: $playItem) { p in
                PlayerSheet(url: p.url, title: "", pip: nil, key: p.id, headers: p.headers)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("回收站是空的")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("在下载页删掉的条目会留在这儿，\n缩略图、片名和那个能直接播的地址都留着。")
                .font(.system(size: 11.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 书签段（行为跟原来的 TrashView 一模一样）

    @ViewBuilder
    private var bookmarkSection: some View {
        if !store.trash.isEmpty {
            Section {
                ForEach(store.trash) { it in
                    Button { restoreBookmark(it) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(it.label)
                                .font(.system(size: 14))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let f = it.folder, !f.isEmpty {
                                    Text(f)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Text("删于 " + it.timeText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { restoreBookmark(it) } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text("书签 · \(store.trash.count) 条")
            } footer: {
                Text("点一条就恢复回去；原来在哪个分组，会自己归位。")
            }
        }
    }

    // MARK: - 下载文件段（新增）

    @ViewBuilder
    private var fileSection: some View {
        if !bin.isEmpty {
            Section {
                ForEach(bin.items) { rec in
                    BinRow(rec: rec,
                           onPlay: { play(rec) },
                           onRedownload: { k in redownload(rec, kind: k) },
                           onRestore: { restore(rec) },
                           onDrop: { drop(rec) },
                           onCopy: { copyURL(rec) })
                }
            } header: {
                Text("下载文件 · \(bin.count) 个 · 占 \(DownloadJob.sizeText(bin.usedBytes()))")
            } footer: {
                Text("文件本身已经删了（空间早腾出来了）；这儿留的是**缩略图、片名和那个能直接播的地址**——"
                     + "「播」直接放，「找回」放回下载页再播。站点下架或改了画质就播不了。"
                     + "占的那点空间是缩略图，点「删掉」或「清空」才真没有。")
            }
        }
    }

    // MARK: - 动作

    private func restoreBookmark(_ it: TrashItem) {
        note = store.restore(it) ? "已恢复「\(it.label)」"
                                 : "这条地址已经在收藏里了，没重复加"
    }

    private func play(_ rec: BinRecord) {
        // ★★ v1.0.166：改走**播放代理** —— 上游请求由本机服务带队去取。
        //   为什么非这样不可：AVPlayer 自己**带不上头**（私有键 `AVURLAssetHTTPHeaderFieldsKey`
        //   对 HLS 的内部请求不可靠）→ 真机上就是 403；而**下载**那条路
        //   （我们自己用 URLSession 取）一直是通的。根因见 `MediaProxy` 开头。
        //   代理起不来才退回原地址直连（头照旧带上，能带多少算多少）。
        let headers = DownloadJob.ctxHeaders(ua: rec.job.ua ?? "",
                                            referer: rec.job.referrer,
                                            cookie: rec.job.cookie)
        if let proxied = MediaProxy.wrap(rec.job.sourceURL, headers: headers) {
            playItem = PlayReq(id: rec.id.uuidString, url: proxied, headers: nil)
            return
        }
        guard let u = URL(string: rec.job.sourceURL) else {
            note = "这条的地址不合法，没法播"
            return
        }
        playItem = PlayReq(id: rec.id.uuidString, url: u, headers: headers)
    }

    /// **「重新下载」**：用存下来的地址 + Referer/UA/Cookie 再下一份。
    /// ★ 这条路**一直是通的**（那条「56 个分片 + AES 钥匙全拿到」的记录就是铁证）——
    ///   所以它是"真能把片子拿回来"的那个按钮，不依赖播放链路的任何改动。
    private func redownload(_ rec: BinRecord, kind: DownloadJob.MediaKind?) {
        downloads.add(title: rec.job.title,
                      url: rec.job.sourceURL,
                      referrer: rec.job.referrer ?? "",
                      ua: rec.job.ua ?? "",
                      cookie: rec.job.cookie ?? "",
                      kind: kind)
        note = "已开始重新下载「\(rec.job.title)」—— 去下载页看进度"
    }

    private func restore(_ rec: BinRecord) {
        guard let r = bin.take(rec.id) else { return }
        downloads.restoreFromBin(r)
        note = "已找回「\(rec.job.title)」—— 它在下载页里，点「在线播放」就能放"
    }

    private func drop(_ rec: BinRecord) {
        bin.drop(rec.id)
        note = "已删掉「\(rec.job.title)」（这一下才真省空间）"
    }

    private func copyURL(_ rec: BinRecord) {
        UIPasteboard.general.string = rec.job.sourceURL
        note = "地址已复制 —— 粘到浏览器里也能打开"
    }

    private func emptyAll() {
        let m = store.trash.count, f = bin.count
        store.emptyTrash()
        bin.empty()
        note = "回收站已清空（书签 \(m) 条 · 文件 \(f) 个）—— 这些真的没了。"
    }
}

// MARK: - 文件那一行

/// 单独一个 View：所有"要读下载任务内部状态"的活儿都放它的 `body` 里做
/// （View 的 `body` 是主线程隔离的，直接读 `DownloadJob` 的东西不用绕）。
private struct BinRow: View {

    let rec: BinRecord
    let onPlay: () -> Void
    /// ★ v1.0.166：把已经算好的类别回传给外层 —— 外层就不必自己去建 `DownloadJob`
    ///   （那属于「从非主线程隔离的上下文调主线程接口」，是编译风险点）。
    let onRedownload: (DownloadJob.MediaKind) -> Void
    let onRestore: () -> Void
    let onDrop: () -> Void
    let onCopy: () -> Void

    @State private var img: UIImage?

    var body: some View {
        // ★ 所有"要读下载任务内部状态"的活儿都在 `body` 里做（`View.body` 是主线程隔离的）
        //   —— 别放到自己的计算属性/函数里，那会变成"从非隔离上下文调主线程接口"。
        //   复用 `DownloadJob` 那套**两级判定**（成品扩展名 → 建卡时记的类别），
        //   自己再写一份"看后缀猜类型"迟早会跟它分叉。
        let k = DownloadJob(record: rec.job).mediaKind
        let canPlay = (k == .video || k == .audio)
        // 缩略图名也在这儿算好再带进 `.task` —— `.task` 的闭包不是主线程隔离的，
        // 在里面调主线程隔离的静态方法会编译不过。
        let thumbName = DownloadJob.thumbName(for: rec.id)
        return HStack(spacing: 10) {
            thumb(k)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.job.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(k.label)
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                    Text(BinFmt.host(rec.job.sourceURL))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("删于 " + BinFmt.stamp.string(from: rec.deletedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if canPlay {
                Button { onPlay() } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 19))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("播放")
            }
            // ★ v1.0.166：重新下载（这条路一直通 —— 不依赖播放链路）
            Button { onRedownload(k) } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("重新下载")
            Button { onRestore() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 19))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("找回")
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDrop() } label: {
                Label("删掉", systemImage: "trash")
            }
            Button { onCopy() } label: {
                Label("复制地址", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .task(id: rec.id) {
            // 缩略图还在原地（`deleteFiles(keepThumb: true)` 留下的）——
            // 走 ThumbLoader 降采样，别把整张图解码进内存。
            guard JobStore.exists(named: thumbName) else { return }
            img = await ThumbLoader.loadLocal(JobStore.file(named: thumbName), maxPx: 120)
        }
    }

    private func thumb(_ k: DownloadJob.MediaKind) -> some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: k.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
