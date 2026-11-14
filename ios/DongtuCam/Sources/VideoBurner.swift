import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import UIKit

/// 输出偏好：单独存 UserDefaults，不塞进 `AIConfig`。
///
/// 原因是 `AIConfig` 走合成 Codable：给结构体加新字段会让**旧版本已保存的配置
/// 解码失败**，而解码失败在 `AISettings.init` 里会被 `try?` 吞掉 → 用户填过的
/// Base URL / Key / 模型名全被重置成默认值。为了一个开关付这个代价不值得。
enum OutputPrefs {
    private static let key = "dtc.burn.into.video"

    /// 默认开启：文案要能在动图播放时也看到
    static var burnIntoVideo: Bool {
        get {
            if let saved = UserDefaults.standard.object(forKey: key) as? Bool { return saved }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 「文案也压进动图」的独立通道：把同一张静态文字层逐帧贴进视频，再交给
/// `BurnEngine.remux` 注入实况配对元数据。
///
/// ## 为什么单独写成一条最笨的路
///
/// v11~v13 的闪退来自 `AVAssetExportSession` + `applyingCIFiltersWithHandler`：
/// 那是一整套由系统托管的「逐帧滤镜会话 + VideoToolbox 编码」，内部状态、峰值
/// 内存、线程都不在我们手里，出问题直接把进程带走，我们连面包屑都留不下。
///
/// 这里换成完全自己掌控的三段：
///   AVAssetReader(32BGRA 出帧) → CIContext 合成一帧（视频帧 + 文字层）
///   → AVAssetWriter(H.264) 逐个 append
///
/// 每一帧都是「取一帧、合成一帧、写一帧」，没有回调风暴，没有隐式渲染队列。
/// 出错只会得到 `writer.status == .failed` 和一个 error，不会崩。
///
/// ## 为什么文字在动图里是「固定」的
///
/// 文字层是一张**静态图**（`TextLayer` 渲染的那张），每一帧都贴在同一组坐标上，
/// 所以动图播放时文字钉在画面位置不动，只有背后的画面在动。
///
/// ## 代价
///
/// 视频需要重编码一次（H.264），5 秒 1080p 大约 1~3 秒；画质会有一次性轻微压缩。
/// 静帧（封面照片）依然用**原始首帧**合成，所以封面上的文字仍是像素级清晰。
enum VideoBurner {

    /// 共用 CIContext（Metal）。只在一个后台队列里用，避免并发创建多个 GPU 上下文。
    private static let context: CIContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 保证 completion 只被调用一次。
    ///
    /// 这个锁不是洁癖：`CheckedContinuation` 被 resume 两次会直接
    /// `Fatal error: SWIFT TASK CONTINUATION MISUSE` —— 那才是真的闪退。
    /// 这条链路有「正常完成 / 超时看门狗」两条出口，必须互斥。
    private final class Once {
        private let lock = NSLock()
        private var done = false
        func run(_ block: () -> Void) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            block()
        }
    }

    /// - Parameters:
    ///   - source: 相机原始录制文件
    ///   - overlay: 与成片同尺寸（renderSize）的透明文字层
    ///   - renderSize: 成片像素尺寸（= 转正后的视频尺寸，也 = 静帧尺寸）
    ///   - completion: 带字的临时 MOV（**未注入配对元数据**，需再走 remux）
    static func burn(source: URL, overlay: CGImage, renderSize: CGSize,
                     completion: @escaping (Result<URL, Error>) -> Void) {
        let once = Once()
        func finish(_ result: Result<URL, Error>) {
            once.run { completion(result) }
        }

        // H.264 要求宽高为偶数，奇数会被编码器拒绝（直接 failed）
        let width = max(2, Int(renderSize.width.rounded()) / 2 * 2)
        let height = max(2, Int(renderSize.height.rounded()) / 2 * 2)
        let outSize = CGSize(width: width, height: height)

        let asset = AVAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            finish(.failure(BurnEngineError.noVideoTrack))
            return
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-burned.mov")
        try? FileManager.default.removeItem(at: outURL)

        // 方向矩阵：录制文件通常是「横着存、靠 preferredTransform 转正」，
        // 必须一次性把帧摆正，否则文字会贴到旋转过的画面上。
        let natural = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let upright = CGSize(width: abs(box.width), height: abs(box.height))
        var matrix = transform.concatenating(
            CGAffineTransform(translationX: -box.minX, y: -box.minY))
        if upright.width > 1, upright.height > 1,
           abs(upright.width - outSize.width) > 1 || abs(upright.height - outSize.height) > 1 {
            matrix = matrix.concatenating(
                CGAffineTransform(scaleX: outSize.width / upright.width,
                                  y: outSize.height / upright.height))
        }

        let overlayCI = CIImage(cgImage: overlay)

        do {
            let reader = try AVAssetReader(asset: asset)
            let videoOut = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            videoOut.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOut) else {
                finish(.failure(BurnEngineError.writerFailed("无法读取视频帧")))
                return
            }
            reader.add(videoOut)

            var audioOut: AVAssetReaderTrackOutput?
            if let audioTrack {
                let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                if reader.canAdd(o) {
                    reader.add(o)
                    audioOut = o
                }
            }

            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

            let fps = max(24.0, min(60.0, Double(videoTrack.nominalFrameRate)))
            // 码率按像素给，系数 6：1080x1920 ≈ 12.4Mbps。
            // 系数取 4（8.3Mbps）时文字边缘就能看出块状；字是高频细节，
            // 压缩最伤的就是它，所以宁可多占几 MB 也要把边缘保住。
            let bitrate = Double(width * height) * 6.0
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitrate),
                    AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                    AVVideoExpectedSourceFrameRateKey: Int(fps),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = false

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ])

