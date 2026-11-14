import UIKit
import CoreGraphics
import CoreText

/// 文案渲染。**同一套排版**同时供静帧（HEIC）和逐帧视频（动图）使用。
///
/// ## v22：为什么文字终于能清晰
///
/// v14~v21 一直用「一次 NSAttributedString.draw + `.strokeWidth` 负值 + NSShadow」。
/// 这在真机上必然发糊，原因有三条，都是叠加的：
///
/// 1. **`.strokeWidth` 负值 = 填充 + 居中描边**。描边线宽的一半会吃掉笔画内部的白色，
///    中文字粗体笔画本身只有字号的 8~10%，描边一宽，字就变成「空心黑框 + 细白芯」，
///    视觉上就是发灰、发糊。截图里那种「字有网格、笔画中间发虚」正是它。
/// 2. **NSShadow 会强制走离屏合成路径**。哪怕 blur 半径设成 0，只要 `.shadow`
///    属性存在，CoreText 就会先把整行渲染到一张临时 bitmap 再合成，
///    这张 bitmap 的栅格化尺寸不等同于目标画布，边缘必然被重采样一遍。
/// 3. **文字与底图不在同一个绘制事务里**。静帧是「先渲染透明图层 → 再 UIGraphics
///    把图层缩放到画布 → 编码」，中间那次缩放就是在拿位图做重采样。
///
/// v22 的做法：
/// - **两遍绘制**：先画「只描边」（`.strokeWidth` 正值），再画「只填充」。
///   填充把笔画内部完全盖成实心白，描边只留下外侧那一圈 —— 这是唯一能得到
///   「实心白字 + 干净黑轮廓」的画法，也是抖音/剪映字幕的实现方式。
/// - **没有 NSShadow**：分离度靠描边，不靠阴影。
/// - **一步到最终像素**：`layout(size:)` 直接按目标画布的像素尺寸算字号与行位，
///   静帧和视频帧各自在自己的分辨率上做一次矢量光栅化，**中间没有任何位图缩放**。
enum TextLayer {

    /// 单次渲染的最大行数（再多会把字号压到看不清）
    private static let maxLines = 5
    /// 外描边宽度（百分比，相对字号）。正值 strokeWidth 的语义是「只描边、不填充」，
    /// 线宽 = 字号 × strokePercent / 100，**居中**画在字形轮廓上；
    /// 第二遍填充会把内侧那一半完全盖掉，所以最终可见的只是外侧 `strokePercent/2`。
    /// 9% 在 62px 字号下 → 外轮廓约 2.8px，是短视频字幕那种「利落黑边」的粗细，
    /// 字与背景任何颜色下都能分开，又不至于把白字挤细。
    /// 关键安全点：描边只出现在**字形外部**，笔画内部的白色永远是完整的 ——
    /// 这正是 v14~v21「负 strokeWidth 居中吃掉笔画」做不到的。
    private static let strokePercent: CGFloat = 9.0
    private static let lineSpacing: CGFloat = 1.26

    // MARK: - 排版结果

    /// 排好的版：每行的纯文本富文本 + 绘制起点（UIKit 坐标，原点左上）
    struct Layout {
        let size: CGSize
        let fontSize: CGFloat
        let lines: [NSAttributedString]
        let origins: [CGPoint]
    }

    // MARK: - 对外入口

