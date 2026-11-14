import AVFoundation
import CoreMedia
import CoreImage
import UIKit
import ImageIO

struct BurnOutput {
    let stillURL: URL
    let videoURL: URL
    let identifier: String
    /// 自检结果（如 "still=heic img17=ok movId=ok sit=ok"），写库失败时会带进错误提示
    let report: String
}

enum BurnEngineError: LocalizedError {
    case noVideoTrack
    case writerFailed(String)
    case stillFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "素材里没有视频轨"
        case .writerFailed(let r): return "视频导出失败：\(r)"
        case .stillFailed(let r): return "静帧生成失败：\(r)"
        }
    }
}

/// 产出一对能配成实况照片的文件：带文字的 HEIC 静帧 + 带文字的 MOV 视频。
///
/// 实况照片能不能存进相册，取决于三件事，缺一项就是 PHPhotosErrorDomain 3302：
///   1. 静帧必须是 **HEIC**，且 iPhone 内部 MakerApple 的 "17" 字段 == 配对标识
///      （iOS 15.1 起 JPEG 已不再写这个字段，用 JPEG 必失败）；
///   2. 视频的文件级元数据里 com.apple.quicktime.content.identifier == 同一个标识；
///   3. 视频里必须有一条 timed metadata 轨道 com.apple.quicktime.still-image-time
///      （值 0xFF，即 SInt8 的 -1），告诉系统封面静帧对应哪一帧。
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

        // —— ① 烧字导出（AVAssetExportSession 最稳，不手动设 renderSize/frameDuration）——
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
            // —— ② 无损重封装，注入两条配对元数据 ——
            remux(videoURL: intermediate, identifier: identifier) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let finalVideo):
                    // —— ③ 生成带标识的 HEIC 静帧 ——
                    // 关键：静帧从「已烧字的成片」抽，尺寸/朝向与视频天然一致，
                    // 避免「图片竖屏 1080x1440、视频横屏 1920x1080」这种配对不一致。
                    guard let frame = stillFrame(videoURL: finalVideo) else {
                        completion(.failure(BurnEngineError.stillFailed("无法解码视频帧")))
                        return
                    }
                    var notes: [String] = []
                    let made = makeStill(frame, identifier: identifier, notes: &notes)
                    guard let made else {
                        completion(.failure(BurnEngineError.stillFailed(
                            notes.joined(separator: " / "))))
                        return
                    }
                    let stillData = made.0
                    let stillName = made.1
                    let stillURL = tmpURL(stillName)
                    guard (try? stillData.write(to: stillURL)) != nil else {
                        completion(.failure(BurnEngineError.stillFailed("静帧落盘失败")))
                        return
                    }
                    let report = selfCheck(stillData: stillData, videoURL: finalVideo,
                                           identifier: identifier)
                    completion(.success(BurnOutput(stillURL: stillURL, videoURL: finalVideo,
                                                   identifier: identifier, report: report)))
                }
            }
        }
    }

    // MARK: - 视频：无损重封装 + 配对元数据

    private static func remux(videoURL: URL, identifier: String,
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

            let metadataInput = try stillImageTimeInput()
            metadataInput.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

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

            // 轨道级 still-image-time：必须写在第一个视频样本之前，值 0xFF(=SInt8 -1)
            let stillItem = AVMutableMetadataItem()
            stillItem.key = "com.apple.quicktime.still-image-time" as NSString
            stillItem.keySpace = .quickTimeMetadata
            stillItem.value = NSNumber(value: -1)
            stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
            adaptor.append(AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: .zero, duration: asset.duration)))
            metadataInput.markAsFinished()

            let group = DispatchGroup()

            group.enter()
            var videoDone = false
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.remux.video")) {
                if videoDone { return }
                while videoInput.isReadyForMoreMediaData {
                    guard let sample = videoOut.copyNextSampleBuffer(),
                          videoInput.append(sample) else {
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput, let audioOut {
                group.enter()
                var audioDone = false
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "dtc.remux.audio")) {
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

    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// still-image-time 的写入输入：必须带 SInt8 的 sourceFormatHint，否则运行期崩溃
    private static func stillImageTimeInput() throws -> AVAssetWriterInput {
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

    // MARK: - 静帧

    /// 从成片里抽一张「已经带字」的静帧（宽高与视频显示尺寸一致）
    private static func stillFrame(videoURL: URL) -> CGImage? {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(at: CMTime(value: 1, timescale: 10),
                                         actualTime: nil)
    }

    /// 依次尝试三种 HEIC 写入方式，只接受「读回来能拿到 17 号标识」的结果。
    ///
    /// 从零编码 HEIC 时 ImageIO 会静默丢掉 MakerApple，所以主路径是：
    /// 先编出一份合法 HEIC，再从这份已有的 HEIC 源用 AddImageFromSource 合并属性写回，
    /// 这样 Apple MakerNote 才会真正落进文件。
    private static func makeStill(_ image: CGImage, identifier: String,
                                  notes: inout [String]) -> (Data, String)? {
        // A：两遍法 + AddImageFromSource（主路径）
        if let base = encodeHEIC(image) {
            if let patched = patchMakerApple(base, identifier: identifier, fromSource: true) {
                if makerIdentifier(patched) == identifier {
                    notes.append("still=A")
                    return (patched, "still.heic")
                }
                notes.append("A:丢标识")
            } else {
                notes.append("A:回写失败")
            }
            // C：两遍法 + AddImage
            if let patched = patchMakerApple(base, identifier: identifier, fromSource: false) {
                if makerIdentifier(patched) == identifier {
                    notes.append("still=C")
                    return (patched, "still.heic")
                }
                notes.append("C:丢标识")
            }
        } else {
            notes.append("A:HEIC编码失败")
        }
        // B：一遍法，直接把 MakerApple 塞进编码属性
        if let direct = encodeHEIC(image, extra: [kCGImagePropertyMakerAppleDictionary: ["17": identifier]]),
           makerIdentifier(direct) == identifier {
            notes.append("still=B")
            return (direct, "still.heic")
        }
        notes.append("B:丢标识")
        return nil
    }

    private static func encodeHEIC(_ image: CGImage, extra: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                         "public.heic" as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        for (key, value) in extra { props[key] = value }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func patchMakerApple(_ base: Data, identifier: String,
                                        fromSource: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(base as CFData, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var maker: [String: Any] = [:]
        if let raw = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] {
            maker = raw
        } else if let raw = props[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any] {
            for (key, value) in raw {
                let name = (key as? String) ?? (key as? NSNumber)?.stringValue ?? ""
                if !name.isEmpty { maker[name] = value }
            }
        }
        maker["17"] = identifier
        props[kCGImagePropertyMakerAppleDictionary] = maker

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData,
                                                         "public.heic" as CFString, 1, nil) else {
            return nil
        }
        if fromSource {
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func makerIdentifier(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] else {
            return nil
        }
        if let dict = maker as? [String: Any], let value = dict["17"] as? String {
            return value
        }
        if let dict = maker as? [AnyHashable: Any] {
            for (key, value) in dict {
                let name = (key as? String) ?? (key as? NSNumber)?.stringValue ?? ""
                if name == "17", let text = value as? String { return text }
            }
        }
        return nil
    }

    // MARK: - 自检（不依赖相册权限，纯读文件）

    private static func selfCheck(stillData: Data, videoURL: URL, identifier: String) -> String {
        var parts: [String] = []

        var format = "?"
        if let src = CGImageSourceCreateWithData(stillData as CFData, nil),
           let type = CGImageSourceGetType(src) {
            format = String(type)
        }
        parts.append("still=\(format.replacingOccurrences(of: "public.", with: ""))")
        parts.append("img17=\(makerIdentifier(stillData) == identifier ? "ok" : "miss")")

        let asset = AVAsset(url: videoURL)
        var movIdentifier = "miss"
        for item in asset.metadata(forFormat: .quickTimeMetadata) {
            if (item.key as? String) == "com.apple.quicktime.content.identifier" {
                movIdentifier = (item.value as? String) == identifier ? "ok" : "diff"
            }
        }
        parts.append("movId=\(movIdentifier)")

        // 有独立的 metadata 轨道即视为成功（本例中除 still-image-time 外没有别的元数据轨）
        let stillTime = asset.tracks(withMediaType: .metadata).isEmpty ? "miss" : "ok"
        parts.append("sit=\(stillTime)")

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            parts.append("vsize=\(Int(abs(size.width)))x\(Int(abs(size.height)))")
        }
        return parts.joined(separator: " ")
    }

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }
}
