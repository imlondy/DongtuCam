import AVFoundation
import CoreMedia
import CoreImage
import UIKit
import ImageIO

struct StillOutput {
    let url: URL
    let data: Data
    let report: String
}

struct VideoOutput {
    let url: URL
    /// 走了哪条路：burn=on / burn=skip(原因) / passthrough
    let mode: String
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

/// 把「原始首帧 + 文字层」做成 HEIC 静帧，把相机原片做成配好元数据的视频。
///
/// ## v16 的两个结构性改动
///
/// 1. **拆成两个独立步骤**（`makeStill` / `makeVideo`）。
///    v15 是一次调用做完两件事，中间崩溃则什么都不剩。现在每做完一步就把产物
///    落进 `ShotStore` 的暂存目录，配合崩溃后自动补存，任何一步挂掉都不会白拍。
///
/// 2. **修掉 AVAssetReader 的并发读取**。
///    自 v10 起，remux 与压字都是「一个 reader 挂视频+音频两个 output，
///    分别用两个队列调用 copyNextSampleBuffer」。AVAssetReader **不是线程安全**的，
///    这种写法属于数据竞争：大部分时候没事，偶发就整进程崩，且崩在哪完全随机
///    ——这正是「每个版本都闪退、每次位置都不一样」最合理的解释。
///    现在视频与音频各用一个独立 reader，彻底不存在共享状态。
///
/// ## 静帧为什么清晰
/// 文字层按 1:1 叠在原始首帧上（两者同像素尺寸，绝不缩放），直接编码 HEIC；
/// 不经过任何视频编解码往返，所以封面上的字是像素级干净的。
///
/// ## 实况照片能不能存进相册
/// 取决于三件事，缺一项就是 PHPhotosErrorDomain 3302：
///   1. 静帧是 HEIC，且 iPhone 内部 MakerApple 的 "17" 字段 == 配对标识；
///   2. 视频文件级元数据 com.apple.quicktime.content.identifier == 同一标识；
///   3. 视频里有一条 timed metadata 轨 com.apple.quicktime.still-image-time（0xFF）。
enum BurnEngine {

    // MARK: - 静帧

