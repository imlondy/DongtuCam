import Foundation
import Vision
import UIKit

/// 一次拍摄画面里能拿到的全部识别线索
struct Recognition {
    var ocrLines: [String] = []
    var labels: [String] = []
    var localHit: Product?
    var localScore: Int = 0

    var ocrJoined: String { ocrLines.joined(separator: " ") }

    /// 显示给用户的一句话
    var summary: String {
        var parts: [String] = []
        if let hit = localHit {
            parts.append("识别到「\(hit.name)」")
        } else if !ocrLines.isEmpty {
            parts.append("画面文字：" + ocrLines.prefix(2).joined(separator: " "))
        } else {
            parts.append("未识别到商品")
        }
        if let first = labels.first {
            parts.append("图像：" + first)
        }
        return parts.joined(separator: " · ")
    }
}

/// 纯本机识别：Vision 做文字识别 + 图像分类，再用商品库的关键词打分。
/// 不联网、不花钱，识别结果同时作为 AI 的输入。
enum ProductRecognizer {
    static func analyze(frame: CGImage, products: [Product]) async -> Recognition {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result = Recognition()

                // 相机缓冲区是传感器朝向（横向），生成图有时是竖向，
                // 两种都试一遍、取文字更多的那个，避免识别率被朝向拖死。
                var best: [String] = []
                for orientation in [CGImagePropertyOrientation.right, .up] {
                    let lines = ocr(frame, orientation: orientation)
                    if lines.joined().count > best.joined().count { best = lines }
                }
                result.ocrLines = best
                result.labels = classify(frame)

                let match = localMatch(result, products: products)
                result.localHit = match.product
                result.localScore = match.score

                continuation.resume(returning: result)
            }
        }
    }

    /// 给多模态模型用的缩略图（768 长边、JPEG 0.6，约 60~100KB）
    static func jpegPreview(_ image: CGImage, maxSide: CGFloat = 768, quality: CGFloat = 0.6) -> Data? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 1, h > 1 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        let target = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: - Vision

    private static func ocr(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        func run(_ languages: [String]) -> [String]? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
        }
        if let lines = run(["zh-Hans", "en-US"]) { return lines }
        return run([]) ?? []
    }

    private static func classify(_ image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
            .map { "\($0.identifier) \(Int($0.confidence * 100))%" }
    }

    // MARK: - 本地打分

    private static func localMatch(_ result: Recognition, products: [Product]) -> (product: Product?, score: Int) {
        let texts = result.ocrLines + result.labels.map { chineseHint(for: $0) }
        let hay = texts.joined(separator: " ").lowercased()
        guard !hay.isEmpty else { return (nil, 0) }

        var best: (product: Product?, score: Int) = (nil, 0)
        for product in products {
            var score = 0
            if hay.contains(product.name.lowercased()) { score += 8 }
            for keyword in product.keywords where hay.contains(keyword.lowercased()) {
                score += 4
            }
            if hay.contains(product.category.lowercased()) { score += 2 }
            if score > best.score { best = (product, score) }
        }
        return best.score >= 4 ? best : (nil, best.score)
    }

    /// Vision 的分类标签是英文，转成中文关键词才能和商品库对上
    private static let hintMap: [(String, String)] = [
        ("bowl", "碗 汤"), ("soup", "汤 汤底"), ("stew", "炖 汤"),
        ("cup", "杯"), ("mug", "杯"), ("bottle", "瓶 喷雾"), ("jar", "罐"),
        ("box", "盒 包装"), ("carton", "盒 包装"), ("package", "包装"),
        ("paper", "纸 抽纸"), ("tissue", "纸 抽纸 纸巾"), ("napkin", "纸 纸巾"),
        ("spray", "喷雾 清洁"), ("cleaner", "清洁"), ("detergent", "清洁"),
        ("towel", "毛巾"), ("cloth", "布 毛巾"),
        ("food", "食品 汤"), ("dish", "菜 汤"), ("pot", "锅 炖"),
        ("tea", "茶"), ("herb", "药膳 中药材"), ("medicine", "药"),
        ("cosmetic", "护理"), ("hygiene", "护理 卫生")
    ]

    private static func chineseHint(for label: String) -> String {
        let lower = label.lowercased()
        return hintMap.filter { lower.contains($0.0) }.map { $0.1 }.joined(separator: " ")
    }
}
