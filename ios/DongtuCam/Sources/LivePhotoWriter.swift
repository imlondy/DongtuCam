import Foundation
import Photos
import UIKit

enum LivePhotoWriterError: LocalizedError {
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "没有相册写入权限，请到 设置 → 隐私与安全性 → 照片 开启「添加照片」"
        case .failed(let reason): return reason
        }
    }
}

/// 把「带文字的 HEIC 静帧 + 带文字的 MOV」交给 PhotoKit 配成一张实况照片。
///
/// 这里刻意贴着 Apple 官方可运行的写法（见 iOS 26 实况照片保存问题的官方示例）：
///
///     let creation = PHAssetCreationRequest.forAsset()
///     creation.addResource(with: .photo, data: stillData, options: nil)
///     let opts = PHAssetResourceCreationOptions()
///     opts.shouldMoveFile = true
///     creation.addResource(with: .pairedVideo, fileURL: movieURL, options: opts)
///
/// 关键点：
///   · **不要**给资源设 uniformTypeIdentifier = "com.apple.live-photo"。
///     那样 PhotoKit 会把资源当成「实况容器」而不是 HEIC/MOV，直接判资源无效（3302）。
///     配对靠的是文件内部的标识（图片 MakerApple 17 == 视频 content.identifier），
///     不是靠 UTI 声明。
///   · 静帧必须是 HEIC（iOS 15.1 起 JPEG 无法携带 MakerApple 17）。
///   · 两个资源必须在同一次 performChanges 里提交，否则会变成「一张照片 + 一段视频」。
enum LivePhotoWriter {
    static func save(still: URL, video: URL, report: String = "",
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard let stillData = try? Data(contentsOf: still) else {
            completion(.failure(LivePhotoWriterError.failed("无法读取静帧文件")))
            return
        }

        authorize { allowed in
            guard allowed else {
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            // 写相册前先让系统自己认一遍这对资源：能认成 PHLivePhoto，配对元数据才算真对。
            preflight(still: still, video: video) { note in
                commit(stillData: stillData, video: video,
                       context: [report, note].filter { !$0.isEmpty }.joined(separator: " "),
                       completion: completion)
            }
        }
    }

    // MARK: - 权限

    private static func authorize(_ done: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            done(true)
            return
        }
        guard status == .notDetermined else {
            done(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { next in
            let ok = (next == .authorized || next == .limited)
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - 本地预校验（不写库，纯诊断）

    private static func preflight(still: URL, video: URL,
                                  done: @escaping (String) -> Void) {
        PHLivePhoto.request(withResourceFileURLs: [still, video],
                            placeholderImage: nil,
                            targetSize: .zero,
                            contentMode: .aspectFit) { photo, info in
            let note: String
            if photo != nil {
                note = "pair=ok"
            } else {
                note = "pair=nil\(errorCode(info))"
            }
            DispatchQueue.main.async { done(note) }
        }
    }

    private static func errorCode(_ info: [AnyHashable: Any]) -> String {
        if let error = info[PHLivePhotoInfoErrorKey] as? NSError {
            return "(\(error.domain) \(error.code))"
        }
        return ""
    }

    // MARK: - 提交

    private static func commit(stillData: Data, video: URL, context: String,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            // 官方写法：静帧用 data + options: nil，让 PhotoKit 从数据本身判断类型（HEIC）
            creation.addResource(with: .photo, data: stillData, options: nil)

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = true
            creation.addResource(with: .pairedVideo, fileURL: video, options: videoOptions)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                    return
                }
                var message = error?.localizedDescription ?? "unknown"
                if let nsError = error {
                    let ns = nsError as NSError
                    let keys = ns.userInfo.keys
                        .map { "\($0)" }
                        .filter { $0.contains("PH") || $0.contains("Resource") }
                        .sorted()
                        .joined(separator: ",")
                    if !keys.isEmpty { message += " [\(keys)]" }
                }
                if !context.isEmpty {
                    message += " · \(String(context.prefix(150)))"
                }
                completion(.failure(LivePhotoWriterError.failed(message)))
            }
        }
    }
}
