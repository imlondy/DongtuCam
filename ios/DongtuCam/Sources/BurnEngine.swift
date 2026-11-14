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

/// 静帧的几何参数：**必须与配对视频的编码尺寸、方向一致**。
///
/// 这是 v19 找到的关键一致性缺陷。相机录制的视频是「编码横向 + 旋转矩阵」，
/// 而我们之前把首帧用 `appliesPreferredTrackTransform` 转正后直接编码成
/// 竖向像素（1080x1440，方向标记 = 1）。于是同一对实况里：
///   照片：编码 1080x1440（竖）+ 无方向标记
///   视频：编码 1440x1920（横）+ 90° 旋转矩阵
/// PhotoKit 在 `addResource(.pairedVideo)` 校验这一对时会判定资源不匹配
/// ——表现就是 mode A 返回失败、接着 mode B 在框架内部断言（signal=5）。
///
/// 原生实况照片从来都是「两者编码尺寸相同、靠方向标记/旋转矩阵显示」，
/// 所以这里改成同样的做法：静帧编码尺寸 = 视频编码尺寸，方向写进 EXIF。
struct StillGeometry {
    /// 编码方向 → 显示方向 的旋转
    enum Rotation: Equatable {
        case none, cw, ccw

        var opposite: Rotation {
            switch self {
            case .none: return .none
            case .cw: return .ccw
            case .ccw: return .cw
            }
        }

        /// 该旋转对应的 EXIF 方向（1 = 不旋转 / 6 = 顺转 90° / 8 = 逆转 90°）
        var exif: Int {
            switch self {
            case .none: return 1
            case .cw: return 6
            case .ccw: return 8
            }
        }
    }

    /// 编码方向 → 显示方向
    let rotation: Rotation
    /// 视频轨的编码尺寸（= 静帧应有的编码尺寸）
    let codedSize: CGSize
    /// 显示尺寸（= 预览/文字层的画布尺寸）
    let displaySize: CGSize

