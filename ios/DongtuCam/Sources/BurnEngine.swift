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
/// 三步走：
///   ① AVAssetExportSession 烧字导出 H.264 MOV（保留音频，不手动设 renderSize/frameDuration）；
///   ② passthrough 无损重封装（video + audio），注入 content.identifier（文件级）
///      与 still-image-time（轨道级 timed metadata，值 0）；
///   ③ 生成静帧：HEIC 优先，写入 MakerApple "17" 配对标识后**读回校验**，
///      校验失败自动降级 JPEG；两者都带标识，保证 PhotoKit 能配对。
enum BurnEngine {
    static func render(source: URL, overlay: CGImage, seconds: Double = 5.0,
                       completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let asset = AVAsset(url: source)
        guard asset.tracks(withMediaType: .video).first != nil else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }
        let identifier = UUID().uuidString
        let textCI = CIImage(cgImage: overlay)
        let duration = CMTimeMinimum(asset.duration,
                                     CMTime(seconds: seconds, preferredTimescale: 600))

        // —— ① 烧字导出 ——
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
            // —— ② 重封装 + 元数据 ——
            remuxWithMetadata(videoURL: intermediate, identifier: identifier) { remuxed in
                switch remuxed {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let finalVideo):
                    // —— ③ 静帧 ——
                    guard let still = makeStill(asset: asset, textCI: textCI,
                                                identifier: identifier) else {
                        completion(.failure(BurnEngineError.stillFailed))
                        return
                    }
                    completion(.success(BurnOutput(stillURL: still, videoURL: finalVideo)))
                }
            }
        }
    }

    /// 无损重封装 video + audio，只加两条 Live Photo 配对元数据
    private static func remuxWithMetadata(videoURL: URL, identifier: String,
                                          completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(BurnEngineError.writerFailed("中间视频没有视频轨")))
            return
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let outURL = tmpURL("burn.mov")

        do {
            let reader = try AVAssetReader(asset: asset)
            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            reader.add(videoOut)
            var audioOut: AVAssetReaderTrackOutput?
            if let audioTrack {
                let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                reader.add(o)
                audioOut = o
            }

            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
            writer.metadata = [contentIdentifierItem(identifier)]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            videoInput.expectsMediaDataInRealTime = false

            var audioInput: AVAssetWriterInput?
            if audioOut != nil {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                ai.expectsMediaDataInRealTime = false
                audioInput = ai
            }

            let metadataInput = try makeStillImageTimeInput()
            metadataInput.expectsMediaDataInRealTime = false
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

            guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
                completion(.failure(BurnEngineError.writerFailed("无法添加写入输入")))
                return
            }
            writer.add(videoInput)
            if let audioInput { writer.add(audioInput) }
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
            stillItem.value = 0 as NSNumber
            stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
            metadataAdaptor.append(AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: .zero, duration: asset.duration)))

            let group = DispatchGroup()

            group.enter()
            var vDone = false
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.meta.video")) {
                if vDone { return }
                while videoInput.isReadyForMoreMediaData {
                    guard let sample = videoOut.copyNextSampleBuffer(),
                          videoInput.append(sample) else {
                        vDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput, let audioOut {
                group.enter()
                var aDone = false
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.meta.audio")) {
                    if aDone { return }
                    while audioInput.isReadyForMoreMediaData {
                        guard let sample = audioOut.copyNextSampleBuffer(),
                              audioInput.append(sample) else {
                            aDone = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .main) {
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

    /// 静帧：带文字 + 写 MakerApple "17" 配对标识并读回校验（HEIC 优先，降级 JPEG）
    private static func makeStill(asset: AVAsset, textCI: CIImage, identifier: String) -> URL? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let frame = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 24),
                                                     actualTime: nil) else {
            return nil
        }
        let stillCI = CIImage(cgImage: frame)
        let sx = stillCI.extent.width / max(1, textCI.extent.width)
        let sy = stillCI.extent.height / max(1, textCI.extent.height)
        let fitted = textCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let merged = fitted.composited(over: stillCI)
        guard let out = CIContext().createCGImage(merged, from: merged.extent) else {
            return nil
        }

        // HEIC 优先（校验配对标识真的写进去了）
        if let heic = encode(out, uti: "public.heic", identifier: identifier),
           hasIdentifier(heic, identifier: identifier) {
            let url = tmpURL("still.heic")
            if (try? heic.write(to: url)) != nil { return url }
        }
        // 降级 JPEG（同样带标识）
        if let jpeg = encode(out, uti: "public.jpeg", identifier: identifier),
           hasIdentifier(jpeg, identifier: identifier) {
            let url = tmpURL("still.jpg")
            if (try? jpeg.write(to: url)) != nil { return url }
        }
        // 最后保底：JPEG（不再强校验）
        if let jpeg = encode(out, uti: "public.jpeg", identifier: identifier) {
            let url = tmpURL("still.jpg")
            if (try? jpeg.write(to: url)) != nil { return url }
        }
        return nil
    }

    /// 编码图片并把配对标识写进 MakerApple 的 "17" 字段
    private static func encode(_ image: CGImage, uti: String, identifier: String) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                          uti as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 读回校验 MakerApple "17" 是否等于 identifier（key 可能是 String 或 NSNumber）
    private static func hasIdentifier(_ data: Data, identifier: String) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any] else {
            return false
        }
        for (key, value) in maker {
            let keyString = (key as? String) ?? (key as? NSNumber)?.stringValue ?? ""
            if keyString == "17", let s = value as? String, s == identifier {
                return true
            }
        }
        return false
    }

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }
}
