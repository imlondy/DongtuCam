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

/// 把「带文字的 HEIC 静帧 + 配好元数据的 MOV」交给 PhotoKit 配成一张实况照片。
///
/// ## v19：只剩一种提交方式，因为它必须不再崩
///
/// 历史上的三种尝试（A 图 data + 视频 data / B 图 data + 视频 fileURL /
/// C 再加 shouldMoveFile）里，真机崩溃现场多次停在 `save.commit-B`，
/// 随后是 `!! 信号崩溃 signal=5`（SIGTRAP = 框架内部断言，catch 不到）。
/// 结论很直接：**用 fileURL 提交配对视频这条路在这台机器上会直接打死进程**，
/// 无论原因是什么（沙盒扩展 / 资源校验），都不能再留作「重试」——
/// 重试一个会崩进程的分支，等于每次失败都必然崩一次。
///
/// 所以现在：
///   1. 只尝试 A（两个资源都用 Data 提交，不涉及文件 URL，v10 真机验证通过）；
///   2. 失败就如实返回错误（含 PhotoKit 错误码），由调用方降级成「照片 + 视频分别存」；
///   3. 就算真的崩了，静帧和视频都已在暂存区，下次启动会自动补存。
///
/// 另外 v19 修掉了更根本的一致性缺陷（见 `StillGeometry`）：静帧与视频的
/// 编码尺寸 / 方向此前不一致，PhotoKit 会判这对资源无效，这才是 A 一直失败的原因。
enum LivePhotoWriter {
    static func save(still: URL, video: URL, report: String = "",
                     completion: @escaping (Result<Void, Error>) -> Void) {
        Diagnostics.mark("save.begin")
        guard let stillData = try? Data(contentsOf: still) else {
            Diagnostics.mark("save.still-unreadable")
            completion(.failure(LivePhotoWriterError.failed("无法读取静帧文件")))
            return
        }
        guard let videoData = try? Data(contentsOf: video) else {
            Diagnostics.mark("save.video-unreadable")
            completion(.failure(LivePhotoWriterError.failed("无法读取视频文件")))
            return
        }

        authorize(addOnly: true) { allowed in
            guard allowed else {
                Diagnostics.mark("save.denied")
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            // 写库前先让系统认一遍这对文件（纯读，不写库）：能认成 PHLivePhoto
            // 说明配对元数据正确，剩下的只是 PhotoKit 收不收这对资源
            preflight(still: still, video: video) { note in
                let context = [report, note].filter { !$0.isEmpty }.joined(separator: " ")
                commit(stillData: stillData, videoData: videoData, context: context,
                       completion: completion)
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

    // MARK: - 提交（只用 data，绝不碰 fileURL）

    private static func commit(stillData: Data, videoData: Data, context: String,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        let sizeMB = Double(videoData.count) / 1024.0 / 1024.0
        Diagnostics.mark("save.commit-data")
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()

            // 静帧：给上文件名（.HEIC 后缀让 PhotoKit 不必去猜类型）
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.originalFilename = "IMG_DTC.HEIC"
            creation.addResource(with: .photo, data: stillData, options: photoOptions)

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.originalFilename = "IMG_DTC.MOV"
            creation.addResource(with: .pairedVideo, data: videoData, options: videoOptions)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    Diagnostics.mark("save.commit-ok")
                    completion(.success(()))
                    return
                }
                Diagnostics.mark("save.commit-failed")
                var message = "实况提交被系统拒绝"
                if let nsError = error as NSError? {
                    message += "（\(nsError.domain) \(nsError.code)）"
                    let keys = nsError.userInfo.keys
                        .map { "\($0)" }
                        .filter { $0.contains("PH") || $0.contains("Resource") }
                        .sorted()
                        .joined(separator: ",")
                    if !keys.isEmpty { message += " [\(keys)]" }
                }
                message += String(format: " · 视频%.1fMB", sizeMB)
                if !context.isEmpty { message += " · \(String(context.suffix(150)))" }
                completion(.failure(LivePhotoWriterError.failed(message)))
            }
        }
    }
}
