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
}

/// 统一的「抢救」逻辑：copy 到临时目录，一条失败不拖垮整批
final class FileBox {
    private(set) var saved: [SavedFile] = []

    /// `defaultExt`：系统给的临时文件**偶尔没有扩展名**（尤其图片）。
    /// 视频那边沿用原来的 "mov"；图片那边传 "jpg"（内容其实是啥无所谓 ——
    /// ImageIO 按**内容**认格式，不看后缀）。
    func take(from url: URL, suggestedName: String?, defaultExt: String = "mov") {
        let orig = suggestedName ?? url.lastPathComponent
        let ext = url.pathExtension.isEmpty ? defaultExt : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_" + UUID().uuidString.prefix(8) + "." + ext)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            saved.append(SavedFile(url: dest, originalName: orig))
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
        var cfg = PHPickerConfiguration()
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
            let typeID = self.typeID, defaultExt = self.defaultExt
            // ★ 先解构成局部常量 —— 下面有两层闭包（async → notify），
            //   直接引用属性会要求显式 self（编译错，踩过）
            let pickedCB = self.onPicked

            DispatchQueue.main.async {
                for p in results.map(\.itemProvider) {
                    group.enter()
                    // 视频：优先原始 UTI；导出失败（该类型其实不可用）再用通用类型兜一次
                    let wantID = PhotoPickerBox.Coordinator.bestVideoTypeID(for: p, fallback: typeID)
                    let fallbackID = typeID
                    _ = p.loadFileRepresentation(forTypeIdentifier: wantID) { url, err in
                        if url == nil, wantID != fallbackID {
                            // 兜底：换通用类型再试一次（不嵌套 group.enter，复用同一次）
                            _ = p.loadFileRepresentation(forTypeIdentifier: fallbackID) { u2, _ in
                                defer { group.leave() }
                                guard let u2 else { return }
                                takeQ.sync { box.take(from: u2, suggestedName: p.suggestedName, defaultExt: defaultExt) }
                            }
                            return
                        }
                        defer { group.leave() }
                        guard let url else { return }
                        takeQ.sync { box.take(from: url, suggestedName: p.suggestedName, defaultExt: defaultExt) }
                    }
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
