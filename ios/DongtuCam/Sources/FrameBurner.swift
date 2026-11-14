import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// 逐帧把文案压进视频，**同时把画面转正**。
///
/// ## 为什么 v15/v16 那一版崩，这一版不会
///
/// v15/v16 的 `VideoBurner` 用 `AVAssetReader` + `CIContext`（Metal）+ `AVAssetWriter`
/// 做逐帧合成，真机上持续闪退。复盘下来是三个独立的坑，这一版逐个绕开：
///
/// 1. **一个 reader 挂两个 output、两条队列并发** → AVAssetReader 不是线程安全的。
///    现在**一个 reader、一个 output、一条串行队列**，全程没有第二个线程碰它。
/// 2. **Metal CIContext 在后台线程 + 每帧新建 CIImage** → GPU 上下文与内存峰值不可控。
///    现在完全不用 Metal：reader 用 `AVAssetReaderVideoCompositionOutput` 直接吐出
///    目标尺寸的 32BGRA，逐帧只做一次 `memcpy` + 一次 CoreGraphics 文字绘制。
/// 3. **每帧都 `createCGImage` 再 `draw` 整幅画面** → 每帧多一份 8~15MB 的位图。
///    现在用 `CVPixelBufferPool` 复用缓冲，整段视频的常驻内存是常数（约两帧）。
///
/// ## 为什么用 VideoCompositionOutput 而不是 TrackOutput
///
/// 相机的原始视频是**横向编码 + preferredTransform 旋转**（竖拍 iPhone 的惯例）。
/// `AVAssetReaderTrackOutput` 吐出来的是编码方向的横向帧，自己在 CGContext 里转
/// 很容易把镜像/旋转顺序搞反（v20 的「倒图」就是这么来的）。
/// `AVAssetReaderVideoCompositionOutput` 由系统按 `preferredTransform` 转好，
/// 再按 `videoSettings` 里的宽高等比缩放 —— **输出就是拿手机竖着看到的样子**，
/// 写进新文件时 transform 保持 identity，播放器不会再自作主张转一次。
/// 这同时解决了「正拍的视频在动图播放时变成横屏」。
enum FrameBurner {

    struct Config {
        let source: URL
        let lines: [String]
        let previewFontPt: CGFloat
        let screenWidthPt: CGFloat
        let identifier: String
    }

    /// 输出最长边上限。相机格式最高到 1600 级，4K 机型也只降到 1920 —— 
    /// 抖音会把源再压一轮，源越清楚成片越清楚。
    private static let maxSide: CGFloat = 1920

