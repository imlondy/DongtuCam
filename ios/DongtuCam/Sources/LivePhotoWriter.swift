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
/// 配对本身靠文件内部标识（图片 MakerApple 17 == 视频 content.identifier
/// + still-image-time 轨），这一点已用 PHLivePhoto.request 现场验证（pair=ok）。
/// 真机实测剩下的失败点是「资源怎么递给 PhotoKit」：报
/// `PHPhotosErrorDomain -1` 且带 `_PHResourceUrlsErrorKey`，
/// 说明 PhotoKit 读不了以 fileURL 形式提交的那个视频。
///
/// 因此按「最不容易出错」到「最传统」的顺序依次尝试：
///   A. 图片 data + 视频 data（完全不涉及文件 URL）
///   B. 图片 data + 视频 fileURL（不移动文件）
///   C. 图片 data + 视频 fileURL + shouldMoveFile（Apple 官方示例写法）
/// 若三种都被拒，再升级到「完整相册权限」用 A 重试一次
/// （部分系统在 addOnly 权限下会拒绝创建实况）。
enum LivePhotoWriter {
    static func save(still: URL, video: URL, report: String = "",
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard let stillData = try? Data(contentsOf: still) else {
            completion(.failure(LivePhotoWriterError.failed("无法读取静帧文件")))
            return
        }
        guard let videoData = try? Data(contentsOf: video) else {
            completion(.failure(LivePhotoWriterError.failed("无法读取视频文件")))
            return
        }

        authorize(addOnly: true) { allowed in
            guard allowed else {
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            // 写库前先让系统认一遍这对文件：能认成 PHLivePhoto 说明配对元数据正确
            preflight(still: still, video: video) { note in
                let context = [report, note].filter { !$0.isEmpty }.joined(separator: " ")
                attempt(0, stillData: stillData, videoData: videoData, videoURL: video,
                        context: context) { result in
                    switch result {
                    case .success:
                        completion(.success(()))
                    case .failure(let lastError):
                        // 兜底：升级到完整相册权限，再用 data 方式试一次
                        authorize(addOnly: false) { full in
                            guard full else {
                                completion(.failure(lastError))
                                return
                            }
                            commit(mode: .bothData, stillData: stillData,
                                   videoData: videoData, videoURL: video,
                                   context: context) { retried in
                                switch retried {
                                case .success:
                                    completion(.success(()))
                                case .failure:
                                    completion(.failure(lastError))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 降级：只存照片

    /// 实况配对失败时的兜底：至少把「带字的那张 HEIC」存成普通照片，
    /// 让用户这一拍不完全白费（界面上会写明实况没配上）。
    static func saveStill(_ still: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        Diagnostics.mark("save.still-begin")
        authorize(addOnly: true) { allowed in
            guard allowed else {
                Diagnostics.mark("save.still-denied")
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "DTC_TEXT.HEIC"
                creation.addResource(with: .photo, fileURL: still, options: options)
            } completionHandler: { success, error in
                Diagnostics.mark(success ? "save.still-ok" : "save.still-failed")
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        let reason = error?.localizedDescription ?? "未知错误"
                        completion(.failure(LivePhotoWriterError.failed("存照片失败：\(reason)")))
                    }
                }
            }
        }
    }

    // MARK: - 降级：只存视频

    /// 最后一道兜底：把视频原样存成普通视频。
    ///
    /// 这条不是「可选项」而是**安全网**：处理链路任何一步失败甚至进程被带走，
    /// 只要原片还在，至少能让用户拿到一段视频（用户对 v13 的印象就是
    /// 「闪退但相册里有视频」，说明这个兜底是有价值的）。
    static func saveVideo(_ video: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        Diagnostics.mark("save.video-begin")
        guard FileManager.default.fileExists(atPath: video.path) else {
            Diagnostics.mark("save.video-missing")
            completion(.failure(LivePhotoWriterError.failed("视频文件不存在")))
            return
        }
        authorize(addOnly: true) { allowed in
            guard allowed else {
                Diagnostics.mark("save.video-denied")
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "DTC_CLIP.MOV"
                // 不移动：暂存目录里的原片要留着，恢复流程可能还要用
                options.shouldMoveFile = false
                creation.addResource(with: .video, fileURL: video, options: options)
            } completionHandler: { success, error in
                Diagnostics.mark(success ? "save.video-ok" : "save.video-failed")
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        let reason = error?.localizedDescription ?? "未知错误"
                        completion(.failure(LivePhotoWriterError.failed("存视频失败：\(reason)")))
                    }
                }
            }
        }
    }

    // MARK: - 依次尝试三种提交方式

    private enum Mode: String {
        case bothData = "A(图data+视频data)"
        case urlNoMove = "B(图data+视频url)"
        case urlMove = "C(图data+视频url+move)"
    }

    private static let modes: [Mode] = [.bothData, .urlNoMove, .urlMove]

    private static func attempt(_ index: Int, stillData: Data, videoData: Data,
                                videoURL: URL, context: String,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        guard index < modes.count else {
            completion(.failure(LivePhotoWriterError.failed(
                "三种提交方式均被系统拒绝 · \(String(context.suffix(140)))")))
            return
        }
        commit(mode: modes[index], stillData: stillData, videoData: videoData,
               videoURL: videoURL, context: context) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure:
                attempt(index + 1, stillData: stillData, videoData: videoData,
                        videoURL: videoURL, context: context, completion: completion)
            }
        }
    }

    // MARK: - 权限

    private static func authorize(addOnly: Bool, _ done: @escaping (Bool) -> Void) {
        let level: PHAccessLevel = addOnly ? .addOnly : .readWrite
        let status = PHPhotoLibrary.authorizationStatus(for: level)
        if status == .authorized || status == .limited {
            done(true)
            return
        }
        guard status == .notDetermined else {
            done(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: level) { next in
            let ok = (next == .authorized || next == .limited)
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - 本地预校验（不写库，纯诊断）

    private static func preflight(still: URL, video: URL,
                                  done: @escaping (String) -> Void) {
        Diagnostics.mark("save.preflight")
        PHLivePhoto.request(withResourceFileURLs: [still, video],
                            placeholderImage: nil,
                            // 别用 .zero：那会按全尺寸解码整套实况，内存峰值陡增；
                            // 配对校验只需要小图
                            targetSize: CGSize(width: 320, height: 428),
                            contentMode: .aspectFit) { photo, info in
            var note = photo != nil ? "pair=ok" : "pair=nil"
            if photo == nil, let error = info[PHLivePhotoInfoErrorKey] as? NSError {
                note += "(\(error.code))"
            }
            Diagnostics.mark("save.preflight-\(photo != nil ? "ok" : "nil")")
            DispatchQueue.main.async { done(note) }
        }
    }

    // MARK: - 提交

    private static func commit(mode: Mode, stillData: Data, videoData: Data,
                               videoURL: URL, context: String,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        let sizeMB = Double(videoData.count) / 1024.0 / 1024.0
        Diagnostics.mark("save.commit-\(mode.rawValue)")
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()

            // 静帧：官方写法用 data + options: nil（PhotoKit 从数据本身判断是 HEIC）
            creation.addResource(with: .photo, data: stillData, options: nil)

            switch mode {
            case .bothData:
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = "IMG_LIVE.MOV"
                creation.addResource(with: .pairedVideo, data: videoData, options: videoOptions)
            case .urlNoMove, .urlMove:
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = "IMG_LIVE.MOV"
                videoOptions.shouldMoveFile = (mode == .urlMove)
                creation.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                    return
                }
                var message = "[\(mode.rawValue)] "
                if let nsError = error {
                    let ns = nsError as NSError
                    message += "错误 \(ns.code)"
                    let keys = ns.userInfo.keys
                        .map { "\($0)" }
                        .filter { $0.contains("PH") || $0.contains("Resource") }
                        .sorted()
                        .joined(separator: ",")
                    if !keys.isEmpty { message += " [\(keys)]" }
                } else {
                    message += "未知错误"
                }
                message += String(format: " · 视频%.1fMB", sizeMB)
                if !context.isEmpty { message += " · \(String(context.suffix(120)))" }
                completion(.failure(LivePhotoWriterError.failed(message)))
            }
        }
    }
}
