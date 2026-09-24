import Foundation
import Photos
import SwiftUI
import UIKit

/// 把程序内的成品交给系统 —— 由用户自己选择存到相册还是某个文件夹。
/// 这两个动作都**只在用户点按钮时**发生，程序不会自作主张往外面写。
enum Saver {

    enum Fail: LocalizedError {
        case noPhotoPermission
        case notMP4

        var errorDescription: String? {
            switch self {
            case .noPhotoPermission:
                return "没有相册写入权限。请到 设置 → 隐私与安全性 → 照片 里允许「视频抓取」添加照片。"
            case .notMP4:
                return "只有转好的 MP4 才能存进相册（相册不认 .ts）。"
            }
        }
    }

    /// 存到系统相册
    static func toPhotos(_ url: URL) async throws {
        guard url.pathExtension.lowercased() == "mp4" else { throw Fail.notMP4 }

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
                req.addResource(with: .video, fileURL: url, options: opt)
            }, completionHandler: { ok, err in
                if let err { c.resume(throwing: err) }
                else if ok { c.resume() }
                else { c.resume(throwing: NSError(domain: "VideoGrab", code: 9,
                                                  userInfo: [NSLocalizedDescriptionKey: "相册写入没有成功"])) }
            })
        }
    }

    /// 存一张图到系统相册（工具箱 · 截图用）。
    /// 授权那段跟上面存视频是同一套规则：只在用户点了按钮时才请求。
    static func toPhotos(image: UIImage) async throws {
        let status: PHAuthorizationStatus = await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in c.resume(returning: s) }
        }
        guard status == .authorized || status == .limited else { throw Fail.noPhotoPermission }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, err in
                if let err { c.resume(throwing: err) }
                else if ok { c.resume() }
                else { c.resume(throwing: NSError(domain: "VideoGrab", code: 10,
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
/// 不用 `@Binding isPresented` 而是用回调：外层用 `.sheet(item:)` 弹出，
/// 关掉时把 item 置 nil 即可 —— 这样也不会有「弹出了但内容为空」的白屏问题。
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    var onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
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
