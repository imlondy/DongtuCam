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

/// 产出可配对成 Live Photo 的一对文件（带文字的静帧 + 带文字的 H.264 视频）。
///
/// 拆成两步，避开 AVAssetReaderVideoCompositionOutput 手动抽帧的崩溃（iOS 27 上
/// applyingCIFiltersWithHandler 的 composition 再手动强设 renderSize/frameDuration
/// 会触发 `_figAssetReaderSampleBufferDidBecomeAvailableForExtractionID` 内部异常）：
///   第一步：AVAssetExportSession 烧字导出 H.264 MOV（简单、已验证稳定）；
///   第二步：AVAssetReaderTrackOutput + AVAssetWriterInput 走 passthrough 无损重封装，
///           只注入 Live Photo 配对元数据，不重新编码、不碰 CIFilter。
///
/// 元数据两条（对应已验证写法）：
///   content.identifier —— 文件级，写 AVAssetWriter.metadata；
///   still-image-time —— 轨道级 timed metadata，带 sourceFormatHint(SInt8)，值 -1。
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
        let duration = CMTimeMinimum(asset.duration,
                                     CMTime(seconds: seconds, preferredTimescale: 600))

        // —— 第一步：AVAssetExportSession 烧字（不手动设 renderSize/frameDuration）——
        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let src = request.sourceImage
                let sx = src.extent.width / max(1, textCI.extent.width)
                let sy = src.extent.height / max(1, textCI.extent.height)
                let fitted = textCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                request.finish(with: fitted.composited(over: src), context: nil)
            })

        let intermediate = tmpURL("intermediate.mov")
        guard let exporter = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(BurnEngineError.writerFailed("无法创建导出会话")))
            return
        }
        exporter.outputURL = intermediate
        exporter.outputFileType = .mov
        exporter.videoComposition = composition
        exporter.timeRange = CMTimeRange(start: .zero, duration: duration)

        exporter.exportAsynchronously {
            guard exporter.status == .completed else {
                let reason = exporter.error?.localizedDescription
                    ?? "status=\(exporter.status.rawValue)"
                completion(.failure(BurnEngineError.writerFailed(reason)))
                return
            }
            // —— 第二步：passthrough 重封装 + 注入配对元数据 ——
            injectMetadata(videoURL: intermediate, identifier: identifier) { injected in
                switch injected {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let finalVideo):
                    completion(makeStill(asset: asset, textCI: textCI,
                                         videoURL: finalVideo, identifier: identifier))
                }
            }
        }
    }

    /// 无损重封装：读原视频 sample → 原样写回，只加两条 Live Photo 配对元数据
    private static func injectMetadata(videoURL: URL, identifier: String,
                                       completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            completion(.failure(BurnEngineError.writerFailed("中间视频没有视频轨")))
            return
        }
        let outURL = tmpURL("burn.mov")

        do {
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
            writer.metadata = [contentIdentifierItem(identifier)]

            // passthrough：不重新编码
            let videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: nil,
                                                sourceFormatHint: track.formatDescriptions.first)
            videoInput.expectsMediaDataInRealTime = false

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

            // 轨道级 still-image-time
            let stillItem = AVMutableMetadataItem()
            stillItem.key = "com.apple.quicktime.still-image-time" as NSString
            stillItem.keySpace = .quickTimeMetadata
            stillItem.value = -1 as NSNumber
            stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
            metadataAdaptor.append(AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: .zero, duration: asset.duration)))

            let queue = DispatchQueue(label: "dtc.meta.write")
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
                            completion(.success(outURL))
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

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }
}
