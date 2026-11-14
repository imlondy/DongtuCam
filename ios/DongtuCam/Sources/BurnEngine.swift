import AVFoundation
import CoreMedia
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
/// Live Photo 的两个资源靠同一个 assetIdentifier 绑定：
///   1. 静帧（HEIC）的 MakerApple 字典里写 `{"17": identifier}`；
///   2. 视频（MOV，H.264）里写两条元数据：
///      - `com.apple.quicktime.content.identifier` = identifier —— 文件级 metadata
///        （写 AVAssetWriter.metadata，不是 timed metadata）；
///      - `com.apple.quicktime.still-image-time` —— 轨道级 timed metadata，
///        必须用带 sourceFormatHint（SInt8）的 AVAssetWriterInput 写入，值 -1（0xFF）。
///
/// 之前的坑：把两条都塞进 timed metadata、且 metadata input 没给 sourceFormatHint，
/// 导致写入格式不合法、录制结束瞬间闪退。
enum BurnEngine {
    static func render(source: URL, overlay: CGImage, seconds: Double = 5.0,
                       completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let asset = AVAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }

        let identifier = UUID().uuidString
        let textCI = CIImage(cgImage: overlay)

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

            // —— 写入端 ——
            let writer = try AVAssetWriter(outputURL: outVideo, fileType: .mov)

            // ① 视频：H.264（Live Photo 兼容、编码快、内存低）
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ])
            videoInput.expectsMediaDataInRealTime = false

            // ② content.identifier 写文件级 metadata
            writer.metadata = [contentIdentifierItem(identifier)]

            // ③ still-image-time 写轨道级 timed metadata（带 sourceFormatHint）
            let metadataInput = try makeStillImageTimeInput()
            metadataInput.expectsMediaDataInRealTime = false
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

            guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
                completion(.failure(BurnEngineError.writerFailed("无法添加写入输入")))
                return
            }
            writer.add(videoInput)
            writer.add(metadataInput)

            guard writer.startWriting() else {
                let reason = writer.error?.localizedDescription ?? "startWriting 失败"
                completion(.failure(BurnEngineError.writerFailed(reason)))
                return
            }
            writer.startSession(atSourceTime: .zero)
            reader.startReading()

            // 录制开始后、视频第一帧之前，写入 still-image-time
            let stillItem = AVMutableMetadataItem()
            stillItem.key = "com.apple.quicktime.still-image-time" as NSString
            stillItem.keySpace = .quickTimeMetadata
            stillItem.value = -1 as NSNumber
            stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
            metadataAdaptor.append(AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: .zero, duration: duration)))

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

    /// 文件级 content.identifier
    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// 轨道级 still-image-time 的写入输入：必须带 SInt8 的 sourceFormatHint
    private static func makeStillImageTimeInput() throws -> AVAssetWriterInput {
        let spec: [CFString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                kCMMetadataBaseDataType_SInt8
        ]
        var desc: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc)
        guard status == noErr, let desc else {
            throw BurnEngineError.writerFailed("无法创建 still-image-time 元数据格式")
        }
        return AVAssetWriterInput(mediaType: .metadata,
                                  outputSettings: nil,
                                  sourceFormatHint: desc)
    }

    /// 静帧：带文字 + HEIC + MakerApple "17" 配对标识
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