    /// 合成好的「显示方向」位图要再做哪个旋转，才能变回编码方向
    var storeRotation: Rotation { rotation.opposite }
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
    ///   - frame: 已转正的首帧（显示方向）
    ///   - overlay: 同尺寸透明文字层；为 nil 时输出无字静帧（文案环节失败时的降级）
    ///   - source: 相机原片，用来读视频轨的编码尺寸与旋转矩阵（对齐实况几何）
    static func makeStill(frame: CGImage, overlay: CGImage?, source: URL,
                          identifier: String,
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

            // 几何：静帧的编码尺寸与方向必须跟配对视频一致，否则 PhotoKit 判无效资源
            Diagnostics.mark("burn.geom")
            let geom = autoreleasepool { geometry(videoURL: source, display: frame) }
            notes.append("geom=\(Int(geom.codedSize.width))x\(Int(geom.codedSize.height))")
            notes.append("o=\(geom.rotation.exif)")

            Diagnostics.mark("burn.heic")
            guard let made = autoreleasepool(invoking: {
                encodeOriented(composed, geometry: geom, identifier: identifier, notes: &notes)
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

    // MARK: - 几何探测（编码尺寸 / 旋转方向）

    /// 读出视频轨的编码尺寸与「编码→显示」的旋转方向。
    ///
    /// 方向不靠猜：取同一时刻的**原始帧**与**转正帧**，各自缩成 16x16 灰度图，
    /// 把原始帧分别顺/逆转 90° 去比对，误差小的那个就是真实方向。
    private static func geometry(videoURL: URL, display: CGImage) -> StillGeometry {
        let displaySize = CGSize(width: display.width, height: display.height)
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return StillGeometry(rotation: .none, codedSize: displaySize, displaySize: displaySize)
        }
        let natural = track.naturalSize
        let coded = CGSize(width: abs(natural.width).rounded(), height: abs(natural.height).rounded())

        guard coded.width != displaySize.width || coded.height != displaySize.height else {
            return StillGeometry(rotation: .none, codedSize: coded, displaySize: displaySize)
        }

        var rotation = StillGeometry.Rotation.cw
        if let raw = previewFrame(from: videoURL, applyTransform: false) {
            let reference = grayThumb(display)
            let base = grayThumb(raw)
            let cwScore = diff(rotateThumb(base, clockwise: true), reference)
            let ccwScore = diff(rotateThumb(base, clockwise: false), reference)
            rotation = cwScore <= ccwScore ? .cw : .ccw
            Diagnostics.mark("burn.geom-\(rotation == .cw ? "cw" : "ccw")")
        } else {
            // 拿不到原始帧时按尺寸推断：编码是横的、显示是竖的，就是竖拍
            rotation = displaySize.height > displaySize.width ? .cw : .none
        }
        return StillGeometry(rotation: rotation, codedSize: coded, displaySize: displaySize)
    }

    /// 16x16 灰度指纹：用来做方向/几何比对，与真实画质无关
    private static func grayThumb(_ image: CGImage, side: Int = 16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return bytes
    }

    /// 旋转方形指纹数组（图像坐标，y 向下）
    private static func rotateThumb(_ src: [UInt8], clockwise: Bool) -> [UInt8] {
        let side = Int(Double(src.count).squareRoot().rounded())
        guard side * side == src.count else { return src }
        var out = [UInt8](repeating: 0, count: src.count)
        for y in 0..<side {
            for x in 0..<side {
                let value = src[y * side + x]
                if clockwise {
                    out[x * side + (side - 1 - y)] = value
                } else {
                    out[(side - 1 - x) * side + y] = value
                }
            }
        }
        return out
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for index in 0..<a.count {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return total / a.count
    }

    /// 把「显示方向」的合成图转回「编码方向」
    private static func rotate(_ image: CGImage,
                               by rotation: StillGeometry.Rotation) -> CGImage? {
        guard rotation != .none else { return image }
        let w = image.width
        let h = image.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: h, height: w),
                                       format: format).image { ctx in
            let cg = ctx.cgContext
            if rotation == .cw {
                cg.translateBy(x: CGFloat(h), y: 0)
                cg.rotate(by: .pi / 2)
            } else {
                cg.translateBy(x: 0, y: CGFloat(w))
                cg.rotate(by: -.pi / 2)
            }
            // 90° 整数倍旋转不做插值，像素是一一搬过去的
            cg.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        }.cgImage
    }

    /// 按几何编码静帧，并用「解码后按 EXIF 转正的小图」与显示图比对，
    /// 自动纠正方向（万一对旋转方向判断反了，这里会自己换回来）。
    private static func encodeOriented(_ display: CGImage, geometry: StillGeometry,
                                       identifier: String, notes: inout [String]) -> Data? {
        let reference = grayThumb(display)
        var best: (data: Data, score: Int, exif: Int)?

        for store in [geometry.storeRotation, geometry.storeRotation.opposite] {
            guard let coded = rotate(display, by: store) else { continue }
            // 存的是「编码方向」的像素，显示时需要 store 的反向旋转
            let exif = store.opposite.exif
            var local: [String] = []
            guard let data = makeStillData(coded, orientation: exif,
                                           identifier: identifier, notes: &local) else {
                notes.append(contentsOf: local)
                continue
            }
            let score = thumbScore(data, reference: reference)
            if best == nil || score < best!.score {
                best = (data, score, exif)
            }
            // 误差已经很小（同一画面 + 文字层，正常 0~10），不用再试另一个方向
            if score <= 12 { break }
        }

        guard let best else { return nil }
        notes.append("exif=\(best.exif)")
        notes.append("oScore=\(best.score)")
        return best.data
    }

    /// 把编码好的静帧按 EXIF 转正、缩成 16x16，和「显示图」的指纹算平均差值
    private static func thumbScore(_ data: Data, reference: [UInt8]) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return 255 }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 16
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return 255
        }
        return diff(grayThumb(thumb), reference)
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
    private static func makeStillData(_ image: CGImage, orientation: Int,
                                      identifier: String,
                                      notes: inout [String]) -> Data? {
        // A：两遍法 + AddImageFromSource（主路径）
        if let base = encodeHEIC(image, orientation: orientation) {
            if let patched = patchMakerApple(base, orientation: orientation,
                                             identifier: identifier, fromSource: true) {
                if makerIdentifier(patched) == identifier {
                    notes.append("still=A")
                    return patched
                }
                notes.append("A:丢标识")
            } else {
                notes.append("A:回写失败")
            }
            // C：两遍法 + AddImage
            if let patched = patchMakerApple(base, orientation: orientation,
                                             identifier: identifier, fromSource: false) {
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
        if let direct = encodeHEIC(image, orientation: orientation,
                                   extra: [kCGImagePropertyMakerAppleDictionary: ["17": identifier]]),
           makerIdentifier(direct) == identifier {
            notes.append("still=B")
            return direct
        }
        notes.append("B:丢标识")
        return nil
    }

    private static func encodeHEIC(_ image: CGImage, orientation: Int,
                                   extra: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                         "public.heic" as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.98,
            kCGImagePropertyOrientation: orientation
        ]
        for (key, value) in extra { props[key] = value }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func patchMakerApple(_ base: Data, orientation: Int, identifier: String,
                                        fromSource: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(base as CFData, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        // 方向必须保住：它决定静帧在相册里是竖的还是躺着
        props[kCGImagePropertyOrientation] = orientation
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
