import AVFoundation
import CoreImage
import UIKit
import ImageIO

struct BurnOutput {
    let stillURL: URL
    let videoURL: URL
}

enum BurnEngineError: LocalizedError {
    case noVideoTrack
    case writerFailed(String)
    case stillFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "素材里没有视频轨"
        case .writerFailed(let r): return "视频导出失败：\(r)"
        case .stillFailed: return "封面静帧生成失败"
        }
    }
}

/// 把同一张文字图同时烧进「静帧」和「视频每一帧」，产出可配对成 Live Photo 的一对文件。
///
/// 关键（三次踩坑后的最终结论）：
///   Live Photo 保存进相册时，PhotoKit 只接受「HEIC 静帧 + HEVC 编码的 MOV」这对组合。
///   任一条件不满足（静帧是 JPEG、或视频是 H.264）都会直接报
///   `PHPhotosErrorDomain 3302 (InvalidResource)`。
///
///   而且配对标识不能靠 AVAssetExportSession.metadata 写——它只能写文件级 metadata，
///   写不进视频轨道里的 timed metadata。必须用 AVAssetWriter + AVAssetWriterInputMetadataAdaptor
///   把 com.apple.quicktime.content.identifier 与 com.apple.quicktime.still-image-time
///   写到视频轨道的开头。still-image-time 的值应为 -1（表示封面是独立 HEIC，不是从视频抽帧）。
enum BurnEngine {
    static func render(source: URL, overlay: CGImage, seconds: Double = 5.0,
                       completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let asset = AVAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }

        // HEIC 静帧与 MOV 视频共用的配对标识
        let identifier = UUID().uuidString
        let textCI = CIImage(cgImage: overlay)

        // 转正后的输出尺寸（CIFilter handler 会自动应用 preferredTransform）
        let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let width = even(Int(abs(natural.width)))
        let height = even(Int(abs(natural.height)))
        let renderSize = CGSize(width: width, height: height)

        let duration = CMTimeMinimum(asset.duration,
                                     CMTime(seconds: seconds, preferredTimescale: 600))
        let outVideo = tmpURL("burn.mov")

        do {
            // —— 读取端：逐帧转正 + 烧字 ——
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            let composition = AVMutableVideoComposition(
                asset: asset,
                applyingCIFiltersWithHandler: { request in
                    let src = request.sourceImage
                    let sx = src.extent.width / max(1, textCI.extent.width)
                    let sy = src.extent.height / max(1, textCI.extent.height)
                    let fitted = textCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    request.finish(with: fitted.composited(over: src), context: nil)
                })
            composition.renderSize = renderSize
            composition.frameDuration = CMTime(value: 1, timescale: 30)
            readerOutput.videoComposition = composition
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)

            // —— 写入端：强制 HEVC + 视频轨道级配对元数据 ——
            let writer = try AVAssetWriter(outputURL: outVideo, fileType: .mov)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ])
            videoInput.expectsMediaDataInRealTime = false

            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil)
            metadataInput.expectsMediaDataInRealTime = false
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

            guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
                completion(.failure(BurnEngineError.writerFailed("无法添加写入输入")))
                return
            }
            writer.add(videoInput)
            writer.add(metadataInput)

            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            reader.startReading()

            // 视频第一帧之前写入配对元数据（必须在此处，而不是导出后再补）
            let group = AVTimedMetadataGroup(
                items: livePhotoMetadata(identifier: identifier),
                timeRange: CMTimeRange(start: .zero,
                                       duration: CMTime(value: 1, timescale: 600)))
            metadataAdaptor.append(group)

            let queue = DispatchQueue(label: "dtc.burn.write")
            var done = false
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData && !done {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !videoInput.append(sample) { done = true }
                    } else {
                        done = true
                    }
                }
                guard done else { return }
                videoInput.markAsFinished()
                metadataInput.markAsFinished()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        if writer.status == .completed {
                            completion(makeStill(asset: asset, textCI: textCI,
                                                 videoURL: outVideo, identifier: identifier))
                        } else {
                            let reason = writer.error?.localizedDescription
                                ?? "status=\(writer.status.rawValue)"
                            completion(.failure(BurnEngineError.writerFailed(reason)))
                        }
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// 视频侧配对元数据：content identifier + still-image-time(-1)
    private static func livePhotoMetadata(identifier: String) -> [AVMetadataItem] {
        let contentID = AVMutableMetadataItem()
        contentID.keySpace = .quickTimeMetadata
        contentID.key = "com.apple.quicktime.content.identifier" as NSString
        contentID.value = identifier as NSString

        let stillTime = AVMutableMetadataItem()
        stillTime.keySpace = .quickTimeMetadata
        stillTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillTime.value = -1 as NSNumber

        return [contentID, stillTime]
    }

    /// 静帧必须带文字（否则长按实况时文字会「闪现一下再消失」），
    /// 且必须存成 HEIC 并把配对标识写进 MakerApple 的 "17" 字段。
    private static func makeStill(asset: AVAsset, textCI: CIImage,
                                  videoURL: URL, identifier: String) -> Result<BurnOutput, Error> {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 24),
                                                  actualTime: nil)
            let stillCI = CIImage(cgImage: frame)
            let sx = stillCI.extent.width / max(1, textCI.extent.width)
            let sy = stillCI.extent.height / max(1, textCI.extent.height)
            let fitted = textCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let merged = fitted.composited(over: stillCI)
            guard let out = CIContext().createCGImage(merged, from: merged.extent),
                  let heic = heicData(from: out, identifier: identifier, quality: 0.9) else {
                return .failure(BurnEngineError.stillFailed)
            }
            let outStill = tmpURL("still.heic")
            try heic.write(to: outStill)
            return .success(BurnOutput(stillURL: outStill, videoURL: videoURL))
        } catch {
            return .failure(error)
        }
    }

    /// 编码 HEIC，并把配对标识写进 MakerApple 元数据的 "17" 字段
    private static func heicData(from image: CGImage, identifier: String, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                          "public.heic" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func even(_ v: Int) -> Int {
        let e = v - (v % 2)
        return max(2, e)
    }

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }
}