            var audioInput: AVAssetWriterInput?
            if audioOut != nil {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) { audioInput = ai }
            }

            guard writer.canAdd(videoInput) else {
                finish(.failure(BurnEngineError.writerFailed("无法添加视频输入")))
                return
            }
            writer.add(videoInput)
            if let audioInput { writer.add(audioInput) }

            guard writer.startWriting() else {
                let reason = writer.error?.localizedDescription ?? "startWriting 失败"
                finish(.failure(BurnEngineError.writerFailed(reason)))
                return
            }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else {
                writer.cancelWriting()
                finish(.failure(BurnEngineError.writerFailed("startReading 失败")))
                return
            }
            Diagnostics.mark("burn.video-writing")

            // 看门狗：编码器万一拿到帧却一直不 ready，这里兜底退出，别让界面永远转圈
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak writer] in
                guard let writer, writer.status == .writing else { return }
                writer.cancelWriting()
                finish(.failure(BurnEngineError.writerFailed("压字超时（75s）")))
            }

            let group = DispatchGroup()
            var frames = 0
            var burnError: Error?

            group.enter()
            var videoDone = false
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.burn.video")) {
                if videoDone { return }
                while videoInput.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = videoOut.copyNextSampleBuffer() else {
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        burnError = BurnEngineError.writerFailed("没有可用的像素缓冲池")
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    var dst: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                          let dst, let src = CMSampleBufferGetImageBuffer(sample) else {
                        // 单帧失败就跳过，别因一帧把整段视频废掉
                        continue
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let composed = overlayCI.composited(
                        over: CIImage(cvPixelBuffer: src).transformed(by: matrix))

                    // 不手动 lock：CIContext 渲染到 CVPixelBuffer 时会自己加锁，
                    // 我们再 lock 一层会和它的 IOSurface 访问打架。
                    context.render(composed, to: dst,
                                   bounds: CGRect(origin: .zero, size: outSize),
                                   colorSpace: colorSpace)

                    if adaptor.append(dst, withPresentationTime: pts) {
                        frames += 1
                    } else {
                        burnError = BurnEngineError.writerFailed(
                            "写帧失败 status=\(writer.status.rawValue) "
                            + (writer.error?.localizedDescription ?? ""))
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            // 音频：原样透传，不重编码（实况照片删了声音体验会不对）
            if let audioInput, let audioOut {
                group.enter()
                var audioDone = false
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.burn.audio")) {
                    if audioDone { return }
                    while audioInput.isReadyForMoreMediaData {
                        guard let sample = audioOut.copyNextSampleBuffer(),
                              audioInput.append(sample) else {
                            audioDone = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                if let burnError {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outURL)
                    finish(.failure(burnError))
                    return
                }
                guard frames > 0 else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outURL)
                    finish(.failure(BurnEngineError.writerFailed("没有取到任何视频帧")))
                    return
                }
                Diagnostics.mark("burn.video-frames-\(frames)")
                writer.finishWriting {
                    DispatchQueue.main.async {
                        if writer.status == .completed {
                            finish(.success(outURL))
                        } else {
                            try? FileManager.default.removeItem(at: outURL)
                            let reason = writer.error?.localizedDescription
                                ?? "status=\(writer.status.rawValue)"
                            finish(.failure(BurnEngineError.writerFailed(reason)))
                        }
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            finish(.failure(error))
        }
    }
}
