import Foundation
import Photos

enum LivePhotoWriterError: LocalizedError {
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "没有相册写入权限，请到 设置 → 隐私与安全性 → 照片 开启「添加照片」"
        case .failed(let reason): return "写入相册失败：\(reason)"
        }
    }
}

/// 在同一次 performChanges 里把 .photo 与 .pairedVideo 一起提交，由 iOS 完成实况照片配对。
///
/// 三个必须同时满足的点（缺任一都会 `PHPhotosErrorDomain 3302`）：
///   1. 两个资源在同一个 performChanges 闭包里添加；
///   2. 资源类型必须是 .photo + .pairedVideo；
///   3. 两个资源的 uniformTypeIdentifier 都显式设为 com.apple.live-photo
///      （系统靠它识别为 Live Photo 资源，不设会被当成「普通照片 + 普通视频」）。
///
/// 另外 .photo 用 data 提交（不是 fileURL）——用 fileURL 传 HEIC 时 PhotoKit
/// 解析资源 URL 易失败（错误里带 _PHResourceUrlsErrorKey）。
enum LivePhotoWriter {
    private static let livePhotoUTI = "com.apple.live-photo"

    static func save(still: URL, video: URL,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard let stillData = try? Data(contentsOf: still) else {
            completion(.failure(LivePhotoWriterError.failed("无法读取静帧文件")))
            return
        }

        let commit = {
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = livePhotoUTI
                creation.addResource(with: .photo, data: stillData, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.uniformTypeIdentifier = livePhotoUTI
                videoOptions.shouldMoveFile = true
                creation.addResource(with: .pairedVideo, fileURL: video, options: videoOptions)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(LivePhotoWriterError.failed(
                            error?.localizedDescription ?? "unknown")))
                    }
                }
            }
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            commit()
            return
        }
        guard status == .notDetermined else {
            completion(.failure(LivePhotoWriterError.denied))
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
            DispatchQueue.main.async {
                if granted == .authorized || granted == .limited {
                    commit()
                } else {
                    completion(.failure(LivePhotoWriterError.denied))
                }
            }
        }
    }
}
