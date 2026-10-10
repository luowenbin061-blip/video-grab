import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 「导入视频」的两个系统选择器 + 文件抢救。
///
/// 特意选这两个 API（ponytail 第 4 级：平台原生）：
/// · PHPickerViewController —— **不弹相册权限**（选择器跑在独立进程，
///   App 只拿到用户选中的那几条），可多选
/// · UIDocumentPickerViewController —— 拿「文件」App 里的视频，可多选
///
/// 两条路殊途同归：把用户选中的视频**立刻复制一份**到我们自己的临时目录。
/// 为什么必须立刻复制：loadFileRepresentation 给的临时文件在回调返回后
/// 随时会被系统删掉，不抢救出来后面就没得用了。

/// 落到稳定位置的一条文件
struct SavedFile {
    let url: URL                 // 我们临时目录里的副本（系统不会动它）
    let originalName: String     // 用户看到的原文件名（做任务标题用）
    /// ★ v1.0.270：这条是不是**系统转码后的"兼容版"**（不是相册里的原片）——
    ///   只有走了"降级"（provider 只给 public.movie）才会为 true。
    ///   界面上据此提示一次"部分为兼容格式"（DP：降级可以，**静默降级不行**）。
    var transcodedFallback = false
}

/// 统一的「抢救」逻辑：copy 到临时目录，一条失败不拖垮整批
final class FileBox {
    private(set) var saved: [SavedFile] = []

    /// `defaultExt`：系统给的临时文件**偶尔没有扩展名**（尤其图片）。
    /// 视频那边沿用原来的 "mov"；图片那边传 "jpg"（内容其实是啥无所谓 ——
    /// ImageIO 按**内容**认格式，不看后缀）。
    func take(from url: URL, suggestedName: String?, defaultExt: String = "mov",
              transcoded: Bool = false) {
        let orig = suggestedName ?? url.lastPathComponent
        let ext = url.pathExtension.isEmpty ? defaultExt : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_" + UUID().uuidString.prefix(8) + "." + ext)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            saved.append(SavedFile(url: dest, originalName: orig,
                                   transcodedFallback: transcoded))
        } catch {
            // 抢救失败的那条放弃 —— 不中断整批
        }
    }
}

/// 相册多选
struct PhotoPickerBox: UIViewControllerRepresentable {
    var onPicked: ([SavedFile]) -> Void
    /// ★★ v1.0.268：**开始导出之前**先报个数 —— 上层据此**立刻建"准备中"的占位卡**。
    ///   为什么必须有：相册导出（转码 / iCloud 下载原片）可能要几秒到几十秒，
    ///   而建卡时机以前在"导出完成之后"——这段时间**连卡都没有**，
    ///   用户以为点了没反应（实测原话："不显示进度，隔几秒发现文件已经在下载页里了"）。
    var onWillLoad: ((Int) -> Void)?
    /// ★ v1.0.158：默认**只收视频**（原来就是这样，调用点一行都不用改）；
    ///   「压画质省空间」的图片模式传 `.image` 就变成只收图片。
    var kind: UTType = .movie

