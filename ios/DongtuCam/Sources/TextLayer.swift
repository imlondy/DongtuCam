import UIKit
import CoreGraphics

/// 把整段文案渲染成一张与视频同尺寸的透明 CGImage。
/// 参数与 dongtu-viral-copy 的 §10 定稿一致：
/// 整段常驻、字号按上方空白带自适应、无顶部渐变、深暖黑描边 + 微暖白 + 柔和投影。
enum TextLayer {
    static func make(lines: [String], size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0, !lines.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(lines: lines, size: size)
        }.cgImage
    }

    // MARK: - 排版

    private static func draw(lines: [String], size: CGSize) {
        let w = size.width
        let h = size.height
        let base = max(28, h * 62 / 1440)
        let floor = max(20, h * 34 / 1440)
        let maxW = w * 0.90
        let maxBlockH = h * 300 / 1440
        let lineGap: CGFloat = 1.10

        var fontSize = base
        var lineH = base * 1.35 * lineGap
        while fontSize >= floor {
            lineH = fontSize * 1.35 * lineGap
            let widest = lines.map { width($0, size: fontSize) }.max() ?? 0
            if widest <= maxW && lineH * CGFloat(lines.count) <= maxBlockH { break }
            fontSize -= 1
        }
        fontSize = max(fontSize, floor)
        lineH = fontSize * 1.35 * lineGap

        let topY = max(10, h * 16 / 1440)
        let stroke = max(2, h * 4 / 1440)
        let shadowRadius = max(3, h * 6 / 1440)

        for (index, raw) in lines.enumerated() {
            let attr = attributed(raw, size: fontSize, stroke: stroke,
                                  shadowRadius: shadowRadius, canvasH: h)
            let x = (w - attr.size().width) / 2
            let y = topY + CGFloat(index) * lineH
            attr.draw(at: CGPoint(x: x, y: y))
        }
    }

    private static func width(_ line: String, size: CGFloat) -> CGFloat {
        attributed(line, size: size, stroke: max(2, size * 4 / 62),
                   shadowRadius: max(3, size * 6 / 62), canvasH: 1440)
            .size().width
    }

    // MARK: - 行内解析：引号内琥珀高亮、行尾 !! 自绘双叹号

    private static func attributed(_ raw: String, size: CGFloat, stroke: CGFloat,
                                   shadowRadius: CGFloat, canvasH: CGFloat) -> NSAttributedString {
        let warmWhite = UIColor(red: 1, green: 250 / 255, blue: 246 / 255, alpha: 1)
        let amber = UIColor(red: 1, green: 198 / 255, blue: 92 / 255, alpha: 1)
        let warmBlack = UIColor(red: 26 / 255, green: 14 / 255, blue: 12 / 255, alpha: 0.92)
        let font = UIFont.boldSystemFont(ofSize: size)

        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = shadowRadius
        shadow.shadowOffset = CGSize(width: max(1, canvasH * 3 / 1440),
                                     height: max(2, canvasH * 6 / 1440))

        func attributes(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: color,
                .strokeColor: warmBlack,
                .strokeWidth: -stroke,
                .shadow: shadow
            ]
        }

        var text = raw
        let hasMark = text.hasSuffix("!!")
        if hasMark { text.removeLast(2) }

        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}"]
        let out = NSMutableAttributedString()
        var buffer = ""
        var inQuote = false

        func flush(_ color: UIColor) {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: attributes(color)))
            buffer = ""
        }

        for ch in text {
            if quotes.contains(ch) {
                flush(inQuote ? amber : warmWhite)
                out.append(NSAttributedString(string: String(ch), attributes: attributes(warmWhite)))
                inQuote.toggle()
            } else {
                buffer.append(ch)
            }
        }
        flush(inQuote ? amber : warmWhite)

        if hasMark {
            out.append(markImage(size: size, color: amber))
        }
        return out
    }

    /// 自绘双叹号（避免 emoji 字体豆腐块），以文本附件形式接在行尾
    private static func markImage(size: CGFloat, color: UIColor) -> NSAttributedString {
        let totalW = size * 0.58
        let barW = max(4, size * 0.150)
        let barH = size * 0.60
        let dotR = max(3, size * 0.085)
        let height = barH + 3 * dotR + 6
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: height), format: format)
        let image = renderer.image { _ in
            let gap = max(4, (totalW - 2 * barW) / 3)
            let x0 = (totalW - (2 * barW + gap)) / 2
            color.setFill()
            for k in 0..<2 {
                let x = x0 + CGFloat(k) * (barW + gap)
                UIBezierPath(roundedRect: CGRect(x: x, y: 3, width: barW, height: barH),
                             cornerRadius: barW / 2).fill()
                UIBezierPath(ovalIn: CGRect(x: x, y: 3 + barH + dotR,
                                            width: barW, height: 2 * dotR)).fill()
            }
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -size * 0.18, width: totalW, height: height)
        return NSAttributedString(attachment: attachment)
    }
}
