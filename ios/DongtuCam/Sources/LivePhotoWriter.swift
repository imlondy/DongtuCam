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

/// 唯一能消除「最后一跳」的地方：
/// 在同一次 performChanges 里把 .photo 与 .pairedVideo 一起提交，
/// 由 iOS 自己完成实况照片配对（系统生成 ContentIdentifier / still-image-time，
/// 不再需要手写任何元数据，也不需要爱思助手 / intoLive）。
enum LivePhotoWriter {
    static func save(still: URL, video: URL,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        let commit = {
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: .photo, fileURL: still, options: nil)
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                creation.addResource(with: .pairedVideo, fileURL: video, options: options)
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
