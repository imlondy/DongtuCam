import UIKit
import CoreGraphics

/// 把整段文案渲染成一张与静帧同像素尺寸的透明 CGImage。
///
/// 清晰度的前提（v14 最重要的一条）：**这张图层永远按 1:1 叠到同尺寸底图上**，
/// 中间不允许任何缩放。之前把图层叠到视频里（还要 CIImage 缩放 + 视频编码 +
/// 再抽帧），每一环都在丢细节，字必糊；现在由 BurnEngine 直接合成静帧，
/// 图层和底图同为 1080x1440 这种像素尺寸，文字边缘就是干净的抗锯齿。
///
/// 字号规则（按真机反馈定的）：
/// 成片里的字要和**拍摄时屏幕上预览的那几行字**看起来一样大，只大 2 磅。
/// 预览是 13pt、铺满屏宽；成片是视频像素铺满同一块屏，所以换算比例是
/// `视频宽 / 屏宽`。
///
/// 视觉规范（抖音动图带货）：
/// - 整段常驻、居中对齐、上方安全区；无顶部渐变、无背景色块
/// - 微暖白字 + 细描边（≈2.5% 字号）+ 柔和投影
///
/// 为什么描边必须这么细：中文字粗体笔画宽度约为字号的 8~10%，
/// 描边一宽就会从两侧吃掉笔画中间的白色，字变成黑色实心块。
/// 同理字重取 bold 而不是 heavy：小字号下 heavy 的笔画会互相粘成一坨。
enum TextLayer {
    /// 单次渲染的最大行数（再多会把字号压到看不清）
    private static let maxLines = 5
    /// 描边宽度占字号的比例
    private static let strokeRatio: CGFloat = 0.026
    /// 投影模糊半径占字号的比例（v17 收窄：投影一糊，小字号就发毛）
    private static let shadowRatio: CGFloat = 0.04

    /// - Parameters:
    ///   - size: 成片画布尺寸（视频显示尺寸）
    ///   - previewFontPt: 拍摄预览里那几行字的字号（pt）
    ///   - screenWidthPt: 手机屏幕宽度（pt），用来把 pt 换算成视频像素
    static func make(lines: [String], size: CGSize,
                     previewFontPt: CGFloat = 13,
                     screenWidthPt: CGFloat = 393) -> CGImage? {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)
            .map { String($0) }
        guard size.width >= 2, size.height >= 2, !cleaned.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // 固定 sRGB，避免广色域/线性空间让白字发灰、投影发糊
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(cleaned, size: size,
                 previewFontPt: previewFontPt, screenWidthPt: screenWidthPt)
        }.cgImage
    }

    // MARK: - 排版

    private static func draw(_ lines: [String], size: CGSize,
                             previewFontPt: CGFloat, screenWidthPt: CGFloat) {
        let w = size.width
        let h = size.height

        // pt → 成片像素：同一条屏宽上，视频像素数 / 屏幕磅数
        let pxPerPt = w / max(1, screenWidthPt)
        // 预览 +2pt，就是用户要的「比预览大 2 个 px」
        let target = (previewFontPt + 2) * pxPerPt

        let maxWidth = w * 0.90
        let maxBlockHeight = h * 0.42
        // 兜底上下限：再小看不清，再大就会盖住商品
        let upperBound = min(target, w * 0.085)
        let lowerBound = max(10, w * 0.028)

        var fontSize = upperBound
        var lineHeight = fontSize * lineSpacing
        while fontSize > lowerBound {
            lineHeight = fontSize * lineSpacing
            let widest = lines.map { measure($0, fontSize: fontSize) }.max() ?? 0
            if widest <= maxWidth && lineHeight * CGFloat(lines.count) <= maxBlockHeight {
                break
            }
            fontSize -= max(1, fontSize * 0.03)
        }
        fontSize = max(fontSize, lowerBound).rounded()
        lineHeight = (fontSize * lineSpacing).rounded()

        let top = max(8, h * 0.055)
        let blockHeight = lineHeight * CGFloat(lines.count)
        // 行数多时整体略微上移，保证视觉重心仍在画面上部
        let startY = top + max(0, (maxBlockHeight - blockHeight) * 0.18)

        for (index, line) in lines.enumerated() {
            let text = attributed(line, fontSize: fontSize)
            let textSize = text.size()
            // 坐标取整：落在半个像素上会让 CoreGraphics 做重采样，白字边缘就毛了
            let x = ((w - textSize.width) / 2).rounded()
            let slotY = startY + CGFloat(index) * lineHeight
            let y = (slotY + max(0, (lineHeight - textSize.height) / 2)).rounded()
            text.draw(at: CGPoint(x: x, y: y))
        }
    }

    private static let lineSpacing: CGFloat = 1.26

    private static func measure(_ line: String, fontSize: CGFloat) -> CGFloat {
        attributed(line, fontSize: fontSize).size().width
    }

    // MARK: - 行内解析：引号内琥珀高亮、行尾 !! 自绘双叹号

    private static func attributed(_ raw: String, fontSize: CGFloat) -> NSAttributedString {
        let warmWhite = UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1.0)
        let amber = UIColor(red: 1.0, green: 0.784, blue: 0.310, alpha: 1.0)
        let outline = UIColor(red: 0.106, green: 0.063, blue: 0.055, alpha: 0.95)

        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)

        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: 0.42)
        shadow.shadowBlurRadius = max(1, fontSize * shadowRatio)
        shadow.shadowOffset = CGSize(width: 0, height: max(1, fontSize * 0.016))

        let strokeWidth = -max(0.8, fontSize * strokeRatio)

        func attributes(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: color,
                .strokeColor: outline,
                .strokeWidth: strokeWidth,
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
            out.append(markImage(fontSize: fontSize, color: amber))
        }
        return out
    }

    /// 自绘双叹号（避免 emoji 字体豆腐块），以文本附件形式接在行尾
    private static func markImage(fontSize: CGFloat, color: UIColor) -> NSAttributedString {
        let totalW = fontSize * 0.58
        let barW = max(2, fontSize * 0.145)
        let barH = fontSize * 0.58
        let dotR = max(1.5, fontSize * 0.078)
        let height = barH + 3 * dotR + 4

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let image = UIGraphicsImageRenderer(
            size: CGSize(width: totalW, height: height), format: format
        ).image { _ in
            let gap = max(3, (totalW - 2 * barW) / 3)
            let x0 = (totalW - (2 * barW + gap)) / 2
            color.setFill()
            for k in 0..<2 {
                let x = x0 + CGFloat(k) * (barW + gap)
                UIBezierPath(roundedRect: CGRect(x: x, y: 1, width: barW, height: barH),
                             cornerRadius: barW / 2).fill()
                UIBezierPath(ovalIn: CGRect(x: x, y: 1 + barH + dotR,
                                            width: barW, height: 2 * dotR)).fill()
            }
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -fontSize * 0.16, width: totalW, height: height)
        return NSAttributedString(attachment: attachment)
    }
}
