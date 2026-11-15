import Foundation
import Photos
import UIKit
import AVFoundation

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

/// 写库结果：用来区分「系统真的存成了实况」和「提交成功但只是一张普通照片」。
struct LivePhotoOutcome {
    /// true = 回读确认是实况；false = 存成了普通照片；nil = 没权限回读，无法确认
    let verifiedLive: Bool?
    /// 刚存进相册那张的 PHAsset 标识符（v23 起用于左下角缩略图与预览）
    let localIdentifier: String?
}

/// 把「带文字的 HEIC 静帧 + 配好元数据的 MOV」交给 PhotoKit 配成一张实况照片。
///
/// ## v20：两个资源都走 fileURL（这是唯一正确的投递方式）
///
/// v19 的真机日志是唯一一次拿到完整现场，信息量很大：
/// ```
/// save.preflight-ok              ← 系统能把这对文件解成 PHLivePhoto，配对元数据是对的
/// save.commit-data               ← 用 Data 提交这一对
/// save.commit-failed             ← 两次都失败
/// save.still-ok / save.video-ok  ← 同样这两个文件，单独用 fileURL 提交都成功
/// ```
///
/// 也就是说：**不是元数据的错，是「Data 投递」被 PhotoKit 拒绝。**
/// Photos 对实况配对的投递方式有隐藏约束——它不接受「一半 Data、一半文件」的混投，
/// 而 v18 那次 `signal=5`（SIGTRAP，框架内部断言）正是死在
/// 「图 data + 视频 url」的混合投递上。v19 改成两边都用 Data，虽然不崩了，
/// 但系统同样不收（这就是 commit-failed 两次都出现的原因）。
///
/// 所以 v20 只留一条路，也是所有「视频转实况」类 App 的标准写法：
/// **静帧和配对视频都走 fileURL，投递方式保持一致。**
/// 顺带解决了内存问题：不再把整个视频读成 Data（几十 MB 常驻内存正是被系统
/// SIGKILL 的温床），系统按文件读，进程里只留一张静帧的字节。
///
/// 失败时把 PhotoKit 的错误码写进面包屑（如 `save.fail-3303`），下一轮不用再靠猜。
enum LivePhotoWriter {

    // MARK: - 主路径：实况配对

    static func save(still: URL, video: URL, report: String = "",
                     completion: @escaping (Result<LivePhotoOutcome, Error>) -> Void) {
        Diagnostics.markMem("save.begin")
        guard FileManager.default.fileExists(atPath: still.path) else {
            Diagnostics.mark("save.still-missing")
            completion(.failure(LivePhotoWriterError.failed("静帧文件不存在")))
            return
        }
        guard FileManager.default.fileExists(atPath: video.path) else {
            Diagnostics.mark("save.video-missing")
            completion(.failure(LivePhotoWriterError.failed("配对视频不存在")))
            return
        }

        authorizeForLive { level in
            Diagnostics.mark("save.auth-\(level)")
            // 写库前先让系统读一遍（纯读，不写库）：能解成 PHLivePhoto
            // 说明配对标识符没问题，剩下的只是投递方式
            preflight(still: still, video: video) { note in
                attempt(still: still, video: video, note: note, report: report,
                        index: 1, moveFile: false) { first in
                    if case .success = first {
                        completion(first)
                        return
                    }
                    // 第二种组合：让系统直接把文件搬进相册（省一次大块拷贝）。
                    // 两种都失败就是真不行了，交给上层降级成「照片 + 视频分开存」。
                    Diagnostics.mark("save.retry")
                    attempt(still: still, video: video, note: note, report: report,
                            index: 2, moveFile: true) { second in
                        completion(second)
                    }
                }
            }
        }
    }

