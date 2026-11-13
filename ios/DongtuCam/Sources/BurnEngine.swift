import AVFoundation
import CoreImage
import UIKit

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
/// 这一步必须在 iPhone 本机做：只有本机产出的 still + pairedVideo
/// 才能被 PHAssetCreationRequest 写成一个实况照片资源。
enum BurnEngine {
    static func render(source: URL, overlay: CGImage, seconds: Double = 5.0,
                       completion: @escaping (Result<BurnOutput, Error>) -> Void) {
        let asset = AVAsset(url: source)
        guard asset.tracks(withMediaType: .video).first != nil else {
            completion(.failure(BurnEngineError.noVideoTrack))
            return
        }

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
            completion(makeStill(asset: asset, textCI: textCI, videoURL: outVideo))
        }
    }

    /// still 必须也带文字，否则长按实况时文字会「闪现一下再消失」。
    private static func makeStill(asset: AVAsset, textCI: CIImage,
                                  videoURL: URL) -> Result<BurnOutput, Error> {
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
                  let jpeg = UIImage(cgImage: out).jpegData(compressionQuality: 0.95) else {
                return .failure(BurnEngineError.stillFailed)
            }
            let outStill = tmpURL("still.jpg")
            try jpeg.write(to: outStill)
            return .success(BurnOutput(stillURL: outStill, videoURL: videoURL))
        } catch {
            return .failure(error)
        }
    }

    private static func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-\(UUID().uuidString)-\(name)")
    }
}