    /// - Parameters:
    ///   - frame: 已转正的首帧（= 成片尺寸）
    ///   - overlay: 同尺寸透明文字层；为 nil 时输出无字静帧（文案环节失败时的降级）
    static func makeStill(frame: CGImage, overlay: CGImage?, identifier: String,
                          completion: @escaping (Result<StillOutput, Error>) -> Void) {
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
            guard let made = autoreleasepool(invoking: {
                makeStillData(composed, identifier: identifier, notes: &notes)
            }) else {
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.stillFailed(notes.joined(separator: " / "))))
                }
                return
            }

            let url = tmpURL("still.heic")
            guard (try? made.write(to: url)) != nil else {
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.stillFailed("静帧落盘失败")))
                }
                return
            }
            Diagnostics.mark("burn.still-ok")
            DispatchQueue.main.async {
                completion(.success(StillOutput(url: url, data: made,
                                                report: notes.joined(separator: " / "))))
            }
        }
    }

    /// 把首帧与文字层压成一张不透明位图（两者同尺寸，绝不缩放）
    private static func flatten(frame: CGImage, overlay: CGImage?) -> CGImage? {
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
            if let overlay {
                UIImage(cgImage: overlay).draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return image.cgImage
    }

    // MARK: - 视频

    /// 视频段：相机原片**无损重封装** + 注入配对元数据。不解码、不重编码。
    ///
    /// 这是 v10~v14 在真机上验证过唯一稳定出「动图」的路。逐帧压字通道
    /// （VideoBurner，v15/v16）在真机上持续闪退，v17 起整体移除：
    /// 文字只印在静帧上，动图播放时画面里没有字。
    static func makeVideo(source: URL, identifier: String,
                          completion: @escaping (Result<VideoOutput, Error>) -> Void) {
        remux(videoURL: source, identifier: identifier) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let url):
                completion(.success(VideoOutput(url: url, mode: "passthrough")))
            }
        }
    }

    /// 无损重封装 + 写入配对元数据。不解码、不重编码。
    ///
    /// ## v18 的两条铁律（都是拿真机闪退换来的教训）
    ///
    /// 1. **视频轨-only**：原生 Live Photo 的配对视频本来就没有音轨，
    ///    所以只读视频轨——一个 reader、一个 output、一个队列，零共享状态。
    ///    v16 曾给同一素材建两个 AVAssetReader（视频/音频各一），真机必崩；
    ///    v10~v14 单 reader 双 output 双队列并发是数据竞争，也不可靠。
    /// 2. **全程后台线程**：AVAsset 同步加载、reader/writer 搭建、startReading
    ///    全部离开主线程（v14 的模型）。v16 重写后这段跑回了主线程，真机持续闪退。
    private static func remux(videoURL: URL, identifier: String,
                              completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            Diagnostics.mark("burn.remux")
            let asset = AVAsset(url: videoURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                Diagnostics.mark("burn.remux-notrack")
                DispatchQueue.main.async {
                    completion(.failure(BurnEngineError.noVideoTrack))
                }
                return
            }
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
                    DispatchQueue.main.async {
                        completion(.failure(BurnEngineError.writerFailed("无法读取视频轨")))
                    }
                    return
                }
                reader.add(videoOut)

                let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
                writer.metadata = [contentIdentifierItem(identifier)]

                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
                videoInput.expectsMediaDataInRealTime = false

                let metadataInput = try stillImageTimeInput()
                metadataInput.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

                guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
                    DispatchQueue.main.async {
                        completion(.failure(BurnEngineError.writerFailed("无法添加写入输入")))
                    }
                    return
                }
                writer.add(videoInput)
                writer.add(metadataInput)

                Diagnostics.mark("burn.remux-startw")
                guard writer.startWriting() else {
                    let reason = writer.error?.localizedDescription ?? "startWriting 失败"
                    Diagnostics.mark("burn.remux-startw-failed")
                    DispatchQueue.main.async {
                        completion(.failure(BurnEngineError.writerFailed(reason)))
                    }
                    return
                }
                writer.startSession(atSourceTime: .zero)
                guard reader.startReading() else {
                    writer.cancelWriting()
                    Diagnostics.mark("burn.remux-startread-failed")
                    DispatchQueue.main.async {
                        completion(.failure(BurnEngineError.writerFailed("startReading 失败")))
                    }
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
                Diagnostics.mark("burn.remux-meta-ok")

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

                group.notify(queue: .main) {
                    Diagnostics.mark("burn.remux-samples-done")
                    writer.finishWriting {
                        DispatchQueue.main.async {
                            if writer.status == .completed {
                                completion(.success(outURL))
                            } else {
                                let reason = writer.error?.localizedDescription
                                    ?? "status=\(writer.status.rawValue)"
                                Diagnostics.mark("burn.remux-finish-failed")
                                completion(.failure(BurnEngineError.writerFailed(reason)))
                            }
                        }
                    }
                }
            } catch {
                Diagnostics.mark("burn.remux-throw")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
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

    // MARK: - HEIC 编码

    /// 依次尝试三种 HEIC 写入方式，只接受「读回来能拿到 17 号标识」的结果。
    ///
    /// 从零编码 HEIC 时 ImageIO 会静默丢掉 MakerApple，所以主路径是：
    /// 先编出一份合法 HEIC，再从这份已有的 HEIC 源用 AddImageFromSource 合并属性写回，
    /// 这样 Apple MakerNote 才会真正落进文件。
    private static func makeStillData(_ image: CGImage, identifier: String,
                                      notes: inout [String]) -> Data? {
        // A：两遍法 + AddImageFromSource（主路径）
        if let base = encodeHEIC(image) {
            if let patched = patchMakerApple(base, identifier: identifier, fromSource: true) {
                if makerIdentifier(patched) == identifier {
                    notes.append("still=A")
                    return patched
                }
                notes.append("A:丢标识")
            } else {
                notes.append("A:回写失败")
            }
            // C：两遍法 + AddImage
            if let patched = patchMakerApple(base, identifier: identifier, fromSource: false) {
                if makerIdentifier(patched) == identifier {
                    notes.append("still=C")
                    return patched
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
            return direct
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
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.98]
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

    static func selfCheck(stillURL: URL, videoURL: URL, identifier: String) -> String {
        var parts: [String] = []

        var format = "?"
        var makerOK = "miss"
        if let src = CGImageSourceCreateWithURL(stillURL as CFURL, nil),
           let type = CGImageSourceGetType(src) {
            format = String(type).replacingOccurrences(of: "public.", with: "")
            if let data = try? Data(contentsOf: stillURL) {
                makerOK = makerIdentifier(data) == identifier ? "ok" : "miss"
            }
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                parts.append("ssize=\(w)x\(h)")
            }
        }
        parts.append("still=\(format)")
        parts.append("img17=\(makerOK)")

        let asset = AVAsset(url: videoURL)
        var movIdentifier = "miss"
        for item in asset.metadata(forFormat: .quickTimeMetadata) {
            if (item.key as? String) == "com.apple.quicktime.content.identifier" {
                movIdentifier = (item.value as? String) == identifier ? "ok" : "diff"
            }
        }
        parts.append("movId=\(movIdentifier)")

        let stillTime = asset.tracks(withMediaType: .metadata).isEmpty ? "miss" : "ok"
        parts.append("sit=\(stillTime)")

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            parts.append("vsize=\(Int(abs(size.width)))x\(Int(abs(size.height)))")
        }
        return parts.joined(separator: " ")
    }

    static func tmpURL(_ name: String) -> URL {
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
