import UIKit
import CoreGraphics
import CoreText

/// 文案渲染。**预览、封面（HEIC）、逐帧视频（动图）共用这一套排版与绘制**。
///
/// ## v25：排版参数从「拍脑袋换算」改成「样式驱动」
///
/// v22~v24 的字号是按「预览 13pt + 2 → 按屏宽换算成像素」推出来的，
/// 位置写死在画面上部居中。那样只能保证「差不多」，一旦要改字体、改位置就无从下手，
/// 而且预览是 SwiftUI 画、成片是 TextLayer 画，两套代码天然对不上。
///
/// 现在排版只由 `TextStyle` 决定：
///   - 字号 = `sizeRatio × 画布宽度`；
///   - 位置 = 归一化中心点；
///   - 字体 = `TextFont`。
///
/// 预览只是把「画布」换成屏幕上的矩形去调同一个 `layout(...)`，
/// 所以**字体、字号、行距、描边、位置全部一致**，这就是所见即所得。
///
/// ## v22 留下的画法（不要再改回去）
///
/// v14~v21 用「一次 NSAttributedString.draw + `.strokeWidth` 负值 + NSShadow」，
/// 真机上必然发糊：
/// 1. **负值 strokeWidth = 填充 + 居中描边**，描边有一半画进笔画内部。
///    中文粗体笔画只有字号的 8~10%，描边一宽就变成「空心黑框 + 细白芯」。
/// 2. **NSShadow 强制走离屏合成**，哪怕 blur=0 也会先渲染到临时 bitmap 再合成，
///    边缘必被重采样一次。
///
/// 现在的画法是**两遍绘制**（抖音/剪映字幕的做法）：
/// 先画「只描边」（正值 strokeWidth），再画「只填充」；填充把描边内圈盖掉，
/// 视觉上只剩外侧一圈干净轮廓，笔画内部永远是实心白。
enum TextLayer {

    /// 单次渲染的最大行数（再多字号会小到看不清）
    private static let maxLines = 5
    /// 外描边宽度（百分比，相对字号）。正值 strokeWidth 的语义是「只描边、不填充」，
    /// 线宽 = 字号 × strokePercent / 100，**居中**画在字形轮廓上；
    /// 第二遍填充会把内侧一半盖掉，所以最终可见的只是外侧 `strokePercent/2`。
    /// 9% 在 90px 字号下 → 外轮廓约 4px，是短视频字幕那种「利落黑边」的粗细。
    private static let strokePercent: CGFloat = 9.0

    // MARK: - 排版结果

    /// 排好的版：每行的富文本 + 绘制起点（UIKit 坐标，原点左上）
    struct Layout {
        let canvas: CGSize
        let fontSize: CGFloat
        /// 文字块外接矩形（含描边与底色余量）。预览只渲染这一块，不必重画整屏。
        let blockRect: CGRect
        /// 底色块（无底色时为 nil）
        let backgroundRect: CGRect?
        let background: UIColor?
        /// 底色圆角
        let cornerRadius: CGFloat
        /// 描边色（无描边时为 nil）
        let outline: UIColor?
        let lines: [NSAttributedString]
        let origins: [CGPoint]
    }

    // MARK: - 对外入口

