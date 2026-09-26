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

    func take(from url: URL, suggestedName: String?) {
        let orig = suggestedName ?? url.lastPathComponent
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
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

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos          // 只要视频
        cfg.selectionLimit = 10       // 批量导入
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([SavedFile]) -> Void
        init(onPicked: @escaping ([SavedFile]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPicked([]); return }

            let box = FileBox()
            let group = DispatchGroup()
            for p in results.map(\.itemProvider) {
                group.enter()
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    box.take(from: url, suggestedName: p.suggestedName)
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
