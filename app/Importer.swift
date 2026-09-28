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
    /// ★ v1.0.158：默认**只收视频**（原来就是这样，调用点一行都不用改）；
    ///   「压画质省空间」的图片模式传 `.image` 就变成只收图片。
    var kind: UTType = .movie

    private var isImage: Bool { kind == .image }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = isImage ? .images : .videos    // 只要这类
        cfg.selectionLimit = 10       // 批量导入
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, typeID: kind.identifier,
                    defaultExt: isImage ? "jpg" : "mov")
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([SavedFile]) -> Void
        /// ★ 请求的类型必须跟 picker 的类型一致 —— 选图时用 `UTType.movie` 会一个都拿不到
        let typeID: String
        let defaultExt: String

        init(onPicked: @escaping ([SavedFile]) -> Void, typeID: String, defaultExt: String) {
            self.onPicked = onPicked
            self.typeID = typeID
            self.defaultExt = defaultExt
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPicked([]); return }

            let box = FileBox()
            let group = DispatchGroup()
            let typeID = self.typeID, defaultExt = self.defaultExt
            for p in results.map(\.itemProvider) {
                group.enter()
                _ = p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    box.take(from: url, suggestedName: p.suggestedName, defaultExt: defaultExt)
                }
            }
            group.notify(queue: .main) { [onPicked] in
                onPicked(box.saved)
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