    /// 生成整张画布的透明文字层，供静帧合成用。尺寸必须与静帧画布完全一致。
    static func make(lines: [String], style: TextStyle, canvas: CGSize,
                     maxWidthRatio: CGFloat = 0.92) -> CGImage? {
        guard let layout = layout(lines: lines, style: style, canvas: canvas,
                                  maxWidthRatio: maxWidthRatio) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // 固定 sRGB：广色域会让白字发灰
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            draw(layout, in: ctx.cgContext)
        }.cgImage
    }

    /// 只渲染文字块本身（预览用）。
    ///
    /// 预览每敲一个字都要重画，整屏渲染太浪费；只画文字块既快，
    /// 又把「绘制逻辑只有一份」这件事保住了 —— 见 `TextBlockImage`。
    ///
    /// - Returns: 图像内容就是 `rect` 那一块画布，位置由调用方摆放。
    static func renderBlock(lines: [String], style: TextStyle, canvas: CGSize,
                            scale: CGFloat,
                            maxWidthRatio: CGFloat = 0.92) -> (image: CGImage, rect: CGRect)? {
        guard let layout = layout(lines: lines, style: style, canvas: canvas,
                                  maxWidthRatio: maxWidthRatio),
              layout.blockRect.width > 1, layout.blockRect.height > 1 else { return nil }

        let rect = layout.blockRect
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scale)
        format.opaque = false
        format.preferredRange = .standard

        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            // 坐标系搬过去：让线条的位标继续用画布坐标，绘制代码无需知道自己在被裁着画
            ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            draw(layout, in: ctx.cgContext)
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return (cgImage, rect)
    }

    /// 按样式算出排版。预览与成片走的是同一条路，只是 `canvas` 不同。
    ///
    /// - Parameter maxWidthRatio: 文字块可用宽度占画布的比例。
    ///   相机预览是 aspectFill 铺满全屏，画面两边会被裁掉；若按整个画面宽度排版，
    ///   长句子在预览里就被切了。传「屏幕上实际看得见的宽度比例」进来，
    ///   预览和成片用同一个值，两边都不外溢 —— 这也是所见即所得的一部分。
    static func layout(lines raw: [String], style: TextStyle, canvas: CGSize,
                       maxWidthRatio: CGFloat = 0.92) -> Layout? {
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)
            .map { String($0) }
        guard canvas.width >= 2, canvas.height >= 2, !cleaned.isEmpty else { return nil }

        let w = canvas.width
        let h = canvas.height
        let textFont = style.font
        let maxWidth = w * min(1, max(0.3, maxWidthRatio))
        let maxHeight = h * 0.70
        let lowerBound = w * TextStyle.minSizeRatio
        let palette = style.palette

        // 用户设的字号优先；只有真的放不下（长句 / 行数多）才按比例缩，直到装得下。
        // 这条规则与画布尺寸无关，所以预览缩到什么程度，成片就缩到什么程度。
        var fontSize = max(lowerBound, style.sizeRatio * w)
        for _ in 0..<60 {
            let font = textFont.uiFont(size: fontSize)
            let widest = cleaned.map {
                attributed($0, font: font, fontSize: fontSize,
                           base: palette.color, accent: palette.accent).size().width
            }.max() ?? 0
            if widest <= maxWidth && fontSize * style.lineSpacing * CGFloat(cleaned.count) <= maxHeight {
                break
            }
            guard fontSize > lowerBound else { break }
            fontSize = max(lowerBound, fontSize * 0.95)
        }

        let lineHeight = fontSize * style.lineSpacing
        let blockHeight = lineHeight * CGFloat(cleaned.count)
        let blockTop = style.centerY * h - blockHeight / 2
        let font = textFont.uiFont(size: fontSize)

        var lines: [NSAttributedString] = []
        var origins: [CGPoint] = []
        for (index, line) in cleaned.enumerated() {
            let text = attributed(line, font: font, fontSize: fontSize,
                                  base: palette.color, accent: palette.accent)
            let size = text.size()
            let x = style.centerX * w - size.width / 2
            // 行盒内垂直居中：不同字体的 ascender/descender 不一样，
            // 不居中的话换字体后整块会往上/往下跳
            let y = blockTop + CGFloat(index) * lineHeight + max(0, (lineHeight - size.height) / 2)
            lines.append(text)
            origins.append(CGPoint(x: x, y: y))
        }

        var union = CGRect.null
        for (index, text) in lines.enumerated() {
            union = union.union(CGRect(origin: origins[index], size: text.size()))
        }
        // 描边会溢出字形外框，外扩一点免得预览把黑边裁掉
        let padding = fontSize * 0.14 + 2
        var blockRect = union.insetBy(dx: -padding, dy: -padding)

        // 底色块：上下留白比左右略小，读起来像「字幕条」而不是方块
        var backgroundRect: CGRect?
        if style.background.color != nil {
            let bgRect = union.insetBy(dx: -fontSize * 0.30, dy: -fontSize * 0.17)
            backgroundRect = bgRect
            blockRect = blockRect.union(bgRect.insetBy(dx: -padding, dy: -padding))
        }

        return Layout(canvas: canvas, fontSize: fontSize, blockRect: blockRect,
                      backgroundRect: backgroundRect,
                      background: style.background.color?.withAlphaComponent(min(1, max(0.05, style.bgOpacity))),
                      cornerRadius: fontSize * 0.34,
                      outline: style.outline.color,
                      lines: lines, origins: origins)
    }

    /// 把排好的版画进任意 CGContext（UIKit 坐标系，原点左上）。
    ///
    /// 调用方负责已经把 CTM 翻好（静帧走 UIGraphicsImageRenderer 自动翻；
    /// 逐帧合成里由 FrameBurner 手动翻）。这里依次做：
    /// 底色块 → 描边一遍 → 填充一遍。
    static func draw(_ layout: Layout, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // 1) 底色（如果有）：先铺块，字压在上面
        if let rect = layout.backgroundRect, let color = layout.background {
            context.setFillColor(color.cgColor)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: layout.cornerRadius)
            context.addPath(path.cgPath)
            context.fillPath()
        }

        let outline = layout.outline

        for (index, text) in layout.lines.enumerated() where index < layout.origins.count {
            let point = layout.origins[index]

            // 2) 第一遍：只描边（正值 strokeWidth = 不填充）
            if let outline {
                let stroked = NSMutableAttributedString(attributedString: text)
                let full = NSRange(location: 0, length: stroked.length)
                stroked.addAttributes([
                    .strokeColor: outline,
                    .strokeWidth: strokePercent,
                    .foregroundColor: UIColor.clear
                ], range: full)
                stroked.draw(at: point)
            }

            // 3) 第二遍：只填充。盖住描边内圈 → 视觉上只剩外侧一圈轮廓，笔画内部是实心色
            text.draw(at: point)
        }
    }

    // MARK: - 行内解析：引号内琥珀高亮、行尾 !! 自绘双叹号

    /// 只带 `font` 与 `foregroundColor`。描边与阴影一律由 `draw` 统一加，
    /// 属性分散在两层时（v14~v21 就是这样）很容易互相覆盖，是文字发糊的来源之一。
    ///
    /// - Parameters:
    ///   - base: 正文颜色（来自 `TextPalette.color`）
    ///   - accent: 引号内卖点与行尾双叹号的颜色（来自 `TextPalette.accent`）
    private static func attributed(_ raw: String, font: UIFont,
                                   fontSize: CGFloat,
                                   base: UIColor, accent: UIColor) -> NSAttributedString {
        func attributes(_ color: UIColor) -> [NSAttributedString.Key: Any] {
            // 表情是彩色位图字形，foregroundColor 对它无效，但也不会被染色 ——
            // 所以文字换色后 emoji 依然是原生彩色，这是想要的效果。
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
                flush(inQuote ? accent : base)
                out.append(NSAttributedString(string: String(ch), attributes: attributes(base)))
                inQuote.toggle()
            } else {
                buffer.append(ch)
            }
        }
        flush(inQuote ? accent : base)

        if hasMark {
            out.append(markImage(fontSize: fontSize, color: accent))
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
