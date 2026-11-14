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
    case composeFailed(String)
    case writerFailed(String)
    case stillFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "素材里没有视频轨"
        case .composeFailed(let r): return "静帧合成失败：\(r)"
        case .writerFailed(let r): return "视频封装失败：\(r)"
        case .stillFailed(let r): return "静帧生成失败：\(r)"
        }
    }
}

/// 产出一对能配成实况照片的文件：带文字的 HEIC 静帧 + 原始 MOV 视频。
///
/// ## v14 的两个关键改动（都来自真机反馈）
///
/// 1. **文字只合成到静帧上，视频一点不碰。**
///    以前文字是烧进视频再抽一帧当静帧，于是：字跟着画面/播放动效一起动，
///    而且一路经历「CIImage 缩放 → HEVC 编码 → 解码抽帧 → HEIC 编码」，
///    每一环都是丢细节，最后当然是一团糊。现在静帧是
///    「原始首帧 + CoreGraphics 文字层」一次性合成，文字按像素 1:1 绘制，
///    没有任何重采样，边缘是干净的抗锯齿。
///
/// 2. **去掉 AVAssetExportSession + applyingCIFiltersWithHandler 整条链路。**
///    那是 v11~v13 每轮闪退的共同起点（VideoToolbox 编码 + CI 每帧回调，
///    1080p 5 秒的峰值内存和内部断言都不受我们控制）。现在视频走
///    `AVAssetReader → AVAssetWriter` 的 passthrough，不解码、不重编码，
///    只是重新封装并写入两条配对元数据——这一步在 v10 起就稳定。
///
/// 实况照片能不能存进相册，取决于三件事，缺一项就是 PHPhotosErrorDomain 3302：
///   1. 静帧必须是 **HEIC**，且 iPhone 内部 MakerApple 的 "17" 字段 == 配对标识；
///   2. 视频的文件级元数据里 com.apple.quicktime.content.identifier == 同一个标识；
///   3. 视频里必须有一条 timed metadata 轨道 com.apple.quicktime.still-image-time
///      （值 0xFF，即 SInt8 的 -1），告诉系统封面静帧对应哪一帧。
enum BurnEngine {
    /// - Parameters:
    ///   - source: 相机原始录制文件（未做任何处理）
    ///   - frame: 已转正的首帧，用来做静帧底图（尺寸 = 成片尺寸）
    ///   - overlay: 与 frame 同尺寸的透明文字层
    static func compose(source: URL, frame: CGImage, overlay: CGImage,
                        completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let identifier = UUID().uuidString

        // 重活全部离开主线程：合成 + HEIC 编码 + 封装，主线程只负责刷 UI
        DispatchQueue.global(qos: .userInitiated).async {
            var notes: [String] = []
            Diagnostics.mark("burn.flatten")

            let composed = autoreleasepool { flatten(frame: frame, overlay: overlay) }
            guard let composed else {
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.composeFailed("画布创建失败")))
                }
                return
            }

            Diagnostics.mark("burn.heic")
            guard let made = makeStill(composed, identifier: identifier, notes: &notes) else {
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.stillFailed(notes.joined(separator: " / "))))
                }
                return
            }
            let stillData = made.0
            let stillName = made.1

            let stillURL = tmpURL(stillName)
            guard (try? stillData.write(to: stillURL)) != nil else {
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.stillFailed("静帧落盘失败")))
                }
                return
            }

            // 视频：原样 passthrough，只注入配对元数据
            Diagnostics.mark("burn.remux")
            remux(videoURL: source, identifier: identifier) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let finalVideo):
                    Diagnostics.mark("burn.remux-ok")
                    let report = selfCheck(stillData: stillData, stillURL: stillURL,
                                           videoURL: finalVideo, identifier: identifier)
                    completion(.success(BurnOutput(stillURL: stillURL,
                                                   videoURL: finalVideo,
                                                   identifier: identifier,
                                                   report: report)))
                }
            }
        }
    }

    /// 把首帧与文字层压成一张不透明位图（两者同尺寸，绝不缩放）
    private static func flatten(frame: CGImage, overlay: CGImage) -> CGImage? {
        let width = frame.width
        let height = frame.height
        guard width > 1, height > 1 else { return nil }
        let size = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // 固定 sRGB：广色域会让白字发灰、描边发糊
        format.preferredRange = .standard

        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: size))
            // draw(_:in:) 在 1:1 的矩形里是像素直拷，不会引入模糊
            UIImage(cgImage: overlay).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }

    // MARK: - 视频：无损重封装 + 配对元数据

    private static func remux(videoURL: URL, identifier: String,
                              completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let outURL = tmpURL("live.mov")

        // 时长的兜底：个别机型刚停止录制时 duration 还是 indefinite，
        // 直接拿它去建 timeRange 会抛异常
        var duration = asset.duration
        if !duration.isNumeric || duration.seconds <= 0 {
            duration = CMTime(seconds: 5, preferredTimescale: 600)
        }

        do {
            let reader = try AVAssetReader(asset: asset)
            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            guard reader.canAdd(videoOut) else {
                completion(.failure(BurnEngineError.writerFailed("无法读取视频轨")))
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
            writer.metadata = [contentIdentifierItem(identifier)]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            videoInput.expectsMediaDataInRealTime = false

            var audioInput: AVAssetWriterInput?
            if audioOut != nil {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                ai.expectsMediaDataInRealTime = false
                // 必须逐个确认能否添加：add 一个不被接受的输入会抛 ObjC 异常（闪退）
                if writer.canAdd(ai) { audioInput = ai }
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
            guard reader.startReading() else {
                writer.cancelWriting()
                completion(.failure(BurnEngineError.writerFailed("startReading 失败")))
                return
            }
            Diagnostics.mark("burn.remux-writing")

            // 轨道级 still-image-time：必须写在第一个视频样本之前，值 0xFF(=SInt8 -1)
            let stillItem = AVMutableMetadataItem()
            stillItem.key = "com.apple.quicktime.still-image-time" as NSString
            stillItem.keySpace = .quickTimeMetadata
            stillItem.value = NSNumber(value: -1)
            stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
            adaptor.append(AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: .zero, duration: duration)))
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
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.96]
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

    private static func selfCheck(stillData: Data, stillURL: URL,
                                  videoURL: URL, identifier: String) -> String {
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
        if let source = CGImageSourceCreateWithURL(stillURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            parts.append("ssize=\(w)x\(h)")
        }
        return parts.joined(separator: " ")
    }

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }

    /// 从原始录制文件里取一帧（已按 preferredTransform 转正）。
    /// 既是静帧底图，也是商品识别的输入。
    static func previewFrame(from url: URL, at seconds: Double = 0.1) -> CGImage? {
        let asset = AVAsset(url: url)
        guard asset.tracks(withMediaType: .video).first != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 容差给宽松：某些机型首帧不在精确位置上，零容差会直接取不到图
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                          actualTime: nil)
    }
}
