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

/// 写库结果：用来区分「系统真的存成了实况」和「提交成功但只是一张普通照片」。
struct LivePhotoOutcome {
    /// true = 回读确认是实况；false = 存成了普通照片；nil = 没权限回读，无法确认
    let verifiedLive: Bool?
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

        authorize(addOnly: true) { allowed in
            guard allowed else {
                Diagnostics.mark("save.denied")
                completion(.failure(LivePhotoWriterError.denied))
                return
            }
            // 写库前先让系统读一遍（纯读，不写库）：能解成 PHLivePhoto
            // 说明配对元数据没问题，剩下的只是投递方式
            preflight(still: still, video: video) { note in
                commit(still: still, video: video, note: note, report: report,
                       completion: completion)
            }
        }
    }

    private static func commit(still: URL, video: URL, note: String, report: String,
                               completion: @escaping (Result<LivePhotoOutcome, Error>) -> Void) {
        Diagnostics.mark("save.commit")
        var created: String?
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()

            // 两个资源必须同一种投递方式（都用 URL）。混投会被 PhotoKit 直接拒绝。
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.originalFilename = "IMG_DTC.HEIC"
            photoOptions.shouldMoveFile = false

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.originalFilename = "IMG_DTC.MOV"
            // 不搬走：暂存目录里的这一对文件是「崩溃也能补存」的安全网，
            // 提交一旦失败还要靠它们降级重来。视频只有几 MB，拷一份不值得冒险。
            videoOptions.shouldMoveFile = false

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
                    completion(.success(LivePhotoOutcome(verifiedLive: isLive)))
                }
                return
            }
            let nsError = error as NSError?
            let code = nsError?.code ?? -1
            // 错误码先进面包屑：文件里出现 save.fail-3303 这种，就是直接判据
            Diagnostics.mark("save.fail-\(code)")
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