    /// 提交一次配对。
    /// - Parameters:
    ///   - index: 第几次尝试（只用于在日志里区分）
    ///   - moveFile: 是否让系统把文件搬进相册（第二次尝试才用）
    private static func attempt(still: URL, video: URL, note: String, report: String,
                                index: Int, moveFile: Bool,
                                completion: @escaping (Result<LivePhotoOutcome, Error>) -> Void) {
        Diagnostics.mark("save.commit\(index)")
        var created: String?
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            // 带上创建时间：个别系统版本会因为没有时间而判资源无效
            creation.creationDate = Date()

            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.originalFilename = "IMG_DTC.HEIC"
            // 显式声明类型：只靠后缀去猜，猜错就是「资源无效」
            photoOptions.uniformTypeIdentifier = "public.heic"
            photoOptions.shouldMoveFile = moveFile

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.originalFilename = "IMG_DTC.MOV"
            videoOptions.uniformTypeIdentifier = "com.apple.quicktime-movie"
            videoOptions.shouldMoveFile = moveFile

            // 两个资源必须同一种投递方式（都用 URL），混投会被 PhotoKit 直接拒绝
            creation.addResource(with: .photo, fileURL: still, options: photoOptions)
            creation.addResource(with: .pairedVideo, fileURL: video, options: videoOptions)

            created = creation.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            if success {
                let isLive = verify(placeholder: created)
                if isLive == false {
                    // 系统收下了，但回读发现只是一张普通照片：不能对用户谎报成功
                    Diagnostics.mark("save.plain")
                    var message = "系统把它存成了普通照片（实况没配上）"
                    if !note.isEmpty { message += " · \(note)" }
                    DispatchQueue.main.async {
                        completion(.failure(LivePhotoWriterError.failed(message)))
                    }
                    return
                }
                Diagnostics.markMem(isLive == true ? "save.live-ok" : "save.ok-unverified")
                DispatchQueue.main.async {
                    completion(.success(LivePhotoOutcome(verifiedLive: isLive,
                                                         localIdentifier: created)))
                }
                return
            }
            let nsError = error as NSError?
            let code = nsError?.code ?? -1
            // 错误码进面包屑：文件里出现 save.fail1-3303 这种就是直接判据
            Diagnostics.mark("save.fail\(index)-\(code)")
            var message = "实况提交被系统拒绝（\(nsError?.domain ?? "?") \(code)）"
            if !note.isEmpty { message += " · \(note)" }
            if !report.isEmpty { message += " · \(String(report.suffix(120)))" }
            DispatchQueue.main.async {
                completion(.failure(LivePhotoWriterError.failed(message)))
            }
        }
    }

    /// 写完立刻回读，确认落进相册的确实是「实况」而不是一张普通照片。
    /// 只有拿到完整相册权限才读得到；拿不到就返回 nil（不影响主流程）。
    private static func verify(placeholder: String?) -> Bool? {
        guard let placeholder else {
            Diagnostics.mark("save.verify-no-id")
            return nil
        }
        let level = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard level == .authorized || level == .limited else {
            Diagnostics.mark("save.verify-skip")
            return nil
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder], options: nil)
        guard let asset = assets.firstObject else {
            Diagnostics.mark("save.verify-none")
            return nil
        }
        return asset.mediaSubtypes.contains(.photoLive)
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
                options.shouldMoveFile = false
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
    /// 只要原片还在，至少能让用户拿到一段视频。
    static func saveVideo(_ video: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        Diagnostics.mark("save.video-begin")
        guard FileManager.default.fileExists(atPath: video.path) else {
            Diagnostics.mark("save.video-gone")
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

    /// 转成「抖音友好」的容器：H.264 + mp4。
    ///
    /// 编码换成 H.264 是为了兼容：我们自己的成片是 HEVC，容易被走别的处理链。
    /// **默认不塞音轨** —— 抖音的「动图」语义上是无声循环，v32 塞了静音轨之后
    /// 用户实测"视频有了、角标没了"，所以这次把音轨去掉再验一次。
    static func transcodeCompat(_ video: URL,
                                withAudio: Bool = false,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        Diagnostics.mark("compat.begin")
        let asset = AVAsset(url: video)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(LivePhotoWriterError.failed("读不到视频轨")))
            return
        }
        let duration = asset.duration
        guard duration.isNumeric, duration.seconds > 0 else {
            completion(.failure(LivePhotoWriterError.failed("时长不可用")))
            return
        }

        let temp = FileManager.default.temporaryDirectory
        let silentURL = temp.appendingPathComponent("dtc-silent.wav")
        let outURL = temp.appendingPathComponent("dtc-douyin.mp4")
        try? FileManager.default.removeItem(at: outURL)

        var audioTrack: AVAssetTrack?
        if withAudio {
            do {
                try makeSilentAudio(seconds: duration.seconds, to: silentURL)
                audioTrack = AVAsset(url: silentURL).tracks(withMediaType: .audio).first
            } catch {
                Diagnostics.mark("compat.silent-failed")
                audioTrack = nil
            }
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(.failure(LivePhotoWriterError.failed("无法创建合成轨")))
            return
        }
        do {
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                          of: videoTrack, at: .zero)
            // 方向由 transform 承载，丢了就又回到「正拍变横屏」
            compVideo.preferredTransform = videoTrack.preferredTransform
            if let audioTrack,
               let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioRange = CMTimeRange(start: .zero,
                                             duration: CMTimeMinimum(duration, audioTrack.timeRange.duration))
                try compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
            }
        } catch {
            Diagnostics.mark("compat.insert-failed")
            completion(.failure(LivePhotoWriterError.failed("合成失败：\(error.localizedDescription)")))
            return
        }

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(LivePhotoWriterError.failed("无法创建导出会话")))
            return
        }
        exporter.outputURL = outURL
        exporter.outputFileType = exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously {
            if exporter.status == .completed {
                Diagnostics.mark("compat.export-ok")
                completion(.success(outURL))
            } else {
                Diagnostics.mark("compat.export-failed")
                let reason = exporter.error?.localizedDescription ?? "状态 \(exporter.status.rawValue)"
                completion(.failure(LivePhotoWriterError.failed("转码失败：\(reason)")))
            }
        }
    }

    /// 转码后存相册。转码失败就存原片，不让用户白等一次拍摄。
    static func saveCompatVideo(_ video: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        transcodeCompat(video) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    saveVideo(url, completion: completion)
                case .failure:
                    saveVideo(video, completion: completion)
                }
            }
        }
    }

    /// 造一条静音 PCM 轨。
    ///
    /// 抖音里正常的视频都带音轨；我们此前全程无音轨，是最可疑的差异之一。
    /// 全零 PCM 写成 wav，导出时由系统转成 AAC。
    private static func makeSilentAudio(seconds: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let pcm = file.processingFormat
        let frames = AVAudioFrameCount(max(1, seconds * pcm.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames) else {
            throw LivePhotoWriterError.failed("无法创建静音缓冲")
        }
        buffer.frameLength = frames
        // AVAudioPCMBuffer 的内存不保证清零，必须显式写 0，否则是爆音
        if let channels = buffer.floatChannelData {
            for index in 0..<Int(pcm.channelCount) {
                memset(channels[index], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        try file.write(from: buffer)
    }

    // MARK: - 权限

    /// 配对写入优先要「完整相册访问」（不只是「添加照片」）。
    ///
    /// 两个理由：
    ///   1. PhotoKit 写完配对资源后要回读校验，只有 addOnly 权限时更容易被直接拒绝；
    ///   2. 有完整权限才能回读确认「到底存成实况没有」，否则我们只能瞎猜。
    /// 拿不到就退回 addOnly 继续尝试，不阻断（降级成照片 + 视频仍然只要 addOnly）。
    private static func authorizeForLive(_ done: @escaping (String) -> Void) {
        let full = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if full == .authorized || full == .limited {
            done("full")
            return
        }
        if full == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { next in
                let ok = (next == .authorized || next == .limited)
                DispatchQueue.main.async { done(ok ? "full" : "addonly") }
            }
            return
        }
        done("addonly")
    }

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
        // 只允许回调一次：系统回调与下面 8 秒超时兜底二选一
        let once = OnceFlag()
        PHLivePhoto.request(withResourceFileURLs: [still, video],
                            placeholderImage: nil,
                            // 别用 .zero：那会按全尺寸解码整套实况，内存峰值陡增；
                            // 配对校验只需要小图
                            targetSize: CGSize(width: 320, height: 428),
                            contentMode: .aspectFit) { photo, info in
            guard once.claim() else { return }
            var note = photo != nil ? "pair=ok" : "pair=nil"
            if photo == nil, let error = info[PHLivePhotoInfoErrorKey] as? NSError {
                note += "(\(error.code))"
            }
            Diagnostics.mark("save.preflight-\(photo != nil ? "ok" : "nil")")
            DispatchQueue.main.async { done(note) }
        }
        // 万一系统不回调（极端情况），别让界面永远停在「写入相册…」
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard once.claim() else { return }
            Diagnostics.mark("save.preflight-timeout")
            done("pair=unknown")
        }
    }
}

/// 只允许成功一次的开关（跨线程安全）。用来保证异步回调只有一条路径生效。
final class OnceFlag {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
