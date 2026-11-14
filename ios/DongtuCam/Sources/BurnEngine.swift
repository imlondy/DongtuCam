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

    /// 静帧画布尺寸：**显示方向的帧再放大 2 倍**。
    ///
    /// 为什么要放大到 2 倍（v21 的 1.5 倍还不够）：
    /// 相机录的是 3:4，而手机屏是 9:16 —— 照片/动图在相册和抖音里按
    /// **aspectFill 铺满全屏**，横向要放大 `屏宽像素 / 画面宽` 倍。
    /// 以 3:4 为例，放大约 1.6~1.8 倍。
    /// 画布只有视频那么大（1080 宽）时，字等于被放大 1.8 倍显示 → 怎么都发毛；
    /// 1.5 倍（1620 宽）仍会被放大约 1.2 倍 → 还是毛；
    /// **2 倍（2160 宽）超过放大后的屏幕像素数（约 1920）→ 显示时是缩小，边缘最锐利。**
    /// 原生实况本来就是这样：照片分辨率远高于配对视频。
    /// 上限 2160，防止大底机型把内存和编码时间顶穿。
    static func stillCanvasSize(for frame: CGImage) -> CGSize {
        let w = CGFloat(frame.width)
        let h = CGFloat(frame.height)
        guard w > 1, h > 1 else { return CGSize(width: max(w, 2), height: max(h, 2)) }
        var scale: CGFloat = 2.0
        if w * scale > 2160 { scale = 2160 / w }
        if scale < 1 { scale = 1 }
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    /// - Parameters:
    ///   - frame: 已转正的首帧（显示方向）
    ///   - overlay: 与 `stillCanvasSize` 同尺寸的透明文字层；nil 时输出无字静帧
    ///   - source: 相机原片（保留参数以便上层统一调用）
    ///
    /// ## v21：彻底不写方向标记
    ///
    /// v19/v20 为「与视频编码尺寸一致」，把竖拍画面转回横向像素、再把方向写进
    /// EXIF。但 HEIC 的方向可以同时用 EXIF 和 `irot` 盒表达，两遍写入很容易被
    /// 应用两次 —— 真机上看到的就是**倒置的图**（90°+90°=180°）。
    ///
    /// 现在改成最不可能出错的做法：**像素就是显示方向，方向标记恒为 1**。
    /// 照片在相册、抖音、任何看图软件里都不会转错；配对也不受影响
    /// （配对只认资源标识符，不认尺寸方向）。
    static func makeStill(frame: CGImage, overlay: CGImage?, source: URL,
                          identifier: String,
                          completion: @escaping (Result<StillOutput, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var notes: [String] = []
            let canvas = stillCanvasSize(for: frame)
            notes.append("cs=\(Int(canvas.width))x\(Int(canvas.height))")

            Diagnostics.mark("burn.flatten")
            guard let composed = autoreleasepool(invoking: {
                flatten(frame: frame, overlay: overlay, canvas: canvas)
            }) else {
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

    /// 把首帧与文字层压成一张不透明位图。
    /// - 底图按画布尺寸放大一次（文字层已经按画布渲染，1:1 叠上去，不再缩放）
    private static func flatten(frame: CGImage, overlay: CGImage?, canvas: CGSize) -> CGImage? {
        guard canvas.width > 1, canvas.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // 固定 sRGB：广色域会让白字发灰、描边发糊
        format.preferredRange = .standard

        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: canvas))
            if let overlay {
                UIImage(cgImage: overlay).draw(in: CGRect(origin: .zero, size: canvas))
            }
        }
        return image.cgImage
    }

    // MARK: - 视频

    /// 视频段：**逐帧压字 + 转正**，失败则降级为无损重封装。
    ///
    /// v22 起文字不再只印在封面上 —— 动图播放时画面里也有字。
    /// v15/v16 的逐帧通道曾让真机持续崩溃，那是一套 Metal + 多 reader 的实现；
    /// 现在的 `FrameBurner` 改成了 CPU + 单队列 + 缓冲池复用（见该文件的说明）。
    ///
    /// 压字失败不影响出片：降级到 `remux`（原样无损封装，只是画面里没有字），
    /// 实况配对、方向修正、时长都照旧。
    static func makeVideo(source: URL, lines: [String],
                          previewFontPt: CGFloat, screenWidthPt: CGFloat,
                          identifier: String,
                          completion: @escaping (Result<VideoOutput, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !lines.isEmpty {
                do {
                    let url = try FrameBurner.run(FrameBurner.Config(
                        source: source,
                        lines: lines,
                        previewFontPt: previewFontPt,
                        screenWidthPt: screenWidthPt,
                        identifier: identifier))
                    DispatchQueue.main.async {
                        completion(.success(VideoOutput(url: url, mode: "burn")))
                    }
                    return
                } catch {
                    // 压字失败不是终点：无字动图也比一张图片强
                    Diagnostics.mark("burnV.failed-fallback")
                }
            } else {
                Diagnostics.mark("burnV.skipped-nolines")
            }

            remux(videoURL: source, identifier: identifier) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let url):
                    completion(.success(VideoOutput(url: url, mode: "passthrough")))
                }
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
                // 文件级元数据：配对标识符（实况的命根子）+ 创建时间
                writer.metadata = [contentIdentifierItem(identifier), creationDateItem()]

                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
                videoInput.expectsMediaDataInRealTime = false
                // **方向的关键**：直通写入 sample buffer 时，轨道方向不会跟着 sample 走，
                // 必须显式把源轨的 preferredTransform 带过去。漏掉这一行，
                // 竖拍的成片在播放器里就会被当成横向（v21 的「正拍变横屏」）。
                videoInput.transform = videoTrack.preferredTransform

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

    static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// 原生实况的配对视频都带拍摄时间；缺了它，个别系统版本会把它当成
    /// 「来源不明的片段」，进相册后排序也会乱。
    static func creationDateItem() -> AVMetadataItem {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.creationdate" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = formatter.string(from: Date()) as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// still-image-time 的写入输入：必须带 SInt8 的 sourceFormatHint，否则运行期崩溃
    static func stillImageTimeInput() throws -> AVAssetWriterInput {
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
    ///
    /// 两处 v21 的修正：
    ///   1. **方向标记恒为 1**（像素已经是正的，见 `makeStill` 的说明）；
    ///   2. **两遍都给满质量**——第二遍不传压缩质量时 ImageIO 按 0.8 重编，
    ///      白字边缘会被直接糊掉，这就是「文字一直不清晰」的真凶之一。
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
        if let direct = encodeHEIC(image,
                                   extra: [kCGImagePropertyMakerAppleDictionary: ["17": identifier]]),
           makerIdentifier(direct) == identifier {
            notes.append("still=B")
            return direct
        }
        notes.append("B:丢标识")
        return nil
    }

    /// 编码 HEIC：像素就是最终方向，不写方向标记；质量拉满
    private static func encodeHEIC(_ image: CGImage,
                                   extra: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                         "public.heic" as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        for (key, value) in extra { props[key] = value }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func patchMakerApple(_ base: Data, identifier: String,
                                        fromSource: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(base as CFData, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        // 方向恒为 1：像素已经转正，任何额外的旋转标记都会把图转歪（v20 的倒图就是它）
        props[kCGImagePropertyOrientation] = 1
        // 这一遍是重新编码，不显式给质量就会被默认的 0.8 糊掉
        props[kCGImageDestinationLossyCompressionQuality] = 1.0
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
                // 与视频编码尺寸/方向一致性：实况配对的硬性前提
                let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
                parts.append("so=\(orientation)")
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
            parts.append("vcode=\(Int(abs(track.naturalSize.width)))x\(Int(abs(track.naturalSize.height)))")
        }
        return parts.joined(separator: " ")
    }

    static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }

    /// 从原始录制文件里取一帧。
    /// - Parameter applyTransform: true = 按 preferredTransform 转正（显示方向，用于成片）；
    ///   false = 原始编码方向（用于探测视频轨的真实旋转）
    /// 既是静帧底图，也是商品识别的输入。
    static func previewFrame(from url: URL, at seconds: Double = 0.1,
                             applyTransform: Bool = true) -> CGImage? {
        let asset = AVAsset(url: url)
        guard asset.tracks(withMediaType: .video).first != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = applyTransform
        // 容差给宽松：某些机型首帧不在精确位置上，零容差会直接取不到图
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                          actualTime: nil)
    }
}
