import Foundation
import Photos
import SwiftUI
import UIKit

/// 把程序内的成品交给系统 —— 由用户自己选择存到相册还是某个文件夹。
/// 这两个动作都**只在用户点按钮时**发生，程序不会自作主张往外面写。
enum Saver {

    enum Fail: LocalizedError {
        case noPhotoPermission
        case notSavable(String)

        var errorDescription: String? {
            switch self {
            case .noPhotoPermission:
                return "没有相册写入权限。请到 设置 → 隐私与安全性 → 照片 里允许「视频抓取」添加照片。"
            case .notSavable(let ext):
                return "相册只收图片和视频（.mp4/.mov/.jpg/.png 这类）。.\(ext) 请用「存文件夹」。"
            }
        }
    }

    /// 存到系统相册。
    /// ★ v1.0.109：不再只认 mp4 —— 图片也能存（相册同时收 photo / video 两类资源），
    ///   音频和文档则明确拒绝（相册根本没有能装它们的地方）。
    static func toPhotos(_ url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        let imgExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "avif", "bmp", "tiff", "webp"]
        let vidExts = ["mp4", "m4v", "mov"]
        let isImg = imgExts.contains(ext)
        guard isImg || vidExts.contains(ext) else { throw Fail.notSavable(ext) }

        // requestAuthorization(for:) 的 async 版本在各 SDK 上可用性不一致，
        // 一律用回调版包一层，避开版本差异。
        let status: PHAuthorizationStatus = await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in c.resume(returning: s) }
        }
        guard status == .authorized || status == .limited else { throw Fail.noPhotoPermission }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opt = PHAssetResourceCreationOptions()
                opt.shouldMoveFile = false          // 我们是"另存一份"，程序内的原件要留着
                req.addResource(with: isImg ? .photo : .video, fileURL: url, options: opt)
            }, completionHandler: { ok, err in
                if let err { c.resume(throwing: err) }
                else if ok { c.resume() }
                else { c.resume(throwing: NSError(domain: "VideoGrab", code: 9,
                                                  userInfo: [NSLocalizedDescriptionKey: "相册写入没有成功"])) }
            })
        }
    }
}

/// 调系统「存储到文件」面板，让用户自己选位置。
///
/// 注意：程序自己的目录是不可见的（Application Support），
/// 所以这里用 forExporting + asCopy —— 系统会把文件**复制**到用户选的地方，
/// 程序内的原件不受影响。
///
/// ★★ v1.0.159：**可以一次交多个文件**。用户的反馈是
///   「批量保存到手机文件夹，居然一个一个弹窗确认放到哪个文件」——
///   那是因为以前每个文件单独弹一次面板（`forExporting: [一个 url]`）。
///   一次交多个时，iOS 换的是一套**选文件夹**的面板：选一次，全部写进去。
///
/// 不用 `@Binding isPresented` 而是用回调：外层用 `.sheet(item:)` 弹出，
/// 关掉时把 item 置 nil 即可 —— 这样也不会有「弹出了但内容为空」的白屏问题。
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: (Bool) -> Void

    /// 老的单文件调用点（备份 / 单条导出）—— 一行都不用改
    init(url: URL, onFinish: @escaping (Bool) -> Void) {
        self.urls = [url]
        self.onFinish = onFinish
    }

    /// ★ v1.0.159 批量：一次把多个文件交给系统，只问一次"存到哪个文件夹"
    init(urls: [URL], onFinish: @escaping (Bool) -> Void) {
        self.urls = urls
        self.onFinish = onFinish
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        vc.delegate = context.coordinator
        vc.shouldShowFileExtensions = true
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coord {
        Coord(onFinish: onFinish)
    }

    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
            onFinish(false)
        }

        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }
    }
}