    /// 生成静帧用的透明文字层。尺寸必须与静帧画布**完全一致**。
    static func make(lines: [String], size: CGSize,
                     previewFontPt: CGFloat = 13,
                     screenWidthPt: CGFloat = 393) -> CGImage? {
        guard let prepared = layout(lines: lines, size: size,
                                    previewFontPt: previewFontPt,
                                    screenWidthPt: screenWidthPt) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // 固定 sRGB：广色域会让白字发灰
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(prepared, in: ctx.cgContext)
        }.cgImage
    }

    /// 按目标尺寸算好版式。视频逐帧合成时也用它 —— 视频帧和静帧用同一套比例，
    /// 所以动图播放时文字的位置、大小与封面完全一致，不会「跳」。
    static func layout(lines raw: [String], size: CGSize,
                       previewFontPt: CGFloat = 13,
                       screenWidthPt: CGFloat = 393) -> Layout? {
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)
            .map { String($0) }
        guard size.width >= 2, size.height >= 2, !cleaned.isEmpty else { return nil }

        let w = size.width
        let h = size.height

        // pt → 成片像素：同一条屏宽上，画面像素数 / 屏幕磅数
        let pxPerPt = w / max(1, screenWidthPt)
        let target = (previewFontPt + 2) * pxPerPt

        let maxWidth = w * 0.90
        let maxBlockHeight = h * 0.42
        // 兜底上下限：再小看不清，再大就会盖住商品
        let upperBound = min(target, w * 0.085)
        let lowerBound = max(16, w * 0.036)

        var fontSize = upperBound
        var lineHeight = fontSize * lineSpacing
        while fontSize > lowerBound {
            lineHeight = fontSize * lineSpacing
            let widest = cleaned.map { measure($0, fontSize: fontSize) }.max() ?? 0
            if widest <= maxWidth && lineHeight * CGFloat(cleaned.count) <= maxBlockHeight {
                break
            }
            fontSize -= max(1, fontSize * 0.03)
        }
        fontSize = max(fontSize, lowerBound).rounded()
        lineHeight = (fontSize * lineSpacing).rounded()

        let top = max(8, h * 0.055)
        let blockHeight = lineHeight * CGFloat(cleaned.count)
        // 行数多时整体略微上移，保证视觉重心仍在画面上部
        let startY = top + max(0, (maxBlockHeight - blockHeight) * 0.18)

        var lines: [NSAttributedString] = []
        var origins: [CGPoint] = []
        for (index, line) in cleaned.enumerated() {
            let text = attributed(line, fontSize: fontSize)
            let textSize = text.size()
            // 坐标取整：落在半个像素上会让 CoreGraphics 做重采样，白字边缘就毛了
            let x = ((w - textSize.width) / 2).rounded()
            let slotY = startY + CGFloat(index) * lineHeight
            let y = (slotY + max(0, (lineHeight - textSize.height) / 2)).rounded()
            lines.append(text)
            origins.append(CGPoint(x: x, y: y))
        }
        return Layout(size: size, fontSize: fontSize, lines: lines, origins: origins)
    }

    /// 把排好的版画进任意 CGContext（UIKit 坐标系，原点左上）。
    ///
    /// 调用方负责已经翻转好 CTM（静帧走 UIGraphicsImageRenderer 自动翻好；
    /// 逐帧合成里由 FrameBurner 手动翻转）。这里只做「描边一遍 + 填充一遍」。
    static func draw(_ layout: Layout, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // 深褐近黑，比纯黑更贴视频常见的暖色调背景
        let outline = UIColor(red: 0.09, green: 0.055, blue: 0.045, alpha: 1.0)

        for (index, text) in layout.lines.enumerated() where index < layout.origins.count {
            let point = layout.origins[index]

            // 第一遍：只描边（正值 strokeWidth = 不填充）
            let stroked = NSMutableAttributedString(attributedString: text)
            let full = NSRange(location: 0, length: stroked.length)
            stroked.addAttributes([
                .strokeColor: outline,
                .strokeWidth: strokePercent,
                .foregroundColor: UIColor.clear
            ], range: full)
            stroked.draw(at: point)

            // 第二遍：只填充。盖住描边内圈 → 视觉上只剩外侧一圈轮廓，笔画内部是实心白
            text.draw(at: point)
        }
    }

    // MARK: - 行内解析：引号内琥珀高亮、行尾 !! 自绘双叹号

    private static func measure(_ line: String, fontSize: CGFloat) -> CGFloat {
        attributed(line, fontSize: fontSize).size().width
    }

    /// 只带 `font` 与 `foregroundColor`。描边与阴影一律由 `draw` 统一加，
    /// 属性分散在两层时（v14~v21 就是这样）很容易互相覆盖，是文字发糊的来源之一。
    private static func attributed(_ raw: String, fontSize: CGFloat) -> NSAttributedString {
        let warmWhite = UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1.0)
        let amber = UIColor(red: 1.0, green: 0.784, blue: 0.310, alpha: 1.0)

        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)

        func attributes(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color]
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