    /// 同步执行并返回成品 URL。**必须在后台线程调用**（会阻塞到整段视频编码完）。
    static func run(_ config: Config) throws -> URL {
        Diagnostics.mark("burnV.begin")
        let asset = AVAsset(url: config.source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw BurnEngineError.noVideoTrack
        }

        // 显示方向的尺寸：编码尺寸经过 preferredTransform 之后的外接矩形
        let transform = track.preferredTransform
        let encoded = track.naturalSize
        let shown = CGSize(width: abs(encoded.applying(transform).width),
                           height: abs(encoded.applying(transform).height))
        guard shown.width > 1, shown.height > 1 else {
            throw BurnEngineError.writerFailed("无法识别画面尺寸")
        }

        // 等比缩放到 maxSide 以内，宽高取偶数（H.264 的硬性要求）
        let ratio = min(1, maxSide / max(shown.width, shown.height))
        let outW = max(2, Int((shown.width * ratio / 2).rounded()) * 2)
        let outH = max(2, Int((shown.height * ratio / 2).rounded()) * 2)
        Diagnostics.mark("burnV.size-\(outW)x\(outH)")

        var duration = asset.duration
        if !duration.isNumeric || duration.seconds <= 0 {
            duration = CMTime(seconds: 5, preferredTimescale: 600)
        }
        let fps = track.nominalFrameRate > 1 ? Double(track.nominalFrameRate) : 30.0
        let fpsInt = max(1, Int(fps.rounded()))

        // MARK: 转正 + 缩放
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fpsInt))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // 先按 preferredTransform 转正（编码 → 显示），再等比缩放到输出画布
        let fit = CGAffineTransform(scaleX: CGFloat(outW) / shown.width,
                                    y: CGFloat(outH) / shown.height)
        layer.setTransform(transform.concatenating(fit), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        // MARK: reader
        let reader = try AVAssetReader(asset: asset)
        let readSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH
        ]
        let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                               videoSettings: readSettings)
        readerOutput.videoComposition = composition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw BurnEngineError.writerFailed("无法读取视频轨")
        }
        reader.add(readerOutput)

        // MARK: writer
        let outURL = BurnEngine.tmpURL("burn.mov")
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        // 配对标识符 + 拍摄时间：实况的命根子，和静帧里的 17 号字段必须一致
        writer.metadata = [BurnEngine.contentIdentifierItem(config.identifier),
                           BurnEngine.creationDateItem()]

        // 码率给足：源很可能还要被抖音再压一轮，这里先留够余量
        let bitrate = Int(Double(outW * outH) * 8.0)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fpsInt
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // 帧已经是显示方向，transform 必须留 identity，否则播放器会再转一次（横屏 bug）
        videoInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])

        let metadataInput = try BurnEngine.stillImageTimeInput()
        metadataInput.expectsMediaDataInRealTime = false
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
            throw BurnEngineError.writerFailed("无法添加写入输入")
        }
        writer.add(videoInput)
        writer.add(metadataInput)

        guard writer.startWriting() else {
            throw BurnEngineError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw BurnEngineError.writerFailed("startReading 失败")
        }
        Diagnostics.mark("burnV.reading")

        // 轨道级 still-image-time 必须先于第一个视频样本写入
        let stillItem = AVMutableMetadataItem()
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.keySpace = .quickTimeMetadata
        stillItem.value = NSNumber(value: -1)
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        metadataAdaptor.append(AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        metadataInput.markAsFinished()

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw BurnEngineError.writerFailed("拿不到像素缓冲池")
        }

        // 与静帧同一套排版：字号按画布宽度换算，位置按高度比例，
        // 所以动图播放时文字和封面完全对齐，不会跳
        let canvas = CGSize(width: outW, height: outH)
        let layout = TextLayer.layout(lines: config.lines, size: canvas,
                                      previewFontPt: config.previewFontPt,
                                      screenWidthPt: config.screenWidthPt)
        Diagnostics.mark(layout == nil ? "burnV.nolayout" : "burnV.layout-\(Int(layout!.fontSize))")

        var frames = 0
        var failures = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            // 等编码器消化积压。串行等待在后台队列里是安全的（不会卡 UI）
            var spins = 0
            while !videoInput.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                Thread.sleep(forTimeInterval: 0.003)
                spins += 1
                if spins > 4000 { break }   // ~12 秒兜底，防止死等
            }
            guard writer.status == .writing else { break }

            guard let srcBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            var dstBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstBuffer) == kCVReturnSuccess,
                  let dst = dstBuffer else {
                failures += 1
                continue
            }

            copy(srcBuffer, to: dst, width: outW, height: outH)
            if let layout {
                paint(layout, into: dst, width: outW, height: outH)
            }
            if adaptor.append(dst, withPresentationTime: pts) {
                frames += 1
            } else {
                failures += 1
            }
        }

        videoInput.markAsFinished()
        Diagnostics.mark("burnV.frames-\(frames)-fail-\(failures)")

        // finishWriting 是异步的，这里在后台队列上等它收尾
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw BurnEngineError.writerFailed(
                writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)")
        }
        guard frames > 0 else {
            throw BurnEngineError.writerFailed("没有写出任何帧")
        }
        Diagnostics.mark("burnV.ok-\(frames)")
        return outURL
    }

    // MARK: - 像素搬运

    /// 整帧复制。每帧只做一次 `memcpy`，不建 CGImage、不建 CIImage。
    private static func copy(_ src: CVPixelBuffer, to dst: CVPixelBuffer,
                             width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return }

        let sBpr = CVPixelBufferGetBytesPerRow(src)
        let dBpr = CVPixelBufferGetBytesPerRow(dst)
        let rows = min(CVPixelBufferGetHeight(src), height)
        let cols = min(CVPixelBufferGetWidth(src), width)
        // 两个 buffer 的行跨度可能不同（对齐要求），逐行拷最稳
        let rowBytes = min(min(sBpr, dBpr), cols * 4)
        for row in 0..<rows {
            memcpy(d + row * dBpr, s + row * sBpr, rowBytes)
        }
    }

    /// 直接在目标像素缓冲上画文字。
    /// 缓冲是 32BGRA，CGContext 的 `premultipliedFirst + byteOrder32Little` 正好对应。
    private static func paint(_ layout: TextLayer.Layout, into buffer: CVPixelBuffer,
                              width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return
        }
        // 视频缓冲第一行是画面顶部，CGContext 原点在左下 —— 翻成 UIKit 坐标再画
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.normal)
        TextLayer.draw(layout, in: ctx)
    }
}