    private var isImage: Bool { kind == .image }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // ★★ v1.0.270：**必须用带 photoLibrary 的初始化** —— 只有这样
        //   `PHPickerResult.assetIdentifier` 才会被填上（拿原片全靠它）。
        //   无参那个初始化下它永远是 nil → 原片路径根本走不到（这一版差点白做）。
        //   ★ 注意：带上 photoLibrary **不改变** picker "免权限选择"的行为 ——
        //     用户选的还是那几条；权限只在后面真正去读原片时才需要。
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = isImage ? .images : .videos    // 只要这类
        cfg.selectionLimit = 10       // 批量导入
        // ★★ v1.0.268：**要"当前（原始）表示"，不要让系统转码** ——
        //   用户实测：相册里 15M 的视频，导入后显示 114M（HEVC 原片被转成 H.264）。
        //   `.current` 是"尽力而为"（Apple 原话 avoids transcoding, if possible），
        //   所以下面**还要**配合"按系统实际注册的类型请求"（见 `bestVideoTypeID`）。
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onWillLoad: onWillLoad,
                    typeID: kind.identifier,
                    defaultExt: isImage ? "jpg" : "mov")
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([SavedFile]) -> Void
        let onWillLoad: ((Int) -> Void)?
        /// ★ 请求的类型必须跟 picker 的类型一致 —— 选图时用 `UTType.movie` 会一个都拿不到
        let typeID: String
        let defaultExt: String

        init(onPicked: @escaping ([SavedFile]) -> Void,
             onWillLoad: ((Int) -> Void)?,
             typeID: String, defaultExt: String) {
            self.onPicked = onPicked
            self.onWillLoad = onWillLoad
            self.typeID = typeID
            self.defaultExt = defaultExt
        }

        /// ★★ v1.0.268：**优先请求"原始格式"的 UTI**。
        ///   系统在 `registeredTypeIdentifiers` 里注册了什么，就可能给什么 ——
        ///   只注册了通用的 `public.movie` 时，拿到的就是**转码后的兼容版**
        ///   （体积能大好几倍）。所以按"越原始越优先"的顺序挑：HEVC → QuickTime
        ///   （mov）/ MPEG-4（mp4）→ 才退通用 movie。图片不走这里。
        static func bestVideoTypeID(for provider: NSItemProvider,
                                    fallback: String) -> String {
            let ids = provider.registeredTypeIdentifiers
            for want in ["public.hevc", "com.apple.quicktime-movie", "public.mpeg-4"] {
                if ids.contains(want) { return want }
            }
            return fallback
        }

        /// ★★ v1.0.270：**走「原始资源」把相册里的原片写到临时文件**（绝不被转码）。
        ///   Apple 官方组合：`PHPickerResult.assetIdentifier` → `PHAsset.fetchAssets`
        ///   → `PHAssetResource`（取**第一个 `.video`**）→ `PHAssetResourceManager.writeData`。
        ///   ★ DP 复核的四个要点全在这：①权限只**静默检查**、不主动弹窗；
        ///   ②`isNetworkAccessAllowed = true`（否则 iCloud 上的原片必然报错）；
        ///   ③**不要**自作聪明按 UTI 筛资源，`.video` 的第一个就是原始视频数据；
        ///   ④回调在任意队列 —— 调用方负责回主线程。
        static func loadOriginal(assetID: String, dest: URL,
                                 done: @escaping (Bool) -> Void) {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = fetch.firstObject,
                  let res = PHAssetResource.assetResources(for: asset)
                      .first(where: { $0.type == .video }) else { done(false); return }
            let opt = PHAssetResourceRequestOptions()
            opt.isNetworkAccessAllowed = true     // ★ 必须：iCloud 原片要先下载
            PHAssetResourceManager.default().writeData(for: res, toFile: dest,
                                                       options: opt) { err in
                done(err == nil)
            }
        }

        /// 降级路径：用 `itemProvider` 导出（免权限，但**可能**是系统转码的兼容版）。
        /// `transcoded` 标记的含义：**只有"本来就只有 public.movie"或"回退到了
        /// public.movie"才算兼容版**（拿到了原始类型 UTI 的不算）。
        static func loadViaProvider(_ p: NSItemProvider, wantID: String, fallbackID: String,
                                    takeQ: DispatchQueue, box: FileBox, defaultExt: String,
                                    done: @escaping () -> Void) {
            _ = p.loadFileRepresentation(forTypeIdentifier: wantID) { url, _ in
                if url == nil, wantID != fallbackID {
                    // 该类型其实拿不到 → 换通用类型兜一次（**这一条就算兼容版**）
                    _ = p.loadFileRepresentation(forTypeIdentifier: fallbackID) { u2, _ in
                        defer { done() }
                        guard let u2 else { return }
                        takeQ.sync {
                            box.take(from: u2, suggestedName: p.suggestedName,
                                     defaultExt: defaultExt, transcoded: true)
                        }
                    }
                    return
                }
                defer { done() }
                guard let url else { return }
                takeQ.sync {
                    box.take(from: url, suggestedName: p.suggestedName,
                             defaultExt: defaultExt,
                             transcoded: (wantID == fallbackID))   // 只有 movie 可拿 = 兼容版
                }
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPicked([]); return }

            // ★ v1.0.268：**先报个数**（上层立刻建占位卡），下一拍再开始导出 ——
            //   这样占位卡一定先渲染出来，不会"点了没反应"。
            onWillLoad?(results.count)

            let box = FileBox()
            let group = DispatchGroup()
            // ★ v1.0.268：多选时回调是**并发**的，`box.take` 会同时 append
            //   （既有的数据竞争隐患）→ 用一条串行队列串起来（sync 保证
            //   "take 真的完成"才算这一条 done，否则 group.notify 可能早于复制完成）。
            let takeQ = DispatchQueue(label: "vg.import.take")
            // ★ 先解构成局部常量 —— 下面有多层闭包（async → 回调），
            //   直接引用属性会要求显式 self（编译错，踩过）
            let typeID = self.typeID, defaultExt = self.defaultExt
            let pickedCB = self.onPicked
            let imageMode = self.isImage
            // ★★ v1.0.270：相册**读取**权限 —— **静默检查**（DP：不要主动弹窗，
            //   那样会在"选视频之前"突兀地弹一次）；没有权限就静默走降级路径。
            //   `.limited` 也算有权限（对用户已授权的资产集 fetch 是能用的）。
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let canReadOriginal = (status == .authorized || status == .limited)

            DispatchQueue.main.async {
                for r in results {
                    let p = r.itemProvider
                    group.enter()
                    let wantID = PhotoPickerBox.Coordinator.bestVideoTypeID(for: p, fallback: typeID)
                    let fallbackID = typeID

                    // ① 首选：**原始资源**（原片、不转码）—— 仅视频、且拿得到 assetIdentifier
                    if canReadOriginal, !imageMode, let aid = r.assetIdentifier {
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("orig_" + UUID().uuidString.prefix(8) + ".mov")
                        PhotoPickerBox.Coordinator.loadOriginal(assetID: aid, dest: tmp) { ok in
                            if ok {
                                takeQ.sync {
                                    box.take(from: tmp, suggestedName: nil, defaultExt: defaultExt)
                                }
                                try? FileManager.default.removeItem(at: tmp)   // 临时文件立刻清
                                group.leave()
                            } else {
                                // ② 原片拿不到（iCloud 出错 / 资源异常）→ 降级 provider 路径
                                PhotoPickerBox.Coordinator.loadViaProvider(
                                    p, wantID: wantID, fallbackID: fallbackID,
                                    takeQ: takeQ, box: box, defaultExt: defaultExt) { group.leave() }
                            }
                        }
                        continue
                    }
                    // ③ 没权限 / 图片 → provider 路径（视频会按能否拿到原始类型标"兼容版"）
                    PhotoPickerBox.Coordinator.loadViaProvider(
                        p, wantID: wantID, fallbackID: fallbackID,
                        takeQ: takeQ, box: box, defaultExt: defaultExt) { group.leave() }
                }
                group.notify(queue: .main) {
                    pickedCB(box.saved)
                }
            }
        }
    }
}

/// 「文件」App 多选
struct FilePickerBox: UIViewControllerRepresentable {
    var onPicked: ([SavedFile]) -> Void
    /// ★ v1.0.90：放开可选类型（导入书签要 .html / .json）。
    ///   **默认还是 .movie**，所以原来那几处调用点一行都不用改。
    var types: [UTType] = [.movie]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true —— 拿到的是系统给的临时副本，不用管 security scope
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([SavedFile]) -> Void
        init(onPicked: @escaping ([SavedFile]) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ picker: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            picker.dismiss(animated: true)
            guard !urls.isEmpty else { return }
            let box = FileBox()
            for u in urls {
                box.take(from: u, suggestedName: u.lastPathComponent)
            }
            onPicked(box.saved)
        }
    }
}
