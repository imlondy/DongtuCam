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
    case noExporter
    case exportFailed(String)
    case stillFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "素材里没有视频轨"
        case .noExporter: return "无法创建视频导出会话"
        case .exportFailed(let reason): return "视频导出失败：\(reason)"
        case .stillFailed: return "封面静帧生成失败"
        }
    }
}

/// 把同一张文字图同时烧进「静帧」和「视频每一帧」。
///
/// 关键：Live Photo 不是「一张 JPEG + 一个 MP4」，而是靠一个 assetIdentifier 把
/// HEIC 静帧与 MOV 视频配对。iOS 15.1 起系统只会把这个标识写进 HEIC 的 MakerApple
/// 元数据（不再写进 JPEG），否则 PHAssetCreationRequest 会直接报
/// `PHPhotosErrorDomain 3302 (InvalidResource)` 而保存失败。
///
/// 因此这里：
///   1. 视频导出时写入 com.apple.quicktime.content.identifier + still-image-time；
///   2. 静帧存成 HEIC，并把同一个 identifier 写进 MakerApple 的 "17" 字段。
enum BurnEngine {
    static func render(source: URL, overlay: CGImage, seconds: Double = 5.0,
                       completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let asset = AVAsset(url: source)
        guard asset.tracks(withMediaType: .video).first != nil else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }

        // Live Photo 配对标识：HEIC 静帧与 MOV 视频必须共用同一个 UUID
        let identifier = UUID().uuidString

        let textCI = CIImage(cgImage: overlay)
        // applyingCIFiltersWithHandler 会自动处理 preferredTransform（竖屏拍摄不会躺倒），
        // 且 sourceImage 的尺寸就是最终渲染尺寸。把文字图按该尺寸缩放后再合成，
        // 就不需要手算任何裁切 / 旋转矩阵 —— 保持源比例、零人工延伸区。
        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let src = request.sourceImage
                let sx = src.extent.width / max(1, textCI.extent.width)
                let sy = src.extent.height / max(1, textCI.extent.height)
                let fitted = textCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                request.finish(with: fitted.composited(over: src), context: nil)
            })

        let outVideo = tmpURL("burn.mov")
        guard let exporter = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(BurnEngineError.noExporter))
            return
        }
        exporter.outputURL = outVideo
        exporter.outputFileType = .mov
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true
        exporter.metadata = livePhotoMetadata(identifier: identifier)
        let limit = CMTime(seconds: seconds, preferredTimescale: 600)
        exporter.timeRange = CMTimeRange(start: .zero,
                                         duration: CMTimeMinimum(asset.duration, limit))

        exporter.exportAsynchronously {
            guard exporter.status == .completed else {
                let reason = exporter.error?.localizedDescription
                    ?? "status=\(exporter.status.rawValue)"
                completion(.failure(BurnEngineError.exportFailed(reason)))
                return
            }
            completion(makeStill(asset: asset, textCI: textCI,
                                 videoURL: outVideo, identifier: identifier))
        }
    }

    /// 视频侧配对元数据：content identifier + still-image-time
    private static func livePhotoMetadata(identifier: String) -> [AVMetadataItem] {
        let contentID = AVMutableMetadataItem()
        contentID.keySpace = .quickTimeMetadata
        contentID.key = "com.apple.quicktime.content.identifier" as NSString
        contentID.value = identifier as NSString

        let stillTime = AVMutableMetadataItem()
        stillTime.keySpace = .quickTimeMetadata
        stillTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillTime.value = 0 as NSNumber

        return [contentID, stillTime]
    }

    /// still 必须也带文字，否则长按实况时文字会「闪现一下再消失」。
    /// 并且必须存成 HEIC，写入 MakerApple 的 "17" 配对标识。
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

    /// 编码 HEIC，并把 Live Photo 配对标识写进 MakerApple 元数据（"17" 字段）
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
